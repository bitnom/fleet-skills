#!/usr/bin/env python3
"""List SubRouter marketplace providers for a model with effective USD pricing.

Public endpoints only; no credentials required.

    python3 subrouter_providers.py --model deepseek-v4.1-flash-1017
    python3 subrouter_providers.py --model deepseek-v4.1-flash-1017 \
        --max-output-usd 0.10 --json

The filters are the usual qualification criteria for a provider: input and
output price per 1M tokens, cache hit rate, and availability. A merchant with
no cache hit rate reading and no traffic is dropped by default, because a
missing reading cannot satisfy "cache hit rate must be above N" and these
merchants are usually dead upstream.

Price handling matters here. The marketplace reports ``output_price`` as 0
for any provider that bills through a ``tiered_expr``, even though the real
price lives inside ``billing_expr``. Reading ``output_price`` alone makes
such a merchant look free, so this script always resolves the effective
output price from the billing expression when one is present.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from typing import Any

DEFAULT_BASE = "https://subrouter.ai"


def get_json(url: str, timeout: int = 60) -> dict[str, Any]:
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as exc:
        raise SystemExit(f"HTTP {exc.code} for {url}: {exc.read().decode('utf-8','replace')[:200]}")
    except Exception as exc:  # noqa: BLE001
        raise SystemExit(f"failed to fetch {url}: {type(exc).__name__}: {exc}")


def exchange_rate(base: str) -> tuple[float, str]:
    """Return (CNY per USD, source) so CNY prices can be normalized."""
    try:
        status = get_json(f"{base}/api/status", timeout=30)
    except SystemExit:
        return 1.0, "default (status unreachable)"
    data = status.get("data", status)
    rate = data.get("price")
    if not isinstance(rate, (int, float)) or rate <= 0:
        return 1.0, "default (status has no usable price)"
    display = data.get("quota_display_type", "CNY")
    return float(rate), f"/api/status price={rate} quota_display_type={display}"


def first_tier_body(expr: str) -> str:
    """Return the body of the first tier(...) in a billing expression."""
    match = re.search(r'tier\s*\(\s*"[^"]*"\s*,(.*)', expr, re.S)
    if not match:
        return expr
    body = match.group(1)
    depth = 1
    out = []
    for char in body:
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                break
        out.append(char)
    return "".join(out)


def coefficient(body: str, variable: str) -> float | None:
    """Extract the multiplier applied to `variable` (e.g. 'c' or 'p') in a tier body."""
    patterns = [
        rf"\b{variable}\s*\*\s*([0-9]*\.?[0-9]+)",
        rf"([0-9]*\.?[0-9]+)\s*\*\s*\b{variable}\b",
    ]
    for pattern in patterns:
        match = re.search(pattern, body)
        if match:
            return float(match.group(1))
    return None


def effective_prices(entry: dict[str, Any]) -> tuple[float, float, str]:
    """Return (input_per_m, output_per_m, note) in the listing's own currency."""
    mode = entry.get("billing_mode") or "ratio"
    if mode == "tiered_expr" and entry.get("billing_expr"):
        body = first_tier_body(entry["billing_expr"])
        out = coefficient(body, "c")
        inp = coefficient(body, "p")
        if out is not None:
            return (
                inp if inp is not None else 0.0,
                out,
                "from tiered_expr (first tier; long-context tiers may differ)",
            )
    return (
        float(entry.get("input_price") or 0.0),
        float(entry.get("output_price") or 0.0),
        "from listed prices",
    )


def to_usd(amount: float, currency: str, rate: float) -> float:
    if currency == "USD":
        return amount
    return amount / rate if rate else amount


def cache_hit_rate_of(entry: dict[str, Any]) -> float | None:
    """Return the cache hit rate as a percentage, or None when there is no reading.

    The platform stores "no reading" as -1 on some listings and omits the field
    on others. A missing reading is not a zero and not a pass: it means the
    merchant has no measurable cache traffic, which for a filter like
    "cache hit rate must be above 80%" is a failure, not an exemption.
    """
    value = entry.get("cache_hit_rate")
    if value is None:
        return None
    try:
        value = float(value)
    except (TypeError, ValueError):
        return None
    return value if value >= 0 else None


def looks_dead(entry: dict[str, Any]) -> bool:
    """True when a listing shows the signature of a merchant that is not serving.

    No cache reading, no availability reading and zero requests together mean
    the merchant has never carried traffic. These still pass a price filter,
    so they have to be filtered out explicitly rather than discovered late.
    """
    requests = entry.get("total_requests") or 0
    return (
        cache_hit_rate_of(entry) is None
        and (entry.get("availability") is None or entry.get("availability") < 0)
        and int(requests) == 0
    )


def discount_percent(entry: dict[str, Any]) -> float | None:
    """Return the discount against the official price as a positive percentage.

    The platform stores it as a negative number (``official_discount_percent``
    of -97.5 means 97.5% off). None means the listing carries no comparison
    against the official price, which is not a pass for a "at least N% off"
    filter.
    """
    value = entry.get("official_discount_percent")
    if value is None:
        return None
    try:
        value = float(value)
    except (TypeError, ValueError):
        return None
    return abs(value)


def is_shared_plan(entry: dict[str, Any]) -> bool:
    """True when the listing's provider_id is a shared plan, not a real merchant.

    Shared-plan ids look like ``shared-plan:5``. They cannot be subscribed to
    as a provider: the platform rejects every subscribe form of them with
    参数错误, so the matching ``provider:<slug>`` group stays empty and a
    fixed key for it returns 403. Such a listing can be measured only through
    smart routing, never pinned, so it has to be reported separately.
    """
    provider_id = entry.get("provider_id")
    return isinstance(provider_id, str) and provider_id.startswith("shared-plan:")


def is_unproven(entry: dict[str, Any]) -> bool:
    """True when a merchant has carried too little traffic to trust its stats.

    A handful of lifetime requests means the marketplace's cache hit rate,
    median TTFT and availability are computed from almost nothing and move
    on the next request. The merchant can still work; its published numbers
    just do not describe it yet.
    """
    requests = entry.get("total_requests")
    if requests is None:
        return False
    try:
        requests = int(requests)
    except (TypeError, ValueError):
        return False
    return requests < 100


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True, help="model name keyword to search")
    parser.add_argument("--base", default=DEFAULT_BASE, help="SubRouter base URL")
    parser.add_argument("--max-output-usd", type=float, help="only show providers at or below this output price per 1M tokens")
    parser.add_argument("--max-input-usd", type=float, help="only show providers at or below this input price per 1M tokens")
    parser.add_argument("--min-cache-hit-rate", type=float, help="only show providers at or above this cache hit rate (percent)")
    parser.add_argument(
        "--min-discount",
        type=float,
        help="only show listings at or beyond this discount against the official price (percent)",
    )
    parser.add_argument(
        "--include-unproven",
        action="store_true",
        help="keep merchants with fewer than 100 lifetime requests instead of flagging them",
    )
    parser.add_argument("--min-availability", type=float, help="only show providers at or above this availability (percent)")
    parser.add_argument(
        "--include-unknown-cache",
        action="store_true",
        help="keep providers with no cache hit rate reading instead of dropping them",
    )
    parser.add_argument(
        "--include-dead",
        action="store_true",
        help="keep merchants that show the signature of a non-serving provider",
    )
    parser.add_argument("--page-size", type=int, default=100)
    parser.add_argument("--json", action="store_true", help="emit JSON instead of a table")
    args = parser.parse_args()

    base = args.base.rstrip("/")
    rate, rate_source = exchange_rate(base)

    payload = get_json(
        f"{base}/api/marketplace/models?page=1&page_size={args.page_size}&keyword={args.model}"
    )
    entries = payload.get("data") or []
    if not entries:
        print(f"no marketplace listings matched {args.model!r}", file=sys.stderr)

    rows = []
    for entry in entries:
        input_native, output_native, note = effective_prices(entry)
        currency = entry.get("price_currency") or "CNY"
        output_usd = to_usd(output_native, currency, rate)
        input_usd = to_usd(input_native, currency, rate)
        rows.append(
            {
                "provider_id": entry.get("provider_id"),
                "provider_slug": entry.get("provider_slug"),
                "provider_name": entry.get("provider_name"),
                "listing_id": entry.get("id"),
                "model_name": entry.get("model_name"),
                "upstream_model": entry.get("upstream_model"),
                "output_usd_per_m": round(output_usd, 6),
                "input_usd_per_m": round(input_usd, 6),
                "currency": currency,
                "output_native": output_native,
                "price_note": note,
                "availability": entry.get("availability"),
                "total_requests": entry.get("total_requests"),
                "median_ttft_ms": entry.get("median_ttft"),
                "cache_hit_rate": cache_hit_rate_of(entry),
                "cache_hit_rate_known": cache_hit_rate_of(entry) is not None,
                "discount_percent": discount_percent(entry),
                "official_output_price": entry.get("official_output_price"),
                "cache_read_price": entry.get("cache_read_price"),
                "effective_cache_read_price": entry.get("effective_cache_read_price"),
                "official_cache_read_price": entry.get("official_cache_read_price"),
                "price_multiplier": entry.get("price_multiplier"),
                "guarantee_level": entry.get("provider_guarantee_level"),
                "is_shared_plan": is_shared_plan(entry),
                "unproven": is_unproven(entry),
                "looks_dead": looks_dead(entry),
                "price_currency": currency,
            }
        )

    rows.sort(key=lambda r: r["output_usd_per_m"])
    if args.max_output_usd is not None:
        rows = [r for r in rows if r["output_usd_per_m"] <= args.max_output_usd]
    if args.max_input_usd is not None:
        rows = [r for r in rows if r["input_usd_per_m"] <= args.max_input_usd]
    if args.min_cache_hit_rate is not None:
        rows = [
            r
            for r in rows
            if (r["cache_hit_rate"] is not None and r["cache_hit_rate"] >= args.min_cache_hit_rate)
            or (r["cache_hit_rate"] is None and args.include_unknown_cache)
        ]
    if args.min_availability is not None:
        rows = [
            r
            for r in rows
            if r["availability"] is not None and r["availability"] >= args.min_availability
        ]
    if args.min_discount is not None:
        rows = [
            r
            for r in rows
            if r["discount_percent"] is not None
            and r["discount_percent"] >= args.min_discount
        ]
    if not args.include_dead:
        rows = [r for r in rows if not r["looks_dead"]]

    if args.json:
        print(
            json.dumps(
                {
                    "model": args.model,
                    "exchange_rate_cny_per_usd": rate,
                    "exchange_rate_source": rate_source,
                    "filters": {
                        "max_input_usd": args.max_input_usd,
                        "max_output_usd": args.max_output_usd,
                        "min_cache_hit_rate": args.min_cache_hit_rate,
                        "min_availability": args.min_availability,
                        "min_discount": args.min_discount,
                        "include_unknown_cache": args.include_unknown_cache,
                        "include_dead": args.include_dead,
                    },
                    "providers": rows,
                },
                indent=2,
            )
        )
        return 0

    print(f"model keyword: {args.model}")
    print(f"exchange rate: {rate} CNY per USD ({rate_source})")
    print()
    header = (
        f"{'provider':<14}{'id':>5}{'out$/M':>10}{'in$/M':>10}{'disc%':>7}"
        f"{'avail%':>8}{'cache%':>8}{'ttft':>9}{'reqs':>8}  flags"
    )
    print(header)
    print("-" * len(header))
    for row in rows:
        ttft = row["median_ttft_ms"]
        ttft_text = "-" if not ttft else f"{ttft}ms"
        avail = row["availability"]
        avail_text = "-" if avail is None or avail < 0 else f"{avail:.1f}"
        cache = row["cache_hit_rate"]
        cache_text = "?" if cache is None else f"{cache:.1f}"
        discount = row["discount_percent"]
        discount_text = "-" if discount is None else f"{discount:.2f}"
        flags = []
        if cache is None:
            flags.append("no-cache-reading")
        if row["looks_dead"]:
            flags.append("dead")
        if row["is_shared_plan"]:
            flags.append("shared-plan: cannot be pinned")
        if row["unproven"]:
            flags.append("unproven: too few requests")
        if row["price_note"] != "from listed prices":
            flags.append(row["price_note"])
        print(
            f"{str(row['provider_slug']):<14}"
            f"{row['provider_id']:>5}"
            f"{row['output_usd_per_m']:>10.4f}"
            f"{row['input_usd_per_m']:>10.4f}"
            f"{discount_text:>7}"
            f"{avail_text:>8}"
            f"{cache_text:>8}"
            f"{ttft_text:>9}"
            f"{row['total_requests'] or 0:>8}"
            f"  {', '.join(flags)}"
        )
    if not rows:
        print("(no provider passed the filters)")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BrokenPipeError:
        # A downstream reader (head, less) closed the pipe. Exit quietly
        # instead of printing a traceback over the table.
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        raise SystemExit(0)
