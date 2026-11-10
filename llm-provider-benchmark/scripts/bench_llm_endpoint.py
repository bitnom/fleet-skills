#!/usr/bin/env python3
"""Measure TTFT, generation window, and output TPS for LLM providers.

Standard library only. Works against any OpenAI-compatible
``POST {base_url}/chat/completions`` endpoint that supports ``stream: true``.

Reports three latencies, because a reasoning model makes them differ:
``ttft_ms`` (first token of any kind), ``ttft_reasoning_ms`` (first reasoning
token, None for non-reasoning models), and ``ttft_content_ms`` (first visible
content token, which is what a user actually waits for).

Targets are described in a JSON spec so one script can sweep many providers,
each with its own key, base URL, model, and request-body overrides:

{
  "targets": [
    {"name": "kriora",
     "base_url": "https://subrouter.ai/v1",
     "api_key_file": "/path/to/key",     # or "api_key_env": "NAME"
     "model": "deepseek-v4.1-flash-1017",
     "extra_body": {"reasoning_effort": "max"}}
  ],
  "runs": 2,
  "prompt": "Write a detailed 700-word plain-prose explanation of ...",
  "max_tokens": 3000,
  "timeout_seconds": 240
}

Run:

    python3 bench_llm_endpoint.py --spec spec.json --out results.json

Secrets are read from files or environment variables and are never printed,
written to the output file, or echoed in errors.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import statistics
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Iterator

DEFAULT_PROMPT = (
    "Write a detailed 700-word plain-prose explanation of how TCP congestion "
    "control works. No headings, no lists, just continuous prose."
)


def die(msg: str) -> None:
    print(msg, file=sys.stderr)
    raise SystemExit(2)


def read_secret(target: dict[str, Any]) -> str:
    """Resolve a target's API key from a file or an environment variable."""
    if target.get("api_key_env"):
        name = target["api_key_env"]
        value = os.environ.get(name, "").strip()
        if not value:
            die(f"environment variable {name} is empty")
        return value
    if target.get("api_key_file"):
        path = Path(target["api_key_file"]).expanduser()
        try:
            value = path.read_text().strip()
        except OSError as exc:
            die(f"cannot read api_key_file {path}: {exc}")
        if not value:
            die(f"api_key_file {path} is empty")
        return value
    if target.get("api_key"):
        return str(target["api_key"]).strip()
    die("target has no api_key_file, api_key_env, or api_key")
    raise AssertionError("unreachable")


def iter_sse(payload: bytes) -> Iterator[dict[str, Any]]:
    """Yield decoded JSON objects from an SSE byte stream."""
    for raw_line in payload.splitlines():
        line = raw_line.decode("utf-8", "replace").strip()
        if not line.startswith("data:"):
            continue
        body = line[5:].strip()
        if not body or body == "[DONE]":
            continue
        try:
            chunk = json.loads(body)
        except json.JSONDecodeError:
            continue
        if isinstance(chunk, dict):
            yield chunk


def pick_completion_tokens(usage: dict[str, Any] | None) -> int:
    if not usage:
        return 0
    return int(usage.get("completion_tokens") or 0)


def pick_reasoning_tokens(usage: dict[str, Any] | None) -> int:
    if not usage:
        return 0
    details = usage.get("completion_tokens_details")
    if isinstance(details, dict) and details.get("reasoning_tokens") is not None:
        return int(details["reasoning_tokens"])
    for key in ("completion_thinking_tokens", "reasoning_tokens"):
        if usage.get(key) is not None:
            return int(usage[key])
    return 0


def measure_once(target: dict[str, Any], spec: dict[str, Any], api_key: str) -> dict[str, Any]:
    """Run one streaming request and return timing and token metrics."""
    base_url = str(target["base_url"]).rstrip("/")
    url = f"{base_url}/chat/completions"
    body: dict[str, Any] = {
        "model": target["model"],
        "messages": [{"role": "user", "content": spec.get("prompt", DEFAULT_PROMPT)}],
        "max_tokens": int(target.get("max_tokens", spec.get("max_tokens", 3000))),
        "stream": True,
    }
    body.update(target.get("extra_body") or {})

    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {api_key}",
    }
    headers.update(target.get("headers") or {})

    timeout = float(target.get("timeout_seconds", spec.get("timeout_seconds", 240)))
    request = urllib.request.Request(
        url, data=json.dumps(body).encode(), headers=headers, method="POST"
    )

    started = time.monotonic()
    # The whole request is bounded, not just each socket read.
    deadline = started + timeout
    first_token_at: float | None = None
    first_reasoning_at: float | None = None
    first_content_at: float | None = None
    last_content_at: float | None = None
    last_chunk_at: float | None = None
    usage: dict[str, Any] | None = None
    content_chars = 0
    reasoning_chars = 0
    chunks = 0
    status = 0
    error: str | None = None
    model_seen: str | None = None
    finish_reason: str | None = None

    def absorb(chunk: dict[str, Any]) -> None:
        nonlocal chunks, usage, model_seen, content_chars, reasoning_chars
        nonlocal first_token_at, first_reasoning_at, first_content_at
        nonlocal last_content_at, last_chunk_at, finish_reason
        chunks += 1
        last_chunk_at = time.monotonic()
        if chunk.get("usage"):
            usage = chunk["usage"]
        if chunk.get("model"):
            model_seen = chunk["model"]
        choices = chunk.get("choices") or []
        if not choices:
            return
        choice = choices[0]
        if choice.get("finish_reason"):
            finish_reason = choice["finish_reason"]
        delta = choice.get("delta") or {}
        text = delta.get("content") or ""
        # Some gateways put the thinking tokens in delta.reasoning instead of
        # delta.reasoning_content. Read both, and tolerate a non-string value,
        # so a route that thinks in the other field still gets a first-token
        # time instead of looking like it never answered.
        reasoning = delta.get("reasoning_content") or delta.get("reasoning") or ""
        if not isinstance(reasoning, str):
            reasoning = "" if reasoning is None else str(reasoning)
        if text or reasoning:
            if first_token_at is None:
                first_token_at = time.monotonic()
        if reasoning:
            if first_reasoning_at is None:
                first_reasoning_at = time.monotonic()
            reasoning_chars += len(reasoning)
        if text:
            if first_content_at is None:
                first_content_at = time.monotonic()
            last_content_at = time.monotonic()
            content_chars += len(text)

    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            status = response.status
            # Read line by line. A sized read() on a buffered HTTP response blocks
            # until the buffer fills, which destroys the timing window.
            for raw_line in response:
                # The socket timeout bounds a single read, not the whole
                # request. A route that keeps an empty chunk trickling every
                # few minutes can hold a request open for as long as it likes,
                # so enforce a wall-clock deadline here as well.
                if time.monotonic() > deadline:
                    error = f"TimeoutError: exceeded the {timeout:.0f}s wall deadline"
                    break
                for chunk in iter_sse(raw_line):
                    absorb(chunk)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:200]
        error = f"HTTP {exc.code}: {detail}"
    except Exception as exc:  # noqa: BLE001 - reported, not raised
        error = f"{type(exc).__name__}: {exc}"

    ended = last_chunk_at if last_chunk_at is not None else time.monotonic()
    completion_tokens = pick_completion_tokens(usage)
    reasoning_tokens = pick_reasoning_tokens(usage)
    tokens_estimated = usage is None and completion_tokens == 0
    if tokens_estimated and content_chars:
        completion_tokens = max(1, content_chars // 4)
        reasoning_tokens = 0

    # Three distinct latencies, because a reasoning model makes them differ:
    #   ttft_ms            first token of ANY kind (reasoning or content)
    #   ttft_reasoning_ms  first reasoning token (None for non-reasoning models)
    #   ttft_content_ms    first visible content token = what the user waits for
    ttft_ms = None if first_token_at is None else round((first_token_at - started) * 1000)
    ttft_reasoning_ms = (
        None
        if first_reasoning_at is None
        else round((first_reasoning_at - started) * 1000)
    )
    ttft_content_ms = (
        None if first_content_at is None else round((first_content_at - started) * 1000)
    )
    total_ms = round((ended - started) * 1000)
    generation_s = (
        None
        if first_token_at is None
        else round(max(0.0, ended - first_token_at), 3)
    )
    content_s = (
        None
        if first_content_at is None or last_content_at is None
        else round(last_content_at - first_content_at, 3)
    )

    tps_effective = (
        None
        if not generation_s or generation_s <= 0
        else round(completion_tokens / generation_s, 2)
    )
    content_tokens = max(0, completion_tokens - reasoning_tokens)
    tps_content = (
        None
        if not content_s or content_s <= 0
        else round(content_tokens / content_s, 2)
    )

    # A gateway can buffer the whole upstream reply and flush it at once. The
    # client then sees every chunk land in a few milliseconds after the stall,
    # which would read as an absurd decode rate. Two signals catch it:
    #   1. chunks arriving faster than any plausible token rate, and
    #   2. the whole payload landing in a sliver of the total request time,
    #      meaning it was delivered in one gulp at the end.
    chunk_rate = (
        None
        if not generation_s or generation_s <= 0 or chunks < 2
        else round((chunks - 1) / generation_s, 1)
    )
    max_chunk_rate = float(
        target.get("max_chunk_rate", spec.get("max_chunk_rate", 1000))
    )
    # Fraction of the request spent after the first token. A true stream
    # spends most of its time here; a buffered one spends almost none.
    delivered_ratio = (
        None
        if not total_ms or total_ms <= 0 or generation_s is None
        else round(generation_s / (total_ms / 1000), 3)
    )
    burst = False
    if chunk_rate is not None and chunk_rate > max_chunk_rate:
        burst = True
    elif (
        delivered_ratio is not None
        and delivered_ratio < 0.25
        and chunk_rate is not None
        and chunk_rate > 50
    ):
        burst = True

    # Wall-clock throughput: tokens per second of the user's whole wait. This
    # stays honest when the response is buffered, because it includes the stall.
    tps_wall = (
        None
        if not total_ms or total_ms <= 0
        else round(completion_tokens / (total_ms / 1000), 2)
    )

    truncated = finish_reason == "length"
    # Only meaningful for a run that actually completed; a failed request
    # never produced content, which is not the same as producing none.
    no_content = error is None and first_content_at is None

    # A relay that ignores max_tokens returns MORE tokens than the cap it was
    # sent. That is not truncation, it is a different contract violation: the
    # merchant is pouring out a pre-generated answer, so the throughput figure
    # is a flush rate and not a decode rate. Truncation and cap violation are
    # separate exclusions and a run can be either or both.
    max_tokens_sent = int(target.get("max_tokens", spec.get("max_tokens", 3000)))
    cap_violation = (
        error is None and not tokens_estimated and completion_tokens > max_tokens_sent
    )
    # Tokens per SSE chunk. A genuine stream delivers about one token per
    # chunk; a bulk flush delivers many. Unlike the burst heuristic this does
    # not depend on the timing of the flush, only on the payload shape.
    tokens_per_chunk = None if not chunks else round(completion_tokens / chunks, 2)
    # Bulk delivery: the payload arrived in gulps, so any rate computed over
    # the generation window is the speed of the socket, not the speed of the
    # model. The burst heuristic above catches one flush at the very end; this
    # catches a relay that dribbles a pre-generated answer out in multi-token
    # chunks, which the burst test does not see at all.
    max_tokens_per_chunk = float(
        target.get("max_tokens_per_chunk", spec.get("max_tokens_per_chunk", 10))
    )
    bulk_delivery = (
        tokens_per_chunk is not None and tokens_per_chunk >= max_tokens_per_chunk
    )

    return {
        "status": status,
        "error": error,
        "model_seen": model_seen,
        "chunks": chunks,
        "finish_reason": finish_reason,
        "truncated": truncated,
        "no_content": no_content,
        "ttft_ms": ttft_ms,
        "ttft_reasoning_ms": ttft_reasoning_ms,
        "ttft_content_ms": ttft_content_ms,
        "total_ms": total_ms,
        "generation_s": generation_s,
        "content_window_s": content_s,
        "completion_tokens": completion_tokens,
        "reasoning_tokens": reasoning_tokens,
        "content_tokens": content_tokens,
        "tokens_estimated": tokens_estimated,
        "tps_effective": tps_effective,
        "tps_content": tps_content,
        "tps_wall": tps_wall,
        "chunk_rate": chunk_rate,
        "delivered_ratio": delivered_ratio,
        "burst": burst,
        "cap_violation": cap_violation,
        "max_tokens": max_tokens_sent,
        "tokens_per_chunk": tokens_per_chunk,
        "max_tokens_per_chunk": max_tokens_per_chunk,
        "bulk_delivery": bulk_delivery,
        "content_chars": content_chars,
        "reasoning_chars": reasoning_chars,
    }


def median(values: list[float | None]) -> float | None:
    clean = [v for v in values if v is not None]
    return round(statistics.median(clean), 2) if clean else None


def summarize(target_name: str, runs: list[dict[str, Any]]) -> dict[str, Any]:
    ok = [r for r in runs if r.get("error") is None and r.get("tps_effective") is not None]
    # A burst run was buffered by the gateway and flushed at once, so its
    # generation-window TPS is an artifact. A run that arrived in multi-token
    # gulps is the same problem with the same answer. Neither belongs in a
    # throughput ranking, but both stay in the latency stats, which are still
    # valid. A run that came back over its max_tokens cap is reported but not
    # excluded: the relay ignored the budget, which is a contract violation
    # worth naming, yet the stream itself may still be a real decode.
    streamed = [r for r in ok if not r.get("burst") and not r.get("bulk_delivery")]
    median_stream = median([r["tps_effective"] for r in streamed])
    median_wall = median([r["tps_wall"] for r in ok])
    # When the gateway buffers every response, the generation window carries no
    # information about decode speed. Rank on wall-clock throughput instead and
    # say so, rather than printing a column of dashes.
    if median_stream is not None:
        rank_tps, rank_source = median_stream, "stream"
    else:
        rank_tps, rank_source = median_wall, "wall"
    return {
        "target": target_name,
        "runs": len(runs),
        "ok_runs": len(ok),
        "failed_runs": len(runs) - len(ok),
        "burst_runs": sum(1 for r in ok if r.get("burst")),
        "rank_tps": rank_tps,
        "rank_source": rank_source,
        "median_tps_effective": median_stream,
        "max_tps_effective": max((r["tps_effective"] for r in streamed), default=None),
        "min_tps_effective": min((r["tps_effective"] for r in streamed), default=None),
        "median_tps_content": median([r["tps_content"] for r in streamed]),
        "median_tps_wall": median_wall,
        "median_ttft_ms": median([r["ttft_ms"] for r in ok]),
        "min_ttft_ms": min((r["ttft_ms"] for r in ok if r["ttft_ms"] is not None), default=None),
        "max_ttft_ms": max((r["ttft_ms"] for r in ok if r["ttft_ms"] is not None), default=None),
        "median_ttft_reasoning_ms": median(
            [r["ttft_reasoning_ms"] for r in ok if r["ttft_reasoning_ms"] is not None]
        ),
        "median_ttft_content_ms": median(
            [r["ttft_content_ms"] for r in ok if r["ttft_content_ms"] is not None]
        ),
        "max_ttft_content_ms": max(
            (r["ttft_content_ms"] for r in ok if r["ttft_content_ms"] is not None),
            default=None,
        ),
        "median_total_ms": median([r["total_ms"] for r in ok]),
        "median_completion_tokens": median([r["completion_tokens"] for r in ok]),
        "truncated_runs": sum(1 for r in ok if r.get("truncated")),
        "no_content_runs": sum(1 for r in ok if r.get("no_content")),
        "cap_violation_runs": sum(1 for r in ok if r.get("cap_violation")),
        "bulk_delivery_runs": sum(1 for r in ok if r.get("bulk_delivery")),
        "median_tokens_per_chunk": median([r["tokens_per_chunk"] for r in ok]),
    }


def render_table(summaries: list[dict[str, Any]]) -> str:
    header = (
        f"{'target':<22}{'ok':>7}{'TPS':>9}{'src':>6}{'wallTPS':>9}"
        f"{'TTFT':>9}{'TTFTmax':>9}{'TTFTc':>9}{'medTok':>9}"
    )
    lines = [header, "-" * len(header)]

    def fmt(value: float | None, scale: float = 1.0, digits: int = 1) -> str:
        if value is None:
            return "-"
        return f"{value / scale:.{digits}f}"

    for s in sorted(summaries, key=lambda x: (x["rank_tps"] or -1), reverse=True):
        lines.append(
            f"{str(s['target']):<22}"
            f"{s['ok_runs']:>3}/{s['runs']:<3}"
            f"{fmt(s['rank_tps']):>9}"
            f"{s.get('rank_source', 'stream'):>6}"
            f"{fmt(s['median_tps_wall']):>9}"
            f"{fmt(s['median_ttft_ms'], 1000.0):>9}"
            f"{fmt(s['max_ttft_ms'], 1000.0):>9}"
            f"{fmt(s['median_ttft_content_ms'], 1000.0):>9}"
            f"{fmt(s['median_completion_tokens'], 1.0, 0):>9}"
        )
    lines.append("")
    lines.append("TTFT = median time to first token (any kind), TTFTmax = slowest run's")
    lines.append("first token, TTFTc = median time to first visible content token.")
    lines.append("TPS src = stream means the generation window; wall means the whole wait.")
    lines.append("wallTPS = tokens per second of the user's whole wait, including the stall.")
    for s in summaries:
        if s.get("truncated_runs") or s.get("no_content_runs"):
            lines.append(
                f"WARNING {s['target']}: {s['truncated_runs']} truncated, "
                f"{s['no_content_runs']} with no visible content."
            )
        if s.get("burst_runs"):
            lines.append(
                f"WARNING {s['target']}: {s['burst_runs']} run(s) were buffered by the "
                "gateway and flushed at once, so the generation window does not "
                "reflect decode speed; ranked on wall-clock throughput instead."
            )
        if s.get("bulk_delivery_runs"):
            lines.append(
                f"WARNING {s['target']}: {s['bulk_delivery_runs']} run(s) arrived in "
                "multi-token gulps, so the generation window measures the speed of "
                "the socket rather than the speed of the model; excluded from the "
                "throughput ranking."
            )
        if s.get("cap_violation_runs"):
            lines.append(
                f"WARNING {s['target']}: {s['cap_violation_runs']} run(s) returned MORE "
                "tokens than the max_tokens cap they were sent, so the relay ignored "
                "the budget and the sample is not the workload that was requested."
            )
    return "\n".join(lines)


def run_target(
    target: dict[str, Any],
    spec: dict[str, Any],
    runs_per_target: int,
    delay: float,
) -> list[dict[str, Any]]:
    """Run every requested sample for one target and report progress."""
    name = str(target.get("name") or target.get("model") or "target")
    api_key = read_secret(target)
    runs: list[dict[str, Any]] = []
    for index in range(runs_per_target):
        result = measure_once(target, spec, api_key)
        runs.append(result)
        status = "err" if result["error"] else "ok"
        flags = ""
        if result.get("truncated"):
            flags += " [truncated]"
        if result.get("no_content"):
            flags += " [no content]"
        if result.get("burst"):
            flags += " [buffered flush]"
        if result.get("bulk_delivery"):
            flags += f" [bulk delivery: {result['tokens_per_chunk']} tok/chunk]"
        if result.get("cap_violation"):
            flags += f" [over cap: {result['completion_tokens']} > {result['max_tokens']}]"
        print(
            f"[{name}] run {index + 1}/{runs_per_target} {status} "
            f"ttft={result['ttft_ms']}ms "
            f"ttft_content={result['ttft_content_ms']}ms "
            f"tok={result['completion_tokens']} "
            f"tps={result['tps_effective']} "
            f"wall_tps={result['tps_wall']}{flags}",
            file=sys.stderr,
            flush=True,
        )
        if result["error"]:
            print(f"    {result['error']}", file=sys.stderr, flush=True)
        if index + 1 < runs_per_target:
            time.sleep(delay)
    return runs


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spec", required=True, help="path to the JSON spec file")
    parser.add_argument("--out", help="write full results as JSON to this path")
    parser.add_argument("--runs", type=int, help="override the spec's run count")
    parser.add_argument("--target", action="append", help="only run these target names")
    parser.add_argument("--delay", type=float, default=1.5, help="seconds between runs")
    parser.add_argument(
        "--parallel",
        action="store_true",
        help="run targets concurrently instead of one at a time; the spec may also "
        "set \"parallel\": true. Cross-check a subset sequentially before reporting",
    )
    parser.add_argument(
        "--max-workers",
        type=int,
        default=0,
        help="cap on concurrently running targets when --parallel is set (0 = all)",
    )
    args = parser.parse_args()

    spec_path = Path(args.spec).expanduser()
    try:
        spec = json.loads(spec_path.read_text())
    except OSError as exc:
        die(f"cannot read spec {spec_path}: {exc}")
    except json.JSONDecodeError as exc:
        die(f"spec is not valid JSON: {exc}")

    targets = spec.get("targets") or []
    if not targets:
        die("spec has no targets")
    if args.target:
        wanted = set(args.target)
        targets = [t for t in targets if t.get("name") in wanted]
        if not targets:
            die("no targets matched --target")

    runs_per_target = args.runs or int(spec.get("runs", 2))

    # Sequential is the default because parallel calls contend for bandwidth
    # and for shared upstream quota. When the schedule forces a parallel
    # sweep, measure a subset sequentially as well so the report can quantify
    # what the concurrency cost instead of assuming it was free.
    parallel = bool(args.parallel or spec.get("parallel"))
    max_workers = args.max_workers or int(spec.get("max_workers") or 0)

    results: dict[str, list[dict[str, Any]]] = {}
    if parallel:
        workers = max_workers or len(targets)
        workers = max(1, min(workers, len(targets)))
        print(
            f"running {len(targets)} targets, {workers} at a time",
            file=sys.stderr,
            flush=True,
        )
        with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
            futures = {
                pool.submit(run_target, target, spec, runs_per_target, args.delay): str(
                    target.get("name") or target.get("model") or "target"
                )
                for target in targets
            }
            for future in concurrent.futures.as_completed(futures):
                results[futures[future]] = future.result()
    else:
        for target in targets:
            name = str(target.get("name") or target.get("model") or "target")
            results[name] = run_target(target, spec, runs_per_target, args.delay)

    summaries = [summarize(name, runs) for name, runs in results.items()]
    print()
    print(render_table(summaries))

    if args.out:
        out_path = Path(args.out).expanduser()
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(
            json.dumps(
                {
                    "spec": {k: v for k, v in spec.items() if k != "targets"},
                    "mode": "parallel" if parallel else "sequential",
                    "summaries": summaries,
                    "runs": results,
                },
                indent=2,
            )
        )
        print(f"\nwrote {out_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
