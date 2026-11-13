---
name: behold-roster
description: Use when the operator asks what the fleet is doing right now — which lanes exist, what status herdr reports for each, how much context a lane has used, or whether a lane looks stuck. Covers the shipped read-only `behold roster` CLI from https://github.com/Apothic-AI/behold, the field states that mean unknown or stale, and the facts that are permanently unavailable from disk. Trigger on "fleet roster", "what is the fleet doing", "lane status", "context usage per lane", "is a lane blocked", or any request to read the fleet's own state instead of joining it by hand.
---

# Behold roster

`behold` derives a **roster** of fleet lanes from stores that already exist on disk and
prints what it found. One process: no daemon, no service, no socket, no database, no cache
file, no network. It reads, it prints, it exits.

Upstream: **https://github.com/Apothic-AI/behold**

This skill describes only what that repository ships today. Where the two disagree, the
repository wins, and the repository's own `README.md` and `FIELD-LEDGER.md` are the
authority for every field, its source and its remaining gate.

## The one rule

**Report the state, not the conclusion.** Every value `behold` prints is a record with a
`state`, a `class`, a `source`, an `observed_at` and a `reason`. `unknown` means the data
does not exist here and says why. `stale` means it existed and cannot be confirmed current.
Neither is zero, neither is a fault, and neither is a claim about a lane.

A lane reported as `working` is a status string herdr emitted. It is **not** evidence that
the lane is making progress. A lane whose field is `unknown` is not a broken lane; it is a
lane whose store does not hold that fact.

## Install

There is **no packaging metadata** — no `pyproject.toml`, no `setup.py`, no entry points.
`pip install .` does not work and will send you down a dead end.

```sh
git clone https://github.com/Apothic-AI/behold.git
cd behold
```

Optional, recommended: put it on `PATH` by linking the **entry point**, not the package
directory.

```sh
mkdir -p ~/.local/bin
ln -s "$HOME/Code/behold/bin/behold" ~/.local/bin/behold
hash -r
behold --version        # -> behold 0.1.0-p1p2
```

CPython 3.10 or newer. Standard library only — no dependencies, and no network at install
time or at run time. `bin/behold` puts the repository root on `sys.path` itself, so
`python3 -m behold roster ...` works from the repository root and the script works from
anywhere.

## The shipped invocation

One subcommand, `roster`:

```sh
behold roster --root /path/to/data-tree           # a fixture / data tree
behold roster --snapshot /path/to/snapshot.json   # one captured herdr snapshot
behold roster --live --snapshot /path/to/snapshot.json
behold roster --root /path/to/tree --markdown     # Markdown instead of JSON
behold roster --root /path/to/tree --full         # every field of every lane
behold roster --root /path/to/tree --lane w1A:p1  # one lane, by pane id
behold roster --root /path/to/tree --filter 'H-5.value.status=working'
behold roster --root /path/to/tree --sort 'T-3.value:desc'
behold roster --root /path/to/tree --as-of 2026-11-11T03:00:00Z
```

`behold --version` prints `behold 0.1.0-p1p2`.

### Input modes — there is no live discovery

| Mode | What it reads |
|---|---|
| `--root DIR` | a data root holding `herdr/`, `proc/`, `pil/`, `instances/`, `state/` |
| `--snapshot FILE` | exactly one file, and nothing else. With no `--root` and no `--live`, the host `/proc`, the pil records and the agent directory are never opened |
| `--live` | the real store paths under `$HOME`, so it reads real private data. It **still needs `--snapshot`** |
| `--herdr` | **refused**, exit 3 |

`--herdr` is refused on purpose: reading a live snapshot needs a herdr child process, and
this build has no external execution at all. Capture the snapshot to a file and pass
`--snapshot FILE`.

There is no "scan every session directory and pick the newest" mode, and there is no
`--output` flag, no `--git`, no `--jj` and no `--stash-count`. An unknown flag is a usage
error, so a plausible-sounding private-export flag fails loudly instead of appearing to
work.

`--live` has never been exercised against a live fleet. Treat the first live run as a
measured event, not as a default.

### Other flags

| Flag | Meaning |
|---|---|
| `--markdown` | render Markdown instead of JSON |
| `--full` | with `--markdown`: every field of every lane, not just the summary table |
| `--lane PANE_ID` | one lane, by pane id such as `w1A:p1` |
| `--filter KEY=OP` | repeatable. Keeps lanes whose flattened `KEY` satisfies the operator |
| `--sort KEY[:desc]` | repeatable. Defaults to the pane id |
| `--proc-root DIR` | an explicit `/proc` tree. The host `/proc` is never read unless you name one |
| `--as-of ISO8601` | evaluate ages at this timestamp instead of now. Single-run only |
| `--watch` | re-derive on input change, bounded by iterations and wall clock |
| `--watch-iterations N` | maximum number of rendered documents (default 2) |
| `--watch-interval S` | seconds between polls (default 0.5) |
| `--watch-max-seconds S` | hard wall-clock bound for the loop (default 30) |
| `--events-file FILE` | a herdr events file to watch. It refreshes snapshot fields only |
| `--verbose` | per-source timings and watch steps on **stderr** |
| `--deny-workspace ID` | add a held workspace. The defaults are never removed |
| `--deny-pane ID` | add a reserved pane. The defaults are never removed |

`--as-of` cannot be combined with `--watch`: a watched document has to age.

## Reading the output

The JSON document has four top-level keys: `behold` (run metadata, privacy rules, counts,
timings, the budget targets and the list of runtime-only pending items), `global` (the
machine-level `M-4` active profile, plus three summaries), `lanes` (one envelope per lane)
and `diagnostics` (per-lane notices about damaged or disagreed data).

A lane envelope carries `key` (the pane id), `handles` (ids and names only, never
content), `admission`, `identity` (the trust record) and `fields` (every field, keyed by
its code).

Every field is the same shape: `state`, `class`, `value`, `source`, `observed_at`, `age_s`,
`method`, `reason`, `note`, `unit`, `privacy`. `source` names the file or record the value
came from — paths only, never content. `method` carries the exact expression for anything
computed, so it can be recomputed by hand. `reason` is present on every state that has no
value.

**No field is ever silently dropped.** All 56 per-lane codes are always in `fields`, either
with a value or with a state and a reason. `M-4` is the 57th id and is global only; it is
never a lane field.

`--markdown` renders a summary table, the pending runtime-only metrics and the budget
targets, plus a per-field section per lane when `--full` or `--lane` is given.

### Privacy — what is never in the output

The design is **counts and paths only**. Free text is never exported, and there is no flag
that turns it on. The following are never in the output, so do not go looking for them and
do not try to reconstruct them from another store:

goal text · TODO subjects · cron prompt bodies · room bodies and receipts · bead
descriptions and notes · bead titles · dagr run titles · session message content · tool
arguments · skill bodies · prompt bodies · environment values other than the single
allowlisted `PI_PROFILE` key.

Bead titles and dagr run titles are withheld even though the plan placed them at privacy 1,
because this tranche is restricted to counts and paths only. Re-enabling them is a separate,
reviewed decision, not a flag flip.

## The vocabulary: states, classes, privacy

### Field states (eleven)

| State | Means | Has a value? |
|---|---|---|
| `present` | read or computed, with its source | yes |
| `divergent` | two authoritative sources disagree; both values are shown | yes |
| `conflict` | two stores disagree about the same fact | yes |
| `inferred` | a heuristic, labelled with its limitation | yes |
| `stale` | a past observation that cannot be confirmed current; the age is shown | yes |
| `expired` | a TTL-bounded value whose deadline passed | yes |
| `unknown` | the data does not exist here; `reason` says why | no |
| `absent` | the source is legitimately missing. Expected, not an error | no |
| `error` | a source failed; the roster still renders | no |
| `held` | refused before any path was opened (held workspace, reserved tab or pane) | no |
| `withheld` | class-2 content exists and is deliberately not exported | no |

`unknown` is never written as `0` or `-`. Neither is `absent`.

### Field classes (four)

`authoritative` (read verbatim from a store) · `derived` (computed, and carrying the exact
`method` that produced it) · `inferred` (a heuristic that may be wrong, labelled with its
limitation) · `last_observed` (a past observation that cannot be confirmed current).

### Privacy classes

`0` public fleet metadata · `1` operator-sensitive (counts, paths and handles only) · `2`
never emitted — the field appears as `withheld` with no value.

### Identity states

`identity` is the trust record, and it is the part worth reading before you trust anything
else in the lane. Only `verified` is trusted.

| State | Meaning |
|---|---|
| `verified` | the pin, the pane-matched lane record and the `/proc` pid triple all agree |
| `session_pin_stale_used_pil_record` | the pin was stale; the lane record was used instead |
| `session_pin_stale_no_fallback` | the pin was stale and no lane record could stand in |
| `reporter_pin_missing_used_pil_record` | no pin at all; the lane record was used |
| `pin_only_unverified` | a pin existed and nothing else did. **Not trusted** |
| `no_session_source` | no session file could be located for this lane |
| `pid_disagreement` | the reporter pid and the lane record pid differ |
| `pane_disagreement` | the recorded pane id differs from the snapshot pane id |
| `process_tuple_disagreement` | the recorded boot id / starttime do not match the observed process |
| `envpane_disagreement` | the process's own `HERDR_PANE_ID` is not this pane |

An untrusted lane is still shown, with every witness visible, but no explicit join (beads)
and no profile or instance resolution happen on it. A pin alone proves nothing.

## What is permanently unknown, stale or withheld

These are not bugs and not failures. The data simply does not exist on disk.

**Six items are runtime-only and are listed verbatim in `behold.runtime_only_pending` and
in the Markdown footer:**

| Item | What is missing | Why |
|---|---|---|
| `T-8` | time to first token | pi persists total `durationMs`, not time-to-first-token |
| `J-1` | live exit state of a background job | only log files and last tool calls exist |
| `J-2` | monitor exit state | runtime-only |
| `J-3` | the bizzy monitor registry | no persistable state |
| `E-1` | the exact loaded extension list | tools alone cannot prove it — an inert extension registers nothing |
| `M-7` | rooms presence and inbox depth | deferred to a separately reviewed phase |

**Eight lane ids are always `unknown`** in every lane, with a stated reason:

`T-8` · `R-1` · `R-2` · `R-3` · `R-4` · `R-6` · `M-7` · `J-3`

`R-1` (git branch and oid), `R-2` (worktree identity), `R-3` (dirty counts), `R-4` (ahead /
behind / stash) and `R-6` (jj state) are `unknown` because the git and jj adapters were
**removed**: a child process is not contained by an in-process audit hook, and repository
config can make even a read-only `git` argv run a helper writer. There is no opt-in flag
that brings them back, and `argparse` rejects `--git`, `--jj` and `--stash-count` outright.
`R-5` and `R-7` still work: detection is pure `stat`, no binary is ever run.

**Five lane ids are class 2 and never carry a value**: `D-2` (TODO subjects) · `C-2` (cron
prompt) · `S-2` (skill text) · `S-4` (prompt text) · `B-2` (bead description and notes).
On a lane with a validated session they are `withheld`; on a lane without one they are
`unknown` with a reason. Neither state ever carries the content.

That is the exact partition of the 56 per-lane ids: 43 carry a value under normal
conditions, 8 are always `unknown`, 5 are always class-2 `withheld`. Any lane can also show
`absent`, `conflict`, `divergent`, `stale` or `error` depending on what the stores actually
hold — those are per-run, not per-field.

`P-4`'s leaf is labelled `DISK_RECONSTRUCTED`: pi keeps the selected leaf in memory only,
so the file can show the last entry but cannot prove which branch is current.

`J-1` and `J-2` are last-observed, not running states. A log file's size and mtime are
evidence that something was logged, not that a process is alive.

## Filtering and sorting

Filtering and sorting operate on **flattened field paths**, so anything the JSON exposes is
reachable without a second schema. `key`, `admitted`, `handles`, a field code (`T-3`), a
field's `state` (`T-3.state`), a field's `value` (`T-3.value`), a path inside the value
(`H-5.value.status`), `identity.state` and `identity.session_id`.

| Operator | Syntax | Meaning |
|---|---|---|
| `=` | `KEY=VALUE` | exact string equality |
| `!=` | `KEY!=VALUE` | not equal |
| `~` | `KEY~GLOB` | shell glob match (`*`, `?`, `[seq]`), case-sensitive |
| `!~` | `KEY!~GLOB` | not a glob match |

There is no `>` or `<`; numbers compare as strings, so `T-3.value=15.75` works and
`T-3.value>10` does not exist. Sort instead. The glob operator takes **no `=`**: it is
`KEY~GLOB`, not `KEY=~GLOB`. Repeating `--filter` ANDs the conditions.

Sorting is a stable multi-key sort; numbers sort numerically, text sorts case-insensitively,
and **missing or unknown values always sort last, in both directions**. A filter that
matches nothing is not an error: it is an empty lane list.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | the roster rendered |
| `2` | usage error — an unknown flag, a filter with no operator, `--as-of` with `--watch` |
| `3` | source error — snapshot missing, unreadable, or an unsupported herdr protocol |
| `4` | guard violation — a write or network attempt was refused inside the process |

## What you may claim

- **The roster is derived on demand, not live.** It is a snapshot of the stores at the moment
  of the run. Quote the run's `generated_at` and `as_of` when a number matters.
- **`behold.budget_targets` are targets, not a measured whole-fleet proof.** The document
  says so in its own `note`. Nothing has been measured against a live fleet.
- **Derived token fields are derived.** `T-1`, `T-3`, `T-4` and `T-5` are computed from
  persisted usage; they are not proven equal to what pi's own footer prints. Each field
  carries its `method` string so the comparison is mechanical, and the comparison is still
  an open gate.
- **A count is a claim, and it travels with the command that produced it.** Say which
  invocation produced a number, the way the `beads` skill says it.
- **A `working` status is not progress.** Quote it as the status string herdr reported.
- **Never quote a field's value without its state.** `unknown` with a reason is the honest
  answer, and it is the answer the tool gives.

## Safety boundaries

Two mechanisms are active for the whole run, and both are enforced in code:

1. **Deny before read.** Held workspaces and reserved tabs and panes are refused *before*
   any session, state or process path for that lane is opened. A held lane produces no value
   at all — not even its label or status.
2. **Fail-closed read-only and network guard.** An audit hook refuses any write-intent open,
   any filesystem mutation, any socket or URL fetch and any spawn. There is no write
   exception, not even for output. A write attempt inside the process crashes the run rather
   than succeeding.

`behold` never writes a file and never reports back to herdr or pi. It is not a second
session reporter.

## When a lane looks empty

| Symptom | What it usually means |
|---|---|
| every field is `unknown` | the lane has no validated session. Read `identity.state` and `identity.untrusted_because` first: a stale pin after a session switch, a pid that no longer matches, or a lane whose process exited |
| every field is `held` | the lane is in a held workspace or a reserved tab or pane. That is the deny policy working |
| `T-3` is `unknown` | either the used-tokens field or the context-window field is unknown. The `reason` says which. No context size is ever assumed |
| `B-1` is `unknown` with `identity_untrusted:` | the identity witnesses disagreed, so the join refused. Read `identity.disagreements` |
| the Markdown table shows long `unknown: ...` strings | the summary columns show the reason. Use `--full` or `--lane` for the per-field section |
| a filter returns nothing | the expression may be parsing differently from what you meant. A filter that matches nothing is not an error |

## Where the detail lives

The upstream repository holds the authoritative material, and it is the right place to read
more or to check a claim:

- `README.md` — the full operator guide, the CLI reference, the field-by-field tables
- `FIELD-LEDGER.md` — every operator field, its source, its state in this tranche, and the
  gate that still has to close before the value is true of a live fleet
- `tests/run-tests.sh` — the offline suite (178 tests, standard library only, no network)
