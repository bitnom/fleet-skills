---
name: agents-cron
description: Schedule agent work for later or on a repeating cadence with agents-cron on this machine — create, inspect, run and remove tasks; the systemd timer, task registry, run artifacts and failure semantics. Use when scheduling an agent task for a future time or a cadence, checking what is scheduled, debugging a task or reading its runs, or answering what ran and how it went.
---

# agents-cron — scheduled and recurring agent work

Only the **overlord and leader/orchestrator lanes** may use this. A worker or
sub-agent that needs something scheduled reports the requirement, the recurrence,
and why it cannot be a one-off to the orchestrator that owns its work; that
orchestrator decides and installs it. See `~/AGENTS.md` for the full gate.

`agents-cron` schedules work for later or on a cadence. The clock does not live in
a pi session: a **systemd user timer** runs `agents-cron run-due --all` every five
minutes, and each due task becomes one **isolated `pi --print` session** of its
own. It survives a closed pane, a logout and a reboot, and no scheduled run ever
enters an interactive conversation.

Verified against the installed package (`agents-cron` 0.13.2) and the live units,
not the README.

## Where it lives

- CLI `agents-cron` on `PATH` (package `~/.pi/agent/npm/node_modules/agents-cron`).
- Service `~/.config/systemd/user/agents-cron.service`.
- Timer `~/.config/systemd/user/agents-cron.timer` (`*:0/5`, `Persistent=true`).
- Global task registry `~/.agents/cron/tasks.json` — every project's tasks.
- Per-project artifacts `<project>/.agents/cron/{runs,reports,sessions}/`.

## Adding and inspecting

```sh
agents-cron add --name nightly-audit \
  --prompt "Review dependencies for CVEs, write findings to reports/cve.md" \
  --cron "0 3 * * *" --model subrouter/deepseek-v4.1-flash-1017 --thinking high \
  --tools read,bash --project /home/bitnom/ops

agents-cron list             # current project first, then every other project
agents-cron show <taskId>    # schedule, counters, and the prompt verbatim
agents-cron run <taskId>     # run now; the schedule is untouched
agents-cron remove <taskId>
```

## Schedules

A schedule is `--at <iso>` (one shot), `--every 30m|6h|1d`, or `--cron "<expr>"`,
and both `--at` and cron expressions are evaluated in **local** time. `add` binds
the task to the current directory; `--project` binds it elsewhere, `--cwd` changes
only where the run works.

Always pass `--model`, `--thinking` and `--tools`: without them a run inherits the
default model and the full tool set, which is both expensive and wider than a
recurring job needs. Record the task in your dagr run before creating it, and be
able to report on each firing from its artifacts — a task nobody reads is silent
spend.

## Semantics that change behavior

- Recurring schedules advance from *now*, not from the missed slot, so a week of
  downtime yields one catch-up run and never a backfill storm.
- A `once` task is terminal — after its first attempt, success or not, it disables
  itself.
- Passes are serialized by a per-project run lock plus systemd's no-overlap rule
  for the oneshot, so two runners cannot double-fire a task; the loser exits `0`.
- A hung run is bounded twice: the unit sets `TimeoutStartSec=2h` (the oneshot
  default of 90 s would kill an agent mid-turn), and a run still marked `running`
  is reclaimed as stale after 30 minutes.
- History keeps the newest 20 runs per task.
- Notifications default to failures only, so silence means healthy.
- Exit codes are `0` fine (including "nothing due" and "another instance holds the
  lock"), `1` a task failed, `2` configuration or storage error.

## Watching it

```sh
systemctl --user list-timers agents-cron.timer
journalctl --user -u agents-cron.service -n 50 --no-pager
agents-cron dashboard        # read-only, 127.0.0.1:7383
```

Every run leaves a run record (`runs/<runId>.json`), a Markdown report
(`reports/<taskId>/<runId>.md`) and the full transcript
(`sessions/<taskId>/<runId>.jsonl`, openable with `pi --session <path>`). Read the
record or report before calling a task healthy — the same rule as any lane.

## Never

- Never schedule unattended work that needs a decision: there is no operator in
  the loop and nobody to answer a permission prompt, so a task that asks a
  question blocks or guesses. Prompts must be self-contained, idempotent, and
  explicit about what to write and where.
- Never put a secret in a prompt — it is stored verbatim and printed by `show` and
  the dashboard.
- Never bind a machine-wide task to `/`; use a dedicated ops directory such as
  `~/ops`.
- Never treat the in-session surface as durable: `/schedule`, `/remind` and
  `schedule_task` only exist after a `/reload` and do nothing while pi is closed —
  they write the same registry, and the timer is the only execution path.
- A scheduled run cannot schedule more work: the child runs with
  `AGENTS_CRON_TASK_SESSION=1` and the extension is inert inside its own task
  session.
