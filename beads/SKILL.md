---
name: beads
description: Use when working in a repository that uses bd or Beads for durable project task tracking, issue dependencies, blocker management, multi-session handoff, or shared work memory. Trigger when the user asks to find ready work, claim or close tasks, create follow-up work, inspect blockers, recover project context, or choose between local planning and persistent project tracking.
---

# Beads

Use Beads as the shared project task system. Local plans, scratch files, and personal memories are useful, but they are not the durable source of truth for project work.

## First Step

Run:

```bash
bd prime
```

If that prints nothing, check whether the repository has an active Beads workspace:

```bash
bd where
```

## Preferred Route

Use the `bd` CLI when shell access is available. It is the most compact and direct Beads interface.

## Core CLI Workflow

**This database is fleet-wide.** One tracker holds every space's beads, discriminated by a
`project:<w-id>` label — so a bare `bd ready` returns every space's work, and a bare `bd create`
makes a bead no space owns.

1. Find work — **always scoped to your space:**

```bash
bd ready --label project:<w-id>          # your space's claimable work
bd list --label project:<w-id> --status=open
bd list --label project:<w-id> --status=in_progress
```

Bare `bd ready` is the fleet, not your space (85 ready beads across 20 spaces when this was
written). Read it deliberately, never by accident.

2. Inspect before editing:

```bash
bd show <id>
```

3. Claim work atomically:

```bash
bd update <id> --claim
```

4. Create durable follow-up work when implementation reveals new tasks — **with the label, always:**

```bash
bd create "Short title" --labels project:<w-id> --description="Why this exists and what needs to be done" --type=task --priority=2
```

5. Close completed work:

```bash
bd close <id> --reason="Completed"
```

## A bead with no `project:` label is an anomaly

The label is how every space's work is separated, and nothing enforces it — so an unlabelled bead
is invisible to its own space's filter and visible to every other space's loose read. When you meet
one, fix it (`bd update <id> --add-label project:<w-id>`) rather than working around it. Do not treat
absence of a label as permission to ignore a bead.

## What Belongs In Beads

Use Beads for:

- shared project tasks
- blockers and dependencies
- discovered follow-up work
- work that must survive thread reset, compaction, or handoff
- status that another person or agent should be able to resume

Use agent-local planning tools only for the current turn's execution checklist. Do not treat them as shared project state.

## bdi pane join (bead ↔ lane)

`bdi` joins a bead to a live lane through bead metadata, never through the agent name. A claim
with no join shows as `orphan-claim`; a bead naming a pane that now belongs to another project
shows as `pane-in-another-project`. Both are the claim's fault, not bdi's.

**This is maintained for you — do not hand-maintain it.** As of 2026-11-02 three pieces do it:

| Piece | What it does |
|---|---|
| `bd` shim (`~/.overlord/bin/bd`, reached through the stock `~/.local/bin/bd`) | on a claim writes `agent_session` + `agent_pane` and sets the pane's `display_agent`; on stop/close unsets both. Passes every other verb through to `bd-real`. |
| `bdi-reconcile` (`~/.overlord/tools/bdi-reconcile.py`, systemd user timer `bdi-reconcile.timer`, 25s) | rewrites `agent_session` for a live claim whose session changed (`/new`, relaunch, profile switch) and clears joins that are stale — closed bead, dead pane, pane reused by another lane, or a space epic whose pane now belongs to another workspace. |
| pane `display_agent` | session-independent fallback that survives `/new` in the same pane. |

So the rule for a lane is short: **claim with `bd update <id> --claim` (or `--status in_progress`) and the join is written; stop with `--status open` or `bd close` and it is cleared.** One pane joins one bead, hence the clear.

If you ever do write it by hand:

```bash
sess=$(herdr agent get "$PI_ROOMS_NAME" | python3 -c 'import json,sys;print(json.load(sys.stdin)["result"]["agent"]["agent_session"]["value"])')
bd update <id> --set-metadata agent_session="$sess" --set-metadata agent_pane="$HERDR_PANE_ID"
```

Audit the whole fleet with `~/.overlord/tools/join-audit.py`; run the reconciler by hand with
`bdi-reconcile.py --dry-run --verbose`.

## Rules

- Do not create markdown TODO files as the source of truth when Beads is available.
- Do not use `bd edit`; it opens an interactive editor. Use `bd update` flags instead.
- Prefer `--json` when parsing `bd` output programmatically.
- If hooks are installed, `bd prime` may already be injected. Run it manually when context is missing.
- Do not auto-close or mutate tasks unless the work is actually complete.
