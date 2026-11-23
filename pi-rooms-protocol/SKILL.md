---
name: pi-rooms-protocol
description: pi-rooms messaging rules — pinning a stable name, why pane ids are correlation not identity, the two delivery states (queued/delivered) and why there is no ack, rooms_dm versus herdr agent prompt, reply-all instead of re-derived recipient lists, room history numbering and since, joining and leaving a room (rooms_leave), and the gate on who may create a room. Use when sending or answering an agent message, creating, joining or leaving a room, being asked to step out of a room or stop reading one, deciding whether to DM a working lane, troubleshooting a lane that cannot be reached by name, or reading a space's decision history.
---

# pi-rooms protocol

File-based messaging for pi sessions: DMs, reply-all, shared rooms with readable history. No daemon or server. State is plain files under `~/.pi/agent/rooms`.

Tools, ten of them: `rooms_who`, `rooms_pins`, `rooms_dm`, `rooms_reply_all`, `rooms_create`, `rooms_join`, `rooms_leave`, `rooms_post`, `rooms_read`, `rooms_list`.

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

That is everything the receipt records. There is **no `rooms_ack` tool and no `acked` state** — the extension registers ten tools and this is not one of them, and it declines a read state deliberately: it cannot see what a model does with a message after handoff. Do not invent an acknowledgement, and do not treat `delivered` as one.

Report only the recorded state. A successful send is not a read message.

## DM versus prompt

| | `herdr agent prompt` | `rooms_dm` |
|---|---|---|
| Delivery | interrupts or queues behind the turn | inbox, read when the lane checks |
| Fails when | pane is `working` — aborts the turn | never (not a turn) |
| Verifiable by | footer, `state_change_seq`, transcript | inbox file, or the lane replying |
| Best for | starting a turn: status request, handoff, resume | context and coordination, read-when-ready |

DM when the lane is `working` and the message is *context*, not a command. Prompt when the point is to start a turn.

## Messages are cut only when a truncation threshold is configured

Truncation is a config setting — `maxMessageChars` in `<base>/config.json` — and it is **off by
default**. `null`, `0` and `-1` all mean disabled: the whole message is stored and delivered. A
positive integer cuts every outbound body at that many characters and appends a marker. `rooms_dm`,
`rooms_post` and `rooms_reply_all` all write through one `sanitize()` call, so the threshold reaches
every path:

```ts
export function sanitize(text: string, maxChars: number | null = null): string {
  const cleaned = text.replace(/\r\n/g, "\n").replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, "");
  if (maxChars == null || !Number.isFinite(maxChars)) return cleaned;
  const limit = Math.floor(maxChars);
  if (limit <= 0 || cleaned.length <= limit) return cleaned;
  return `${cleaned.slice(0, limit)}\n… [truncated ${cleaned.length - limit} chars]`;
}
```

Sanitisation is separate and unconditional: control characters are stripped whether or not a
threshold is set, because disabling truncation must never be a way to put an escape sequence into
another agent's terminal.

**When a threshold is set, the sender sees success.** `rooms_dm` returns a delivery receipt for a
message that arrived cut, and the marker sits at the end of the stored text where the recipient may
not look. This is not a send failure and it is not the transport dropping anything: the message was
truncated at write time.

Two habits, and they have both been paid for:

1. **Substantive content goes in a file, not a DM.** Write the report/analysis/diff to a path and send
   the path plus a one-line summary. A DM is conversation; state belongs on disk. This is the same
   rule as "rooms carry conversation, not state", and it is why the default is safe: a fleet that
   never sets a threshold still should not paste a report into a message.
2. **When a message of yours is cut, send the tail — never resend the whole thing.** Start the follow-up
   with an explicit marker naming where the previous one stopped, so the recipient can splice them.
   Resending whole doubles the message and arrives cut at the same place.

Reading a message you received: if it ends mid-sentence or carries a `[truncated N chars]` line, the
rest was never sent — ask for it rather than inferring what it said. Under the default that line
cannot appear unless someone configured a threshold.

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

## Leaving a room

**Asked to step out of a room, or to stop reading it? Call `rooms_leave`. Do not silently stop reading.**
Stopping to read by hand leaves you a member: every post is still written into your inbox, still
counts against the room, and is still handed to your session on the next wake. There is a tool for
this, and "I can't remove myself, there's no leave-room action" is no longer true of this fleet.

```text
rooms_leave({ room: "dxdb" })                      // parts, and discards your queue for dxdb
rooms_leave({ room: "dxdb", discardQueued: false })  // parts, keeps the backlog
```

What it does, and the exact boundary of it:

- **Membership**: your name is removed from `room.json`. You receive no further posts from the room,
  and none are queued for you — a post after your parting writes no inbox file for you at all.
- **History**: the parting is appended as an *event* — `kind:"event"`, `recipients:[]`, delivered to
  nobody — rendered as `#12 15:00 · dxdb-core left the room`. It occupies a sequence number, so
  `since` cursors keep working across it. Joining records the same kind of event, but only on a real
  membership change, so a repeated join adds nothing.
- **`discardQueued` defaults to true and deletes files.** Narrowly: only messages in *your own*
  inbox, only those whose `room` is the room you left, only those not yet `deliveredAt`, and only
  top-level inbox files — the `read/` archive behind `rooms_reply_all` is untouched, as are other
  rooms, direct messages, other lanes' inboxes and all receipts. The tool reports the count it
  deleted. If you might want the backlog, pass `false`; those messages are still delivered after
  you leave, which is the whole point of the opt-out.
- **No replay on rejoin.** `rooms_join` re-admits you; posts made while you were out stay in the
  history and are never re-queued. Catch up deliberately with `rooms_read({room, since})`.
- **DMs are unaffected.** A lane that has left a room is still reachable with `rooms_dm`.
- **You cannot speak into a room you are not in.** `rooms_post` and `rooms_reply_all` both refuse
  until you rejoin, so leaving is an exit from the room's speech as well as its traffic.
- **The last member may leave.** The room keeps its history, stays listed by `rooms_list`, and stays
  joinable — leaving is never a way to delete a room.
- **Idempotent.** Leaving a room you are not in is a no-op that says so; an unknown room is an error.
- **Do not use a rename as a leave.** A rename changes the name you answer to but leaves the old name
  in `room.json`, still being queued posts into an inbox nobody drains. `rooms_leave` first, then rename.

**A discarded message's receipt stays `queued` forever.** Discarding deletes inbox files and leaves
receipts alone, so a receipt you hold for a message a lane discarded will never turn `delivered` and is
not evidence the message is still in flight. Treat a long-`queued` receipt as unknown, not pending.

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