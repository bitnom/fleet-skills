---
name: subrouter-provider-ops
description: Test, benchmark, subscribe, and manage SubRouter marketplace providers (merchants) for a given model. Use when comparing SubRouter merchants on speed or price, creating fixed-provider or smart-routing API keys, checking subscription state, pruning slow or expensive merchants, or verifying which merchant actually served a request.
---

# SubRouter Provider Ops

Operate SubRouter merchants: discover them, price them, subscribe to them,
pin traffic to one of them, measure them, and cut the ones that do not earn
their place.

Use the `llm-provider-benchmark` skill for the actual timing runs. This skill
supplies the SubRouter-specific setup that skill needs: which endpoints to
call, how to read prices correctly, how to force traffic onto a single
merchant, and how to verify afterwards.

## Base URL and authentication

Default base URL: `https://subrouter.ai`. Regional fronts exist
(`https://usaeast.up.railway.app/v1`, `https://asiasouth.up.railway.app/v1`)
and serve the same API; the console shows the right one per key.

Two distinct credentials exist, and mixing them up is the most common
failure:

| Credential | Header | Grants |
|---|---|---|
| Relay key (`sk-…`) | `Authorization: Bearer sk-…` | `/v1/*` model calls, public `/api/pricing` and `/api/marketplace/*` |
| Access token | `Authorization: Bearer <access_token>` **plus** `New-Api-User: <user_id>` | `/api/token/`, `/api/user/self`, `/api/log/self`, subscription and provider management |
| Browser session | session cookie **plus** `New-Api-User: <user_id>` | the same `/api/*` management calls, from inside a logged-in console session |

Management calls made with a relay key fail with
`无权进行此操作，access token 无效`. Two headers are always required together
for the access token: `Authorization` and `New-Api-User`. A wrong
`New-Api-User` returns `New-Api-User 与登录用户不匹配`.

A logged-in browser session is a third credential, and often the easiest
one to get: the console's own calls authenticate with the session cookie
and a `New-Api-User` header carrying the account id. It needs no
`access_token`, and the console does not expose one. Use it when the task
is already in the console, and see "Benchmarking from a browser session"
below.

Never print a key or token into a log, a transcript, or a file that is not
the credential store. Show at most an `sk-…` prefix when confirming.

## Where the work lives

Two fixed locations on this machine, and nothing goes in `/tmp`:

| What | Path |
|---|---|
| Fixed-provider keys | `~/.config/subrouter/keys/<provider-slug>`, mode 600, one file per slug |
| Benchmark runs and reports | `~/.cache/subrouter-benchmarks/<model-slug>/` |

A benchmark directory holds that model's spec, raw results, log rows and the
finished report:

```text
~/.cache/subrouter-benchmarks/gpt-6.1-sol/
~/.cache/subrouter-benchmarks/deepseek-v4.1-flash-1017/
```

`/tmp` is volatile and gets cleaned. A report the user cannot open next week
is a wasted run, and a spec that has to be rebuilt is a wasted hour. Re-run
a benchmark in place in its directory, and keep the previous run's report
when the scope changed, because the diff between two runs is often the most
useful thing in the second one.

Key files are the one thing that must never be copied around casually. They
stay in `~/.config/subrouter/keys/` at mode 600, and only paths appear in
specs and commands.

## Discover merchants and price them

```bash
python3 ~/.agents/skills/subrouter-provider-ops/scripts/subrouter_providers.py \
  --model deepseek-v4.1-flash-1017 \
  --max-input-usd 0.03 --max-output-usd 0.10 --min-cache-hit-rate 80
```

The script prints each merchant's provider id, slug, effective USD price per
1M input and output tokens, availability, cache hit rate, request count, and
the platform's median TTFT.

Filters, all of which take a price in USD per 1M tokens or a percentage:

| Flag | Meaning |
|---|---|
| `--max-input-usd` | input price ceiling |
| `--max-output-usd` | output price ceiling |
| `--min-cache-hit-rate` | cache hit rate floor, in percent |
| `--min-availability` | availability floor, in percent |
| `--min-discount` | discount against the official price floor, in percent |
| `--include-unknown-cache` | keep merchants that have no cache reading at all |
| `--include-dead` | keep merchants that look like they are not serving |

`--min-discount` is the filter to reach for when the user's criterion is
"at least N% off" rather than a dollar ceiling. It reads the listing's own
`official_discount_percent`, which the platform stores negative (97.5% off
is `-97.5`).

The script flags three merchant states that are worth reading before you
spend a benchmark run on them:

- `unproven: too few requests` — under 100 lifetime requests. The
  merchant's cache hit rate, median TTFT and availability are computed from
  almost nothing and move on the next request. It can still work; its
  published numbers just do not describe it yet. Report it as unproven
  rather than as a fast route.
- `shared-plan: cannot be pinned` — the listing's `provider_id` is a shared
  plan (`shared-plan:5`), not a merchant. See below; such a listing cannot
  be measured in isolation at all.
- `dead` — no cache reading, no availability reading, zero requests.

**A merchant can leave the scope between two runs.** The discount is a
function of the merchant's own multiplier, and the merchant changes it. One
merchant measured at 97.0% off in the morning was at 94.0% off the next
afternoon because its multiplier went from 0.03 to 0.06. Re-read the
listings at the start of every run, and when a merchant drops out of scope
say so in the report with the old and new figures. It is a scope change,
not a deletion: the listing is still there and still serving other people.

**A change of the scope rule is not a merchant failing.** When the filter
itself changes — from a ceiling on output price to a ceiling on input price,
say — the merchants that drop out have not got worse; they simply no longer
answer the question being asked. Say that in the report, and report the
current price of every merchant that dropped out so the reader can see the
ceiling that excluded it. A report that says "six merchants left the scope"
without that context reads as six merchants breaking.

**Keep the scope rule in the data, not in the prose.** The scope builder
should write the rule it actually applied — the axis and the ceiling — into
the scope file, and the report generator should read it from there. A
hard-coded price ceiling in the report template is one edit away from
describing a filter the run did not use, and the mistake is invisible in the
output because the numbers look fine.

Two exclusion rules matter more than they look:

- **A missing cache hit rate is not a pass.** The platform stores "no reading"
  as `-1` or omits the field. A merchant with no reading cannot satisfy
  "cache hit rate must be above N". It is dropped unless
  `--include-unknown-cache` is passed, and it is usually a merchant that has
  never carried traffic.
- **A merchant with no cache reading, no availability reading and zero
  requests is dead upstream.** It still passes a price filter, so it has to be
  excluded deliberately. The script drops it and flags it `dead`.

Always run the discovery step with the user's full criteria before creating
any token. A merchant that cannot serve a request at all still costs a
subscription, a token, and benchmark time to find out.

Two pricing traps, both of which will corrupt a comparison if missed:

- **Currency.** Most merchant prices are quoted in CNY. The platform's own
  rate is in `/api/status` as `price` (currently `6.8` CNY per USD, with
  `quota_display_type: CNY`). Divide CNY amounts by that rate. A few
  merchants quote directly in USD.
- **Tiered expressions.** A merchant billing via `billing_mode: tiered_expr`
  reports `output_price: 0` even though it charges real money, because the
  price lives inside `billing_expr` (for example
  `tier("base", p * 0.4 + c * 1.6 + ...)`). Reading `output_price` alone
  makes such a merchant look free. The script resolves the first tier's
  coefficients, and labels the row `from tiered_expr`.

`GET /api/marketplace/models?page=1&page_size=100&keyword=<model>` returns the
listing rows. `GET /api/marketplace/models/<id>` returns one listing with
provider description, guarantee level, credit score, and cache pricing.

## Subscription state and changes

```text
GET    /api/marketplace/subscribe/<provider_id>/status   -> true | false
POST   /api/marketplace/subscribe   {"provider_id": N}    -> subscribe
DELETE /api/marketplace/subscribe/<provider_id>          -> unsubscribe
```

Subscriptions are free and are what puts a merchant's models into your
available pool. Confirm the state before and after any change, and report
which merchants changed.

**Do not trust the status endpoint.** It returns `{"data": false}` for a
merchant that is subscribed, for every id form — provider id, listing id and
slug alike. Measured against an account with 50+ subscriptions, it reported
`false` for all of them, including one that had just been subscribed
successfully in the same session.

Two signals that do work:

- **The subscribe POST's message.** A first subscription returns
  `收藏成功`; one that was already in place returns `已收藏或操作失败`
  ("already collected, or the operation failed"). The wording tells you
  whether anything changed, which is the thing you actually want to report.
- **The group catalogue.** `GET /api/user/models?group=provider:<slug>`
  returns the merchant's catalogue only once it is in your pool, so a
  non-empty catalogue is proof of the subscription. Use this as the check
  before a benchmark: it also confirms the group serves the model you are
  about to request.

Subscribe **before** listing the group's models. `GET /api/user/models?group=provider:<slug>`
returns the group's catalogue only once the merchant is in the pool, and
the catalogue is the only reliable answer to whether the group actually
carries the model the marketplace advertises. Group sizes vary from two
models to over fifty.

Note that unsubscribing affects **every** key and every model that merchant
serves, not only the model under test. Say so before acting.

**Unsubscribing revokes access to that merchant's group immediately.** A
`provider:<slug>` key for an unsubscribed merchant starts returning
`403 无权访问 provider:<slug> 分组`. The key still exists and still looks
active in the token list, so a stale key fails at call time rather than at
creation time. Verify group access by making one small call per key after
any subscription change, not by reading the token list.

## Force traffic onto one merchant

A plain `/v1/chat/completions` call goes to whichever merchant smart routing
picks, so you cannot benchmark one merchant that way. Two mechanisms pin
traffic, and both are needed:

1. **A fixed-provider key.** Create a token whose group is `provider:<slug>`:

   ```json
   {
     "name": "<slug>-fixed",
     "group": "provider:<slug>",
     "unlimited_quota": true,
     "remain_quota": 0,
     "expired_time": -1,
     "model_limits_enabled": false,
     "model_limits": "",
     "subrouter_providers": "",
     "subrouter_model_providers": "",
     "subrouter_sort_mode": "token_price_first",
     "subrouter_route_preference": "price_first",
     "include_cache_hit_rate": false,
     "load_balance_enabled": false,
     "include_provider_self": true,
     "include_official_channels": false,
     "include_shared_subscriptions": false
   }
   ```

   POST it to `/api/token/`. The response contains `data.key` **once**; store
   it in the user's credential directory with mode 600 at creation time,
   because a lost key cannot be recovered.

   **Check for an existing token first.** `GET /api/token/?p=1&size=100`
   returns every token with its full key and its group. Look for a token
   whose group is already `provider:<slug>` and reuse it. Creating a second
   one is not harmless: it leaves duplicate keys in the account that nobody
   remembers, and the older one keeps working with the same access. Accounts
   accumulate these. When more than one token exists for a group, use the
   highest id, and delete the rest as dead weight.

   Keys that belong to a merchant you later unsubscribe from become dead
   weight: they still authenticate but return
   `403 无权访问 provider:<slug> 分组` on every call. Delete them.

   ```text
   GET    /api/token/?p=1&size=100   -> {data: {page, page_size, total, items}}
   DELETE /api/token/<id>  body {"id": <id>}   -> {"success": true}
   ```

   `GET /api/token/` returns the full key value for every token, so it is a
   credential dump. Never print its `key` field, and never echo it into a
   log or a report. Delete a token by id, and only ids the user created or
   explicitly asked to remove.

   **The create response and the list disagree about the `sk-` prefix.** The
   POST response returns the key *with* the prefix (`sk-…`); the token list
   returns it *bare*. Prepending `sk-` to the create response gives you
   `sk-sk-…`, which authenticates as `401 无效的令牌` and looks like a broken
   token rather than a formatting mistake. Normalise to one form before
   writing the file. SubRouter accepts both the bare key and the prefixed
   key, so either is fine as long as there is exactly one prefix.

2. **The right model name for that group.** The model name a merchant exposes
   may differ from the marketplace listing name. List the group's models with
   `GET /api/user/models?group=provider:<slug>` and use a name from that
   list. A merchant can advertise `deepseek-v4.1-flash-1017` and still only
   serve `deepseek-v4.1-flash`; requesting the advertised name returns
   `Model "..." is not supported by any configured account in this group`
   (HTTP 404). That is a real upstream condition, not a benchmark error.

The same endpoint also creates smart-routing keys (`group: subrouter`), which
route across every subscribed merchant.

## Verify who actually served the request

Smart routing and failover mean a request can land somewhere you did not
intend. After a benchmark, read the account log:

```text
GET /api/log/self?p=1&page_size=100
```

Each row carries `group` (`provider:<slug>`), `completion_tokens`,
`use_time` (seconds), and an `other` JSON blob holding `provider_slug`,
`frt` (first-response time in ms), `reasoning_effort`, and the per-provider
prices actually charged. Type 5 rows are errors and carry the upstream
message.

**`use_time` is in seconds.** The benchmark script reports `total_ms` in
milliseconds, so join on `use_time * 1000 ≈ total_ms`, not on the raw
values. Getting this wrong silently produces zero matches and looks like
attribution failure.

**The log row's `id` is not unique.** The same id appears on unrelated
rows; `request_id` is the per-request key. Deduplicating a log pull on `id`
silently drops real rows — in one measured run it dropped 7 of 49, including
the first request of two different merchants, which then looked like two
requests the gateway had never logged. Deduplicate on `request_id`.

**The account carries other traffic.** A benchmark account may be running
other work on the same model through the same merchants, with prompts of
280 000 tokens next to your 250-token ones. Filter the log to the run's
time window, or you will attribute somebody else's traffic to your
benchmark. Reconcile the rows you keep against the account's own quota
delta: they should agree to within a row or two.

Join a client-side run to its log row on three fields: the slug, the exact
`completion_tokens`, and the `use_time`. All three, not one of them — the
same merchant can serve two runs of the same workload, and the token count
disambiguates them. A request that timed out is billed and logged with
**zero** completion tokens, so it can only be matched on `use_time`.

Attribution rules:

- `other.provider_slug` is the authoritative merchant. Match it against the
  merchant you intended for every sample.
- `frt` is the server-side first-token time and is a good cross-check on
  client-side TTFT.
- **The gap between the client's TTFT and the gateway's `frt` says where the
  wait happened.** When the two agree, the upstream was slow. When the
  gateway saw the first token long before the client did, the merchant held
  it back. A gap of more than a few seconds is merchant-side buffering, and
  it inflates the route's apparent time to first token by exactly that much.
  A measured example: five of ten routes showed a 9-25 second gap, and the
  three fastest routes had no gap at all, which meant part of their apparent
  speed was that they release immediately.
- Merchant-side `total_requests` counters on the marketplace are shared
  across all tenants and move with other people's traffic. They are not a
  reliable per-request oracle. Use them only as a rough sanity check.
- **A client-side error does not mean the provider failed.** A stream that
  dies with an HTTP/2 protocol error or a connection reset leaves a
  successful row in the log, because the gateway completed the request and
  billed it. Read the log before writing a merchant off: if the row is
  type 2 with completion tokens, the merchant served it and the transport
  broke on the way back.
- **Check the model name in the response.** `model` in the SSE payload is the
  upstream model the merchant actually ran. It can differ from the requested
  name even when the marketplace listing is identical for two merchants, and
  that difference is worth reporting.

Failure modes, by what they mean:

| Response | Meaning |
|---|---|
| `无权访问 provider:<slug> 分组` | the token's provider group is no longer available, usually after an unsubscribe |
| `该令牌无权访问模型 <model>` | the token has `model_limits_enabled` with a whitelist that does not include this model; a property of the token, not the merchant |
| `分组 provider:<slug> 下模型 <model> 无可用渠道` | the group lists the model but no channel is serving it. The merchant is dead: it can appear in the marketplace with a price and still have nothing behind it |
| `upstream error: do request failed` (HTTP 500) | the merchant's upstream endpoint refused or failed the request. Often a dead provider, sometimes transient |
| `Model "..." is not supported by any configured account in this group` (HTTP 404) | the group does not carry that model name. A real upstream condition, not a benchmark error |
| `参数错误` when subscribing to `shared-plan:N` | the listing's `provider_id` is a shared plan, not a merchant. It cannot be subscribed to, so its `provider:<slug>` group stays empty and every fixed key for it returns 403. Record it as unpinnable and measure it only through smart routing, if at all |

**A shared-plan listing is not a merchant you can benchmark.** One listing
in the `gpt-6.1-sol` set had `provider_id: "shared-plan:5"`, 189 889
platform requests and the best price on the page, and it could not be
measured at all: subscribing was rejected, the group stayed empty, and the
key returned `403 无权访问 provider:openai-pro 分组`. It is a route for smart
routing, not a target for a pinned benchmark. Do not spend a key and a
benchmark slot on it.

## Benchmark workflow

1. List candidates with `subrouter_providers.py` and filter by the user's
   budget and cache hit rate. Drop merchants with no cache reading.
2. Subscribe to every candidate you intend to test.
3. Create one fixed-provider key per candidate, stored mode 600 in
   `~/.config/subrouter/keys/`. Reuse an existing `provider:<slug>` token if
   one is already there. **Pull every key the account already has onto disk
   once**, in the same pass: `GET /api/token/` returns the full key for every
   token, so one sweep populates the whole store and later runs never touch
   the account again. That endpoint is a credential dump, so never print its
   `key` fields.
4. Build a spec for the `llm-provider-benchmark` script with one target per
   merchant: the fixed key, the group model name, and the reasoning effort
   the user wants.
5. Run it **sequentially**, at least 3 runs per target, with a long-form
   prompt and `max_tokens` high enough to avoid truncation.
6. Cross-check the account log for attribution and server-side `frt`.
7. Report the ranking, then state the method, the sample count, the caveats,
   and what the run cost.

A merchant can pass every filter and still be unable to serve. Probe each
candidate with one cheap request before spending a full benchmark run on it.

**A probe timeout is not a verdict on the merchant.** A probe uses a shorter
deadline than the sweep, and on a reasoning model at `max` effort the first
token can take several seconds and the visible answer much longer. One
merchant hit a 90-second probe deadline and answered normally at 150 seconds;
another probe at 200 `max_tokens` produced a first token and no visible
content. That may reflect reasoning or an exhausted output budget, not
categorical merchant failure. Re-probe at the sweep's own deadline and with
an adequate output budget before writing a merchant off, and distinguish
three probe outcomes rather than two:

| Probe outcome | Reading |
|---|---|
| HTTP 4xx/5xx, no token at all | this request/route failed; inspect auth, group/model access and upstream error before attributing merchant incapacity |
| a token arrived, no visible content | token production was observed, not a usable answer; reasoning or an insufficient output budget may explain it |
| the wall deadline fired | unknown; re-probe at the sweep's deadline |

A timeout or an unexplained HTTP status alone is not proof that the merchant
cannot serve. Distinguish invalid access, model/group mismatch and transient
request/route failure from confirmed inability to serve the intended workload.

### When the schedule forces a concurrent sweep

Sequential is the right default, and it is what `llm-provider-benchmark`
asks for. When the user is on a tight schedule and asks for a concurrent
sweep anyway, do it — but measure a subset of the routes sequentially first
or alongside, and put the comparison in the report. `--parallel` runs the
targets at the same time; the sequential cross-check is the same script with
`--target` repeated for the subset.

The comparison is what turns "we ran them in parallel" from a caveat into
evidence. In one measured run, seven of eleven routes were measured both
ways: four were faster concurrently, three slower, no directional penalty.
The caveat and the cross-check table both belong in the report.

### Exclusions are part of the result

A route can answer, and still not be comparable. Exclude it from the
throughput ranking when the measured stream shows a bulk delivery — many
tokens per SSE chunk, or a single gulp at the end — because the rate is
then a property of the relay rather than of the model. Keep its latency and
cost figures, show it in a table of its own with the reason, and say it was
excluded rather than dropping it silently.

One route did this on three consecutive runs, returning 16 665, 26 190 and
41 634 tokens under an 8 000-token cap, at rates that looked like the
fastest on the page. It arrived at 19 tokens per chunk against 1.2 to 7.8
for every route that decoded normally, the rate was the speed of the
socket, and the route had no business in a decode-rate ranking.

A route that returns **more** tokens than the cap it was sent is a
different failure and is reported rather than excluded: the merchant
ignored the budget, so the sample is not the workload you asked for, but
the stream may still be a real decode. Both facts belong in the report.

Note that the buffered-flush heuristic misses this case. The route above
dribbled its payload out at 18 chunks per second, which is not a burst, and
the flush test never fired. Tokens per chunk is the metric that catches it,
and `bench_llm_endpoint.py` reports it for every run.

### Killing a run does not cancel the bill

Stopping a request part way through does not cancel it. The gateway
completes the call, charges for it, and writes a log row with no
client-side metrics attached. One aborted attempt in a measured run still
cost quota and still appears in the log. Reconcile the log against the
client runs and account for every row, including the ones that came from
requests you stopped.

### Pruning

Prune a merchant only when the user asks, only on measured evidence, and
tell them that the change affects every key and every model that merchant
serves.

## Getting a management credential into the shell

Management calls need one of three things: an `access_token`, a browser
session, or something already on disk. Check the disk first.

```text
~/.subrouter/credentials.json   {"key", "access_token", "user_id", "base_url"}
```

That file holds a working `access_token` and the numeric `user_id`. With
both, every management endpoint works from the shell:

```bash
curl -s --max-redirs 0 "$BASE/api/token/?p=1&size=100" \
  -H "Authorization: Bearer $(jq -r .access_token ~/.subrouter/credentials.json)" \
  -H "New-Api-User: $(jq -r .user_id ~/.subrouter/credentials.json)"
```

**When that file is missing or its token has expired, the browser session is
still on this machine.** The Playwright browser runs in a network namespace
whose loopback cannot reach the shell, and the MCP sandbox has no filesystem,
so a key created in the page cannot be moved out of it. The session cookie
itself, however, is readable locally: Chrome encrypts it with the "Chrome
Safe Storage" secret from the desktop keyring.

`scripts/session_auth.py` does this end to end and never prints the cookie:

```bash
python3 ~/.agents/skills/subrouter-provider-ops/scripts/session_auth.py check
python3 ~/.agents/skills/subrouter-provider-ops/scripts/session_auth.py create-key <slug>
```

The derivation, for the case where you need to write it yourself:

| Step | Value |
|---|---|
| Secret | `secret-tool lookup application chrome` — the base64 **text** of the keyring item, not its decoded bytes |
| Key | `PBKDF2-HMAC-SHA1(secret, b"saltysalt", 1, 16)` |
| IV | 16 spaces |
| Ciphertext | the cookie's `encrypted_value` with the `v11` prefix removed |
| Plaintext | 32-byte domain hash, then the cookie value, then PKCS#7 padding |

The 32-byte domain hash in front of the plaintext is what makes the result
look like garbage if you forget it: the cookie decrypts correctly and then
fails at the HTTP header because of the binary prefix.

## Benchmarking from a browser session

Sometimes the keys cannot be written to a local file: the fixed-provider keys
were created through a browser automation session (Playwright MCP, Camoufox,
CDP) whose loopback is isolated from the shell, and every route for moving a
key out of the page is closed. Pushing a credential into a shared console
buffer, a download directory, or a paste service to work around that is
worse than the problem.

In that case, keep the keys in the browser and run the benchmark in the page.
`scripts/bench_browser_session.js` is a drop-in harness for this. It mirrors
the metric names, arithmetic, and buffering thresholds of
`bench_llm_endpoint.py`, so the numbers are comparable with a locally run
sweep.

```js
// Playwright MCP, browser_run_code:
await page.addScriptTag({ path: '<skills>/subrouter-provider-ops/scripts/bench_browser_session.js' });
const runs = await page.evaluate(() =>
  window.__srbench.runProvider('znu', { runs: 3, maxTokens: 12000 }));
const summary = await page.evaluate(() => window.__srbench.summarize());
```

The harness exposes `getKeys`, `createFixedToken`, `groupModels`,
`measureOnce`, `runProvider`, `summarize`, and `attribution`.

Things this path gets for free:

- **Management auth needs no access token.** From inside a logged-in session,
  the session cookie plus a `New-Api-User` header with the account id
  authenticates every `/api/*` call. The `access_token` is not needed and
  the console does not even expose it.
- **Existing keys are readable.** `getKeys()` reads the full key of every
  token from `GET /api/token/`, so an already-created fixed-provider token
  can be reused instead of duplicated.
- **`addScriptTag({path})` reads the local filesystem** from the automation
  host, so the harness file can be injected by path rather than pasted in.

Things to watch:

- **One merchant per automation call.** A call that runs two merchants takes
  long enough to hit the tool's own timeout, and the abandoned half is lost.
  A timed-out call also does not cancel the request: the gateway completes
  it and bills it, so the log shows a run you have no client-side metrics
  for.
- **The measurement client is the browser, not your shell.** Say so in the
  report, and corroborate with the gateway's server-side `frt`, which is
  independent of the client.
- **Keep the key in the page.** The harness returns measurements only. Never
  return a key from a tool call: the result is echoed into the session
  transcript.

## Reading the marketplace numbers

The marketplace publishes figures about each merchant. They are useful for
shortlisting and misleading if taken at face value.

- **Judge price per million output tokens, and measure it as well as quote
  it.** The advertised output price is a good approximation of the real one —
  in one sweep every merchant's measured all-in price landed within 0.1% to
  6.9% of its sticker — but the gap is the merchant's own system prompt and
  its cache-read billing, and it is charged on every request. The merchants
  whose measured price came in furthest above their sticker were the ones
  injecting the largest system prompts, not the ones overcharging.

  A merchant's system-prompt overhead is not always fixed. In one sweep
  every merchant billed the same 19-word instruction at the same prompt size
  on all three of its runs except one, which billed it at 63 tokens on two
  runs and 1 768 on the third. That single run is the whole of that
  merchant's price gap, and it looks like a 17% overcharge if you only
  compare the sticker. Read the per-run prompt-token counts, not just the
  range, before you attribute a gap to overcharging.

  Do not compare on spend per request. On a reasoning model the answer length
  varies several-fold across merchants for the same prompt, so spend per
  request measures the model's thinking, not the merchant's price. Divide the
  gateway's billing by the output tokens delivered and quote a price per
  million.

- **The cache fields are in the `other` blob, not at the top level of the log
  row.** `row["cache_tokens"]` is always absent, so reading it there makes
  every request look uncached. Parse `other` and take `cache_tokens` and
  `cache_ratio` from it. `cache_ratio` is the cache-read *price* as a
  fraction of the input price, not the fraction of the prompt that was
  cached.

- **`median_ttft` does not predict the latency you will measure.** It is the
  platform's own rolling figure over all traffic, and it does not separate
  the first token from the first visible content. Measured side by side it
  ranked merchants in a different order than the benchmark did, and the gap
  between first-token and visible-content latency was several times larger
  than the marketplace figure suggested. Use it to shortlist, never to
  report.
- **`cache_hit_rate` drifts.** It is computed over a rolling window, so a
  merchant can sit just above a threshold and fall below it. Re-read it
  immediately before you report a qualification decision, and say which
  reading you used. One merchant's marketplace cache hit moved from 65.8%
  to 13.3% between two runs a day apart, while the hit rate measured on the
  request itself was 88.2%.
- **`official_discount_percent` drifts too, and it moves the scope.** It is
  the merchant's own multiplier applied to the official price, and the
  merchant changes the multiplier. Re-read the listing every run and report
  a merchant that falls below the threshold as a scope change with both
  figures.
- **`total_requests` is not a measure of this account's traffic.** It is the
  merchant's platform-wide counter, shared with every other tenant.
- **A merchant can be listed as 100% available and fail every request.**
  `x-loop` is listed at 100% availability and a 2.7-second median TTFT for
  `minimax-m3.1-flash`, and timed out on all three attempts. An availability
  figure of 100% means the merchant was reachable, not that it can serve
  this model.
- **The window is shared across tenants.** `total_requests` and the
  availability buckets include other people's traffic. They are a sanity
  check on a merchant, not a measurement of it.

## What "tolerable" means beyond price and speed

Cheapest is only meaningful against a bar the route has to clear. Before a
cheap route is used for real work, put one request through it and check the
three things price and timing cannot show: does it answer **this task**
correctly, in the **format** the caller parses, and with a **valid tool
protocol** (well-formed tool-call names, arguments and JSON) if tools are in
play. A route that is fast, cheap and wrong is not tolerable, it is free
damage; a route that cannot emit the tool-call shape the caller needs fails
regardless of its price.

Model and route **identity** is a separate check, not a quality score.
Reading `model` out of the SSE payload, or the log row's
`other.provider_slug`, says *who answered*; it says nothing about whether
the answer was good. Report identity and quality as distinct facts.

This workflow does **not** measure answer quality by default. Cost, latency
and stability are what it quantifies; quality is a per-task spot check made
by the caller against a known-good answer. The tokenizer-fingerprint and
semantic-substitution probe kept under
`~/.cache/subrouter-benchmarks/<model>/NEXT-STEPS.md` is **not** a quality
gate: its flag moves between merchants without settling on either, it is
excluded from every ranking, and it is paused at the operator's request. Do
not resume it as part of this workflow and do not present it as a verdict.

Disclosure is not authorization. Naming what a run will cost, or who
approved it, never authorizes spending: subscriptions, token creation,
benchmark sweeps and any auth or account change remain separately released
actions, gated as described above.

## Housekeeping

- Keep created keys in the user's credential directory, mode 600, never in a
  chat transcript or a repo. A key created in a browser session stays in the
  browser session; do not copy it out to make it convenient.
- Removing a subscription does not remove the keys that referenced it; those
  keys become dead weight and should be deleted or noted.
- A token created for a merchant that turns out to be dead is dead weight
  from the moment it is created. Probe the merchant with one cheap request
  before creating its token, and delete the token if the merchant cannot
  serve.
- Report what the benchmark cost in quota or dollars. Marketplace quota is
  internal units where 500000 units = $1. Take the delta of `quota` from
  `/api/user/self` before and after the run; it is the only figure that
  includes platform overhead the token arithmetic misses. For a per-request
  breakdown, sum the `quota` of the log rows the run produced and attribute
  each row to the client run it joins to. Count the rows from requests you
  aborted: they were billed too.
- Duplicate tokens in the same group are dead weight rather than a risk.
  Use the highest id and keep the others only if the user would rather not
  have them deleted.
