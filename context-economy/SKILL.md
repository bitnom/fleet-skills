---
name: context-economy
description: Token and context conservation rules for pi and codex lanes — measure before reading, keyhole inspection with head/tail/grep -m, recon in one pass, poll in large slices, never build an unrequested verification harness, and construct every wait so it fires on failure as well as success. Use when a task involves reading large files, exploring an unfamiliar repo, running long commands, waiting on a background job or another agent, or when context usage is climbing.
---

# Context economy

Every request re-reads the whole conversation, so **cost = steps × context**, not words. Save by taking fewer steps and keeping bulky tool output out of the transcript — never by skimping on the work. Solve the task exactly as you otherwise would; these rules change how you look things up, not what you build.

## Rules

1. **Recon in one pass.** Before changing anything, gather every independent fact in one step: chain labeled probes with `;` (`echo == layout ==; ls -la; echo == deps ==; head -30 requirements.txt`), or issue parallel tool calls. A second round is only for questions the first round raised. When copying a convention (DSL, schema, file format), sample two existing examples of the exact construct, not one.
2. **Look through a keyhole.** Inspect-only commands end with a limiter: `| head -50`, `| tail -20`, `grep -m 20`, `wc -l` before contents, Read with offset/limit. If size is unknown, measure first, then read the slice you need. Read whole files only to edit them or copy verbatim. Truncating data you will transform corrupts output, so keyhole rules apply to inspection, never ingestion. If a peek was too narrow, take exactly one wider look.
3. **Probe the environment once.** Test all dependencies in one probe (`python3 -c "import x, y, z"`; `command -v tool1 tool2`) and install everything missing in one command, not one traceback at a time.
4. **Green means the task's own check.** If the task names verification commands, run them exactly as written; green = exit status zero. An environmental failure (missing package, compiler, tool) is still your failure: fix the environment and re-run. "Unrelated to my change" is not green. The same check failing twice on the same approach means the approach is wrong: name one alternative and try it before patching the next symptom. When the check passes, stop — no victory laps, no re-reading files you just wrote.
5. **Polling is a step.** An unfinished command is no new information. If the harness returns while a command still runs, wait in large slices (30 s or more; minutes for builds and test suites). Never re-poll at 1 s intervals or send empty input to peek. Where execution blocks until completion, this costs nothing. Prefer background tasks that wake you over polling, and keep a secondary wide-interval long-poll in case the wake fails.

## Waits must fire on the failure mode

A condition built only from what you want (commit landed, file exists, test green) can never become true if the lane dies, so the wait sleeps until timeout while the work sits dead. Every wait needs:

- **success**: new commit / expected artifact / matching output;
- **failure**: `error`, `FAILED`, `Traceback`, `Killed`, `OOM` in the log;
- **stalled**: for a herdr lane, `herdr agent get <name>` no longer `working`; for a plain process, pid gone or last line older than N minutes;
- **a bounded timeout** printing an explicit `*_TIMEOUT` line, so silence is never ambiguous.

Lifetime decides the mechanism: a wait inside this session can be a `bash_bg` loop or a
`monitor`; a wait that must survive a session restart belongs in `systemd-run --user
--on-active=…` or an `agents-cron` task, paired with a prompt to this pane — nothing scheduled
wakes an idle session by itself.

Give stalled checks a ~45 s grace window, so the brief idle between a nudge and pickup does not false-fire. Print exactly one line per terminal state, carrying diagnostic state (agent status, dirty file count, timestamp, last log line) so the woken turn needs no recon round trip.

Lesson this encodes: a watcher armed only on `git rev-parse HEAD` changing sat silent for 40 minutes while a delegated agent went `idle` with 13 uncommitted files, and the operator spotted the dead lane first.

## Context measurement

Two different numbers, routinely confused:

| Number | Meaning | Where |
|---|---|---|
| `21.5%/1.0M` in the footer | **context used** | survey field |
| `CH99.8%` beside it | cache-hit rate | not a cost signal |

From a session file, sum `input + cacheRead + cacheWrite` — not `totalTokens`, which adds output. Newest file by **mtime**, not name (resumed sessions keep the original date). Skip zeroed usage rows.

Thresholds: >20% moderate, >30% moderate-high, >40% high, >50% very high. Above 50%, at a stop boundary: lane writes a continuation prompt to a `.md`, then `/compact` (mid-tranche, coherent) or `/new` (bloated, repeatedly resumed), then reads the file and continues.

## Do not build what was not asked

Never build a verification harness, test suite, or checker the task did not request. Verify stated properties with the shortest command that measures them, and spend the saved steps on the task. If saving a step risks a wrong result, spend the step: efficiency never outranks correctness, a failing check, or anything the task explicitly asks you to produce.