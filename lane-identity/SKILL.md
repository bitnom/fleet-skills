---
name: lane-identity
description: How a lane's name is derived and where it must match — herdr agent name, PI_ROOMS_NAME, and the dagr task owner, all from the herdr tab label at spawn via pil. Use when starting, naming, renaming, or re-identifying an agent lane, when a lane appears unnamed or under a numeric or pid-suffixed name, when writing a dagr owner field, or when a lane cannot be reached by name.
---

# Lane identity

A lane's name is its identity and must be the **same string on three surfaces**: the herdr agent name, `PI_ROOMS_NAME`, and the dagr task `owner`. It is derived from the herdr **tab label**, slugified.

## Starting a lane

Fleet lanes use only Pi, regardless of role. In agent-issued spawn commands use
`herdr pane run <verified-new-pane-id> "pil"` after naming the new tab and
verifying its shell is ready. Use only the mode/profile authorized by the brief;
this example chooses no role. Other harness names in support docs are not launch
instructions. See the fleet `herdr` skill for the full topology/readiness checks.

Start it with `pi` inside its herdr pane, or `pil` explicitly (`~/.local/bin/pil`). `pil` derives the name from the tab label, exports `PI_ROOMS_NAME`, renames the herdr agent in the background, and always execs the real binary without blocking the spawn.

- Interactive shells get this automatically: `.bashrc`/`.zshrc` define `pi()` as a `pil` shim when `HERDR_ENV=1`.
- **Agent shell calls are non-interactive and do not source rc files.** An agent spawning a lane must call `pil` by name.

## Name the tab before starting the lane

The name is taken at spawn, so renaming the tab afterwards does not rename the lane. herdr auto-names a fresh tab with a bare number (`12`), and `pil` refuses such a label — so an unnamed tab yields an *unnamed* lane rather than one called `12`, which is the correct failure.

## Never pin instead of naming

Do **not** write a name into `~/.pi/agent/rooms/names.json` as a substitute for naming at spawn. A pin is stamped with the claiming process's `pid+starttime` and is rejected by any other process, so it is lost on every restart. A pin is only for correcting a running lane you cannot restart now. (Before `d4d0bfa`, 2026-11-01, the check compared the whole identity string including the process *state*, so a live process's own pin was also rejected after it went idle. The stamp is start time; state is not identity.)

`~/.overlord/tools/rooms-names.json` is retired. Do not re-apply it, quote names from it, or treat absence there as meaning a lane is unnamed.

## A name with a participant record is reserved

A human participant's name lives in `~/.pi/agent/rooms/participants/<name>.json`, and that record is the **only** reservation the protocol has: a pin cannot hold a name for a human, because pins are stamped with the writing process's pid+starttime and are rejected by any process that did not write them.

Check that directory before naming a tab. `claimName` returns an unowned name **unsuffixed** (`src/store.ts:415`), so a tab labelled with a human's name is claimed silently by the next lane started in it — no warning, no suffix, and two writers then share one inbox. If a lane has already taken a reserved name, that is a collision to report, not something to rename around quietly.

## Renaming a running lane

`pil --rename [name]` renames the herdr agent immediately (and pins the pane when the lane has no `PI_ROOMS_NAME`). `PI_ROOMS_NAME` is fixed for the process's life, so the rooms identity follows on the *next* restart. Renaming is leave-and-join for rooms: it drops the old registration and any room memberships.

**Renaming can leave you unregistered — verify it, don't assume it.** The pin `pil --rename` writes is stamped with *pil's* pid+starttime, and a pin is rejected by any process that did not stamp it. The rename therefore drops the old registration and the new pin is not adopted by the running session: `rooms_who` then reports **"No agents registered"**. Observed 2026-10-31 on a live lane. **This symptom has a second, unrelated cause:** until `d4d0bfa` (2026-11-01) pi-rooms pruned any registration whose process had changed sleep/run state since it wrote, so `rooms_who` reported "No agents registered" for reasons that had nothing to do with renaming. Do not infer a bad rename from an empty roster alone.

Repair, in order:

1. `rooms_pins` `set` with key `pane:<HERDR_PANE_ID>` and the new name — this tool's pin resolves on every call, so the running session adopts it live.
2. `rooms_who` again and confirm the new name appears. A pin that is written but not adopted looks identical to one that is (see `rooms_pins` `list`).

Prefer renaming **before** joining rooms, or expect to rejoin every room afterwards.

## Never run `pil` from inside a lane

`pil` derives the lane name from the **tab label of the pane it runs in**. Running it from an agent's own shell therefore makes a short-lived child claim *that lane's* name: it registers, the child exits, and its leave-and-join deregistration **deletes the real lane's registry entry**. The lane keeps its footer name (resolved from the pin) while `rooms_who` reports no agents — so it looks fine and cannot be reached.

Observed 2026-11-01: a `PI_PROFILE=worker pil --print` smoke test run from inside the `pi-leader` lane silently deregistered `pi-leader`. Before that call `rooms_who` listed the lane; after it, the registry was empty.

Rules:

- To test `pil` or the launcher, run it from a **scratch cwd in a pane with no lane**, or pass `PI_LANE_NAME`/`PI_ROOMS_NAME` explicitly so the child cannot collide with a live lane.
- After any such test, immediately `rooms_who` and re-pin if the lane vanished.
- A footer name is not evidence of registration. `rooms_who` is — but it was a **lower bound**, not ground truth, until `d4d0bfa` reached every lane (see above): registrations flapped with process state. The check that survives both defects is a delivery round-trip — send a DM and read `deliveredAt` from its receipt. A lane running older code still flaps.

## owner is never a role

dagr `owner` = the lane name. It is never:

- a role — `leader`, `orchestrator`, `operator`
- a harness — `droid`, `opencode`, `pi`, `codex`
- a pane id — `wF:pC`

None of those resolve to anything live.

## Checking the join

`swarm-topology` is a stateless read-only join of herdr + dagr + pi-rooms. Re-run it rather than trusting a remembered frame: it can be old, but it never drifts.

Pane ids (`HERDR_PANE_ID`, `HERDR_TAB_ID`, `HERDR_WORKSPACE_ID`) are a **correlation attribute**, not identity: they are positional and recycled, meaningful only paired with pid + starttime + boot id.