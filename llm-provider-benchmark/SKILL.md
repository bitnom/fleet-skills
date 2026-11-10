---
name: llm-provider-benchmark
description: Measure throughput and latency for LLM providers and models - tokens per second, time to first token, TTFT, TTFT to first visible content, and generation window - across OpenAI-compatible endpoints. Use when comparing providers or merchants for speed or latency, when the vendor publishes no benchmark, when validating a new route, or when a provider needs to be ranked or pruned by throughput.
---

# LLM Provider Benchmark

Measure output speed and latency for one or more LLM providers so they can
be compared and ranked. Vendor-published numbers are often absent, stale, or
measured on different hardware; the only reliable figure is one you take
yourself against the route the user actually calls.

This skill is measurement-agnostic. For provider-specific setup, pairing, and
subscription management, use the provider's own skill (for SubRouter, see
`subrouter-provider-ops`).

## Where the run lives

Put every benchmark artefact in a subdirectory of `~/.cache/`, never in
`/tmp`:

```text
~/.cache/llm-provider-benchmark/<project-slug>/
    spec.json          the target list and workload
    results.json       the raw per-run output
    <report>.md        the finished report
```

`/tmp` is volatile. A report that lives there is a report the user will
discover is gone after a reboot, and a spec that lives there is a spec that
has to be rebuilt from scratch. Use `~/.cache/` for anything the user might
want to read, diff, or re-run later, and say where it is when you hand the
result over.

For SubRouter merchants the convention is `~/.cache/subrouter-benchmarks/`,
one subdirectory per model, because each model is its own run with its own
specs, results and report:

```text
~/.cache/subrouter-benchmarks/gpt-6.1-sol/
~/.cache/subrouter-benchmarks/deepseek-v4.1-flash-1017/
```

Re-running a benchmark should overwrite the previous run in place, not pile
up `spec2.json` / `results-final.json` copies. Keep the previous run's
report when the scope changed, because the diff between two runs is often
the most useful output of the second one.

## Decide the metric before measuring

Three different numbers get called "TPS". State which one you are reporting.

| Metric | Definition | Use when |
|---|---|---|
| **Effective output rate** | `completion_tokens / (last_token_time - first_token_time)` | Comparing end-to-end responsiveness of reasoning models. Includes reasoning tokens. |
| **Content rate** | `content_tokens / content_window` | Comparing raw decode speed of the visible answer. |
| **Total wall time** | request start to last byte | The number a user actually waits. |

For a reasoning model, effective output rate is usually the number that
matters: it charges every generated token, reasoning included, against the
time the user sat waiting. Report content rate alongside it when the split is
visible, and always report TTFT separately, because a provider can look fast
on throughput and still be unusable interactively.

## Report three latencies, not one

A single "TTFT" number is ambiguous on a reasoning model, and the ambiguity
hides the latency that matters. The script measures all three:

| Field | Meaning |
|---|---|
| `ttft_ms` | First token of **any** kind. On a reasoning model this is the first reasoning token. |
| `ttft_reasoning_ms` | First reasoning token. `None` for a non-reasoning model. |
| `ttft_content_ms` | First **visible content** token. This is what a user actually waits to see. |

`ttft_content_ms` is the number to lead with when a model reasons before
answering. On a reasoning model with a long think phase it can be several
seconds beyond `ttft_ms`, and that gap is invisible if you report only the
first token.

The summary table shows `TTFT` (median first token), `TTFTmax` (the slowest
run's first token, which is the number that predicts a bad experience), and
`TTFTc` (median time to first visible content).

A `TTFTc` of `-` means the model produced **no visible content at all**,
usually because `max_tokens` was consumed by reasoning before any answer was
emitted. That sample is not a usable latency measurement. Raise `max_tokens`
and rerun.

## Check whether the response was actually streamed

Some gateways generate the whole upstream reply, buffer it, then flush it to
the client in one gulp. The client sees hundreds of chunks land within
milliseconds after a long stall, and a naive calculation reads that as an
absurd decode rate: thousands of tokens per second.

The script detects this two ways and flags the run `[buffered flush]`:

- Chunks arriving faster than any plausible token rate (default threshold
  1000 chunks/sec, override with `max_chunk_rate` in the spec).
- The whole payload landing in under a quarter of the request time, which
  means it was delivered at the end rather than streamed.

A buffered run's generation-window TPS is an artifact and is excluded from
the throughput ranking. Its latency numbers stay valid, because the wait was
real. When every run for a target is buffered, the ranking falls back to
wall-clock throughput and the table says `src=wall`.

**Confirm buffering independently before trusting either number.** The
gateway's own request log is the cross-check: compare its `use_time` and
`frt` against the client-side timings. If the server recorded a
`use_time` of 4 seconds and a `frt` of 3.6 seconds, the server itself saw
only about 400ms of actual streaming, and any client-side generation rate
computed over that sliver is meaningless.

| Metric | Meaning |
|---|---|
| `tps_effective` | Generation-window rate. Valid only for a genuinely streamed response. |
| `tps_content` | Content-window rate. Same caveat. |
| `tps_wall` | Tokens per second of the user's whole wait, stall included. Always valid, and the honest number for a buffered route. |

When a route buffers, the meaningful throughput comparison between providers
is `tps_wall` and the latency comparison is TTFT. Report both and say the
route buffers, rather than quoting a generation rate that no user ever
experienced.

**The burst test has a blind spot.** It catches a response flushed in one
gulp at the end, but it misses a relay that dribbles a pre-generated answer
out steadily in multi-token chunks. That shape looks like a slow but
honest stream to every timing test. Check tokens per chunk as well — see
"Two different ways a route misbehaves" below.

**A route can think without telling you.** Some relays deliver
`delta.reasoning_content: null` on every chunk while the usage block reports
a large `reasoning_tokens` count: the model is thinking, and the thinking is
invisible to the client. The visible stream then starts minutes later, or
never arrives. The script reads `delta.reasoning` as well as
`delta.reasoning_content`, but a route that hides its reasoning in neither
field will still show a null first-token time. Treat a null `ttft_ms` with
a nonzero token count as "the route thinks in private", not as "the route
failed", and read the raw SSE before concluding either.

## Measure with the bundled script

`scripts/bench_llm_endpoint.py` is dependency-free and drives any
OpenAI-compatible `POST {base_url}/chat/completions` endpoint with
`stream: true`. It times the first token, the generation window, the content
window, and reports per-run and median throughput and latency.

Describe the targets in a JSON spec. Each target carries its own base URL,
key, model, and request-body overrides:

```json
{
  "targets": [
    {"name": "kriora",
     "base_url": "https://subrouter.ai/v1",
     "api_key_file": "/home/user/.config/subrouter/keys/kriora",
     "model": "deepseek-v4.1-flash-1017",
     "max_tokens": 3000,
     "extra_body": {"reasoning_effort": "max"}}
  ],
  "runs": 3,
  "prompt": "Write a detailed 700-word plain-prose explanation of how TCP congestion control works. No headings, no lists, just continuous prose.",
  "timeout_seconds": 240
}
```

Then run it:

```bash
python3 ~/.agents/skills/llm-provider-benchmark/scripts/bench_llm_endpoint.py \
  --spec "$RUN/spec.json" --out "$RUN/results.json"
```

Keys come from `api_key_file` (path) or `api_key_env` (variable name). The
script never prints a key, never writes one to the output file, and never
echoes one in an error message. It prints a ranked table to stdout and full
per-run detail to the JSON file.

**`timeout_seconds` bounds the whole request, not just each socket read.**
That distinction matters: a route that keeps an empty chunk trickling every
few minutes never trips a socket timeout and holds the request open
indefinitely. One route did exactly this and ran for eight minutes before
the sweep was stopped. The script enforces a wall-clock deadline inside the
read loop, so a route that will not finish inside the budget is recorded as
a timeout rather than stalling the sweep. Put a slow route last in the
target list so it cannot hold up the rest.

Useful flags: `--runs N` overrides the spec, `--target NAME` restricts the
sweep to named targets, `--delay SECONDS` spaces out runs, `--parallel` runs
the targets concurrently (see "Concurrency" below), `--max-workers N` caps
how many run at once.

## Two different ways a route misbehaves

`finish_reason: "length"` means the model ran out of budget. That is
truncation, and the sample measures the cap rather than the provider. Two
other failures look similar and need to be kept apart, because only one of
them invalidates a throughput number.

**Over the cap.** A relay can return **more** tokens than the `max_tokens`
it was sent. The request asked for 8 000 and the response carried 16 665.
That is a contract violation: the merchant ignored your budget, so the
sample is not the workload you asked for. Report it. Do not automatically
throw the sample out — the stream may still be a real decode. A route that
came back over a 2 000-token cap with 6 233 tokens at 58 tok/s was slow,
not fast; its rate was meaningful even though its budget was not respected.

**Bulk delivery.** The response arrives in gulps. Many tokens per SSE
chunk, so any rate computed over the generation window is the speed of the
socket, not the speed of the model. This one does invalidate the throughput
figure, and the route leaves the ranking.

The signal that detects it is **tokens per SSE chunk**. A genuine stream
delivers roughly one token per chunk; a bulk flush delivers many. The
script reports `tokens_per_chunk` for every run and flags
`bulk_delivery` at ten tokens per chunk, configurable with
`max_tokens_per_chunk` in the spec.

Do not rely on the burst heuristic alone for this. In one measured sweep of
eleven routes, tokens per chunk ran from 1.2 to 7.8 across every route that
decoded normally and 19.2 on the one that was flushing — and the burst
heuristic did not catch that route at all, because it dribbled the payload
out steadily at a modest 18 chunks per second rather than dumping it in one
gulp. Tokens per chunk is the signal that works.

| Exclusion | Detect it with | Keep the latency? | Keep the throughput? |
|---|---|---|---|
| Request failed | `error` is set | no | no |
| No visible content | `no_content` | no | no |
| Truncated at the cap | `truncated` | yes | no |
| Flushed in one gulp | `burst` | yes | no |
| Arrived in multi-token gulps | `bulk_delivery` | yes | no |
| Over the cap | `cap_violation` | yes | yes, but report it |

A target with only excluded runs falls back to wall-clock throughput, and
the table says `src=wall`.

## Concurrency

Parallel calls contend for the same local bandwidth and for shared upstream
quotas, so **sequential is the default**: one target at a time.

Sometimes the schedule does not allow that, and a concurrent sweep is the
right call. When it is, do not just assume the numbers are unaffected.
Measure a subset of the targets sequentially as well, then report the two
sets side by side so the reader can see what concurrency actually did.

A measured example: seven of eleven routes measured both ways, four came
out faster under concurrency and three slower, with no directional
penalty. The run-to-run spread was dominated by how long the model chose to
think, not by transport. That table is worth more than the assertion that
concurrency is fine.

```bash
# the concurrent sweep
python3 bench_llm_endpoint.py --spec spec.json --out results.json --parallel
# the cross-check, one target at a time
python3 bench_llm_endpoint.py --spec spec.json --out results-seq.json \
  --target kriora --target a6aa --target cheaprouter
```

The output file records `"mode": "parallel"` or `"sequential"`, so a later
reader can tell which is which without guessing.

**A run that is killed is still billed.** Stopping a request mid-flight does
not cancel it: the gateway completes the call and charges for it. One
aborted attempt in a measured run still cost quota, and it still produced a
row in the gateway's log with no client-side metrics attached to it. Reconcile
the log against your client runs and account for every row.


## Handling the keys

One key per target is the only way to attribute a measurement to a provider
when a gateway sits in between, so expect to create keys as part of the
work. Keep them in the user's credential directory at mode 600, one file per
target, referenced by `api_key_file`. Never paste a key into a spec, a
command line, a log, or a report; a file path is the only way a key should
enter the tooling.

If a key is created during the task, record which one it is so it can be
removed or rotated later. Keys scoped to a provider that is later
unsubscribed, or to a provider that stops being the target, become dead
weight and should be cleaned up once the work is done. See
`subrouter-provider-ops` for how SubRouter group keys behave when a
subscription changes.

## Choosing a workload

- **Use a fixed, long-form prompt for every target.** A short prompt measures
  time-to-first-token and little else. A few hundred words of continuous
  prose exercises sustained decoding and gives a stable denominator.
- **Set `max_tokens` high enough that the answer is not truncated.** When the
  response ends with `finish_reason: "length"`, the sample is measuring the
  cap rather than the provider. The script reports the finish reason and
  flags truncated runs.
- **Budget for the reasoning phase.** On a reasoning model, `max_tokens` is
  spent on reasoning first. If the cap is hit during the think phase, the
  model emits no visible answer at all and `ttft_content_ms` comes back
  `None`. A run like that measures nothing useful. Give the budget enough
  headroom that the model finishes thinking and still answers; the script
  flags these runs as `[truncated]` and `[no content]` and prints a warning
  under the table.
- **Set the reasoning effort explicitly** when comparing reasoning models, and
  use the same value for every target. Pass it in `extra_body`; for
  OpenAI-compatible routes that is usually `{"reasoning_effort": "max"}`.
- **Check that the effort parameter is honoured, not just accepted.** A
  gateway will happily pass a parameter the upstream ignores. On
  `minimax-m3.1-flash`, `reasoning_effort: max` turned out to be honoured —
  the response carried a reasoning stream and the usage block counted the
  thinking separately — while the model's own native flag,
  `reasoning_split: true`, was also accepted and made it think roughly twice
  as long on the same prompt (17 242 completion tokens against 9 481, first
  visible content at 58.4s against 44.1s). Check the usage block on one
  call before sweeping, and pick the parameter that actually does something.
- **A route may ignore `max_tokens` entirely.** The same minimax sweep had a
  route return 16 298 completion tokens against a 12 000-token cap while
  another returned 1 312. Treat the cap as a request, not a guarantee, and
  keep a wall-clock deadline so an unbounded route cannot stall the sweep.
- **Do not run targets concurrently by default.** Parallel calls contend
  for the same local bandwidth and for shared upstream quotas, and they
  distort the very number you are trying to measure. Measure sequentially,
  one target at a time. When the schedule forces a concurrent sweep, measure
  a subset sequentially too and report the comparison — see "Concurrency"
  above.

## Judge price per million, never per request

This is the rule that decides how a report's price column must be built.

A reasoning model decides on its own how long the answer is. The same prompt
produced answers between 931 and 8 244 tokens across the routes measured in
one sweep. If the price comparison is made on spend per request, then the
merchant whose upstream thought longest looks like the most expensive one,
and the comparison is really measuring the model's behaviour rather than the
merchant's price.

**Divide the spend by the tokens and quote the result per million.** The
gateway's own billing divided by the output tokens it delivered gives an
all-in price per 1M output tokens that carries the output price, the
provider's system prompt and its cache-read billing together, and it does not
move when the answer is long or short.

Two consequences worth stating in the report:

- A provider that is cheap per million can still be the expensive choice if
  it bills heavily on the input side. Report the listed price and the
  measured all-in price side by side, and the gap between them.
- The gap between listed and measured is not the model. It is the provider's
  own system prompt and its cache-read billing, and it is constant per
  request. A provider that injects a 350-token system prompt is charging for
  it on every call.

Use only the rows the benchmark itself produced when you compute this. Probe
traffic in the same window lands in the same log and will distort the
arithmetic.

## Read the results honestly

- **Take a median over at least 3 runs per target.** A single sample is
  usually noise. When the user says the schedule is tight, one run per
  target is a usable measurement, but it must be labelled as a single sample
  in the report and the mid-table treated as unordered.
- **Say how many samples each target got.** A report that mixes one-sample
  targets with three-sample targets without saying so reads as uniform.
- **Report the spread, not just the median.** Providers that swing between
  two modes are often routing across a heterogeneous backend pool, and a
  median hides that. Include min and max in the output table. The same
  applies to latency: report the slowest run's TTFT (`TTFTmax`), not only
  the median, because the tail is what a user actually notices.
- **Separate the slow tail from the fast path.** If most runs land near
  150 tok/s and a few land near 15, say so. The provider is not uniformly
  slow; it is inconsistent, which is a different problem with a different
  fix.
- **Confirm attribution.** When a gateway sits between you and the provider,
  check the gateway's own request log to confirm the request was served by the
  merchant you intended. Counting merchant-side request totals is a weak
  oracle because other tenants share the same counters.
- **Note the truncation and the reasoning split** in the final report so the
  numbers can be interpreted later.
- **Discard runs with no visible content** from the latency comparison. They
  mean the token budget ran out during reasoning, not that the provider was
  slow.
- **`status: 200` does not mean the run completed.** When the wall deadline
  fires, the script keeps the HTTP status and adds an `error` field, because
  the response did start: `status` is `200`, `error` is
  `TimeoutError: exceeded the Ns wall deadline`, and the partial metrics are
  still on the record. A report that filters on `status == 200` silently
  counts a cut-off run as a finished one. Filter on the error field as well.
- **Say whether a route ever finished.** A route that shows visible content
  but never completes an answer inside the deadline is a different thing from
  a route that answers quickly: the latency to first visible content is real,
  and the throughput is the rate of the part of the answer that arrived, so
  it is comparable, but the answer itself is not the workload that was
  requested. Report the route with that stated, and note that a gateway
  usually logs such a request with **zero** completion tokens, which means its
  price per million cannot be measured from the billing at all.
- **Put the excluded routes in their own table, not in a footnote.** A route
  excluded from the throughput ranking still has real latency and a real
  price. Show it with the reason it was excluded, so the reader can see that
  it was measured and judged rather than quietly dropped.
- **Say whether the route buffers.** If the runs were flagged
  `[buffered flush]`, the generation-window throughput is meaningless. Report
  wall-clock throughput and TTFT, and state plainly that the gateway buffers
  the response.

## Reporting format

Lead with the ranking table: provider, throughput, TTFT, TTFT to first
visible content, and the price or cost context the user cares about. Then
state the method in a few lines: what was measured, how many samples, over
what prompt, at what reasoning effort, and from where. Then give the caveats
that would change the reader's interpretation.

Always disclose what the measurement cost and whether any keys or account
state were created to obtain it. Say where the raw results and the report
were written.

### Rank on three length-independent axes

**Stability gates the ranking; it does not enter the score.** The three axes
below are medians, so without a gate a route whose worst run is materially
worse than its median can out-rank a steadier one on the strength of its
good runs alone. Read the spread before ranking: when the worst run is
materially worse than the median on the axis the caller depends on (usually
time to first visible content), the route stays **listed** and stops being
**promoted** — report it, name it inconsistent, and keep it out of the
frontier and out of any "use these" recommendation. Report the spread and
the worst run beside the score either way; the score itself does not absorb
variance.

A ranking that mixes in anything proportional to the answer's length is
ranking the model's thinking rather than the provider. The three axes below
are all independent of how long the model chose to think, and the score is
the sum of the three ranks, lowest wins:

| Axis | Direction | Why it is length-independent |
|---|---|---|
| all-in cost per 1M output tokens | lower is better | billed per token, not per request |
| time to first visible content | lower is better | a property of when the answer starts, not how long it is |
| wall-clock throughput | higher is better | tokens per second of the whole wait |

Ties break on time to first visible content. Report the component ranks or
the raw values so the reader can see what the score is made of, and say
plainly in the text when the ranking method changed between runs, because a
changed order is then not a change in the measurements.

Mark the **frontier** as well: the providers that nothing else beats on all
three axes at once. A merchant is dominated when some other merchant is at
least as cheap, at least as quick to show content, and at least as fast
sustained. The frontier is a short, defensible answer to "which few should
I actually use", and it is different information from the score.

### Name every provider twice

Every table and every sentence that names a provider must give both its
marketplace display name and its slug: `zZ 妞` is `znu`, `Guansji API` is
`stableai`. The display name is what the reader sees on the marketplace page
and the slug is what the API, the key store and the group names use. One
without the other leaves the reader guessing which identifier a row refers
to, and the two are the same string for only a few merchants. Use one helper
for the label so every table is formatted the same way.

When the sweep was concurrent and a sequential cross-check exists, include
the comparison as a table in the report. It is evidence, not a footnote.

A good report reads like this:

| Provider | TPS | src | Out $/M | TTFT median | TTFT worst | TTFT to content |
|---|---:|:--|---:|---:|---:|---:|
| acme | 214.6 | stream | 0.0399 | 4.0s | 6.2s | 4.9s |
| globex | 58.6 | wall | 0.0412 | 8.4s | 15.1s | 9.0s |

"4 samples per provider, sequential, `reasoning_effort: max`, 700-word
prose prompt, `max_tokens` 6000, measured from this host. TTFT is time to
first token of any kind; the rightmost latency column is time to first
visible content, which is what a user waits for. acme's worst run took 6.2s
to first token against a 4.0s median. globex's gateway buffers the whole
response and flushes it at once, so its throughput is wall-clock and its
generation window is not a decode measurement. Run cost about $0.02 in
quota."
