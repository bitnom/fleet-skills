---
name: pi-rooms-protocol
description: pi-rooms messaging rules — pinning a stable name, why pane ids are correlation not identity, the two delivery states (queued/delivered) and why there is no ack, rooms_dm versus herdr agent prompt, reply-all instead of re-derived recipient lists, room history numbering and since, and the gate on who may create a room. Use when sending or answering an agent message, creating or joining a room, deciding whether to DM a working lane, troubleshooting a lane that cannot be reached by name, or reading a space's decision history.
---

# pi-rooms protocol

File-based messaging for pi sessions: DMs, reply-all, shared rooms with readable history. No daemon or server. State is plain files under `~/.pi/agent/rooms`.

Tools: `rooms_who`, `rooms_dm`, `rooms_reply_all`, `rooms_create`, `rooms_join`, `rooms_post`, `rooms_read`, `rooms_list`.

## Pin the identity

Each session registers one name. Without `PI_ROOMS_NAME` the name is **cwd + a pid suffix** (`m2-core-309f`), which does not survive restart. Three lanes in one cwd become `overlord-18c7-46525`, `overlord-18c7-72208`, `overlord-18c7-73545` — indistinguishable to a human — and get new names after reboot, so **room membership silently empties across a restart**.

Pin `PI_ROOMS_NAME` for any lane that must be addressable. The durable route is naming at spawn via the tab label (see the `lane-identity` skill); a pin in `names.json` is a repair for a running lane, not a substitute.

## Name ↔ pane

Every pane env carries `HERDR_PANE_ID` (plus `HERDR_TAB_ID`, `HERDR_WORKSPACE_ID`, `HERDR_ENV=1`). Reading `process.env.HERDR_PANE_ID` is free (`undefined` without herdr) and adds no herdr dependency.

It is a **correlation attribute**, never identity: pane ids are positional and recycled, meaningful only paired with pid + starttime + boot id. It answers "which pane is this name now", never "which name is this".

## Liveness

Registration records `/proc/<pid>/stat` starttime and boot id, so dead processes and pids reused after reboot are detected rather than reported live. The roster previously climbed 35 → 37 → 41 with ghosts before this.

If a name will not answer, use that evidence rather than guessing. `rooms_who` means **registered**, not necessarily alive — two surfaces disagreeing means check the process table and trust neither alone.

## Delivery has two states, and there is no ack

- `rooms_dm` writing the inbox = **queued**
- the watcher handing it to the session = **delivered**

That is everything the receipt records. There is **no `rooms_ack` tool and no `acked` state** — the extension registers nine tools and this is not one of them, and it declines a read state deliberately: it cannot see what a model does with a message after handoff. Do not invent an acknowledgement, and do not treat `delivered` as one.

Report only the recorded state. A successful send is not a read message.

## DM versus prompt

| | `herdr agent prompt` | `rooms_dm` |
|---|---|---|
| Delivery | interrupts or queues behind the turn | inbox, read when the lane checks |
| Fails when | pane is `working` — aborts the turn | never (not a turn) |
| Verifiable by | footer, `state_change_seq`, transcript | inbox file, or the lane replying |
| Best for | starting a turn: status request, handoff, resume | context and coordination, read-when-ready |

DM when the lane is `working` and the message is *context*, not a command. Prompt when the point is to start a turn.

## Messages are cut at 4,000 characters, silently

`src/store.ts:28` — `export const MAX_MESSAGE_CHARS = 4000;` — and `:182-183` slices past it and
appends a marker:

```ts
if (cleaned.length <= MAX_MESSAGE_CHARS) return cleaned;
return `${cleaned.slice(0, MAX_MESSAGE_CHARS)}\n… [truncated ${cleaned.length - MAX_MESSAGE_CHARS} chars]`;
```

**The sender sees success.** `rooms_dm` returns a delivery receipt for a message that arrived cut,
and the marker sits at the end of the stored text where the recipient may not look. This is not a
send failure and it is not the transport dropping anything: the message was truncated at write time.

Two habits follow, and they have both been paid for:

1. **Substantive content goes in a file, not a DM.** Write the report/analysis/diff to a path and send
   the path plus a one-line summary. A DM is conversation; state belongs on disk. This is the same
   rule as "rooms carry conversation, not state", made concrete by a hard cap.
2. **When a message of yours is cut, send the tail — never resend the whole thing.** Start the follow-up
   with an explicit marker naming where the previous one stopped, so the recipient can splice them.
   Resending whole doubles the message and arrives cut at the same place.

Reading a message you received: if it ends mid-sentence or carries a `[truncated N chars]` line, the
rest was never sent — ask for it rather than inferring what it said.

**Test for truncation with an anchored match, never a substring.** `'[truncated' in text` is wrong:
a message that *quotes this section* contains the word and looks cut when it is whole. On 2026-11-03
that test produced 8 false positives in 39 messages, including two of the author's own — and sending
a "tail" for a message that was never cut doubles the recipient's reading for nothing. The marker is
always at the very end:

```python
import re
cut = re.search(r"\[truncated (\d+) chars\]\s*$", text)
```

Same class of error as a windowed pane count standing in for a baseline: an unanchored match reports
a state that is not the one it names.

## Answering

`rooms_dm` records its recipients; answer everyone with `rooms_reply_all({messageId})` instead of re-deriving the list. A room message answers back into the room.

## Rooms

`rooms_post({room, message})` appends to history and pushes to other members. `rooms_read({room})` numbers history by position, and `since: N` returns only new posts — the way a late joiner catches up.

**Membership is a trust boundary**: any member can put text into every other member's context, so add only agents whose work you would paste into your own prompt.

## Who may create a room

Creating rooms is a **lead/orchestrator** action, not a peer action.

- Create one only over agents you lead — ones you dispatched, own the work of, or are accountable for coordinating.
- Never include an agent you do not direct. Never create a room to convene peers, lobby for resources, or reach an orchestrator sideways; upward and sideways coordination goes through the operator.
- One room per owned unit of work. No per-task rooms, no duplicates — check `rooms_list` first.
- Members must exist and be running, or be expected to start under that name.
- **Workers and sub-agents**: post to rooms you were added to, answer with `rooms_reply_all`, never create rooms.

## Rooms carry conversation, not state

A room is not the board. Use a DM for one-to-one questions; use `/goal` plus herdr to assign and track work. Never duplicate a dagr task list into a room. Room posts are claims until verified.

For "what did a space decide", `rooms_read` the history rather than reconstructing it from memory or from a lane's summary.