---
name: pi-goal-contracts
description: The @signalridge/pi-goal contract on pi — the three agent tools goal_complete/goal_blocked/goal_wait, the goal queue verbs (add, edit, prioritize, skip, pause, resume, clear, drop-last), why /goal <objective> wipes the queue and opens a modal, why a token budget must never be set, and how prompting a working goal lane pauses its goal. Use when setting, resuming, blocking, or completing a goal, when a lane shows Goal paused or Goal blocked in its footer, when a goal-driven lane stops early, or when briefing another agent about goals.
---

# pi-goal contracts

pi runs `@signalridge/pi-goal` (npm; config `~/.pi/agent/pi-goal.json`, `experimental.goals: true`). codex has native `/goal`. The two are not interchangeable, and pi's is stricter.

## Queue model

Verbs: `pause`, `resume`, `clear`, `edit <obj>`, `add <obj>`, `prioritize <obj>`, `drop-last`, `skip`, `status`.

- `addGoal()` **appends when a goal is active and starts immediately when none is**, so `/goal add` is *always* safe. Hand over a backlog by adding several and letting the queue walk.
- `prioritize` puts a goal at the front; `skip` advances past the head; `drop-last` removes the tail.
- The queue **self-advances**: `goal_complete` sets a pending advance, and the next goal activates at the settled idle boundary with no human focus step.
- A stopped next item **stays stopped**. A paused goal you skip to does not silently resume.

## Only three tools

`goal_complete`, `goal_blocked`, `goal_wait`. There is **no** `create_goal`, `get_goal`, or `update_goal` on pi.

- The agent cannot create or change its own objective; only a typed `/goal` command can.
- Complete with `goal_complete` — one call, guarded by the current goal id — not `update_goal complete`.
- Block with `goal_blocked` plus reason and evidence. A blocked goal stops continuing until an explicit `/goal resume`; nothing auto-resumes it.
- Wait with `goal_wait` (reason, optional deadline) for outside dependencies — CI, review, a reply. It parks instead of burning turns polling, and is not a failure or a hang.
- Tools stay hidden until a goal exists (`toolVisibility: after-first-goal`). They appear once a goal is set, and at startup for a session that restores an unfinished goal.

## `/goal <objective>` replaces everything

It is **not** "add". `startGoal()` sets `queuedGoals = []` after a `Replace goal?` confirm modal that lists the goals it will destroy. In an agent pane the modal absorbs your next Enter, so a send reports success while no turn runs.

Prefer, in order:

1. **`/goal edit <objective>`** — in place, no modal, no queue loss, keeps usage counters. **This is the safe way to re-point a goal.**
2. **`/goal add <objective>`** — appends without touching the head; starts immediately if no goal exists. Use for every goal after the first.
3. **`/goal <objective>`** — only to replace everything deliberately, with a human at the modal.

`/goal` alone and `/goal status` print state and are safe to send blind. Every other route is destructive or needs the modal or settlement boundary.

## Never set a token budget

Do not pass `--tokens` to any route, and do not ask an agent to set one. With continuation limits disabled, a budget is the only ceiling: the goal stops at `budgetLimited` and needs a new budget or a brand-new goal — which loses the queue and the context, so the lane must be rebuilt. Goals run uncapped by operator decision.

## Two failure modes that look like stops

- **Prompting a working goal lane pauses its goal.** `pauseForAbort` fires on `stopReason: "aborted"`, so it looks like an ordinary stop. Recover with the lane's own bare `/goal resume` — **no replacement objective, no re-sent brief**.
- **`blocked` stops continuation** until an explicit `/goal resume`. Settle-worthy; never wait it out.

`/new` carries no goal across (it is reconstructed from the session branch) — re-establish it when reorienting.

## A profile switch re-mints the goal id

After `/profile use`, the goal survives intact — objective, paused state, waiting reason and queue position — but its **`goal_id` is re-minted**. The first `goal_complete` carrying the pre-switch id is therefore rejected:

```
Goal completion rejected: goal_id does not match the active goal
```

This is a **re-read, not a recovery**: fetch the current id and complete again. Verified 2026-11-01 by the overlord running `/goal add` → `/profile use worker` → `/goal status` → `/profile use fleet` → `goal_complete` → retry → `Goal Complete`. Do not treat the rejection as a lost goal, and do not re-send the objective because of it — `/goal <obj>` would wipe the queue.

## Reading goal state

From the **footer**, not the API (`herdr agent get` / `list` have no goal fields): `herdr agent read <pane> | tail -2` shows `Pursuing goal (47m)`, `Goal achieved (…)`, `Goal paused (/goal resume)`, or `Goal blocked`. Run this during surveys before concluding a quiet lane is finished — an `idle` lane may hold a paused or achieved goal.

## Briefing

In a multi-tranche brief, ask the agent to `goal_complete` only after an evidence-backed audit, and `goal_blocked` with a reason rather than parking. Setting the objective is the operator's or orchestrator's call, never the worker's.

`rpc.enabled` is true on this machine, so the `pi-goal:start` / `pi-goal:cancel` event channels are live: anything that can emit on pi's extension event bus can start or cancel a goal run. That is a deliberate hook for programmatic run control, and the reason not to run untrusted extension code in a session.