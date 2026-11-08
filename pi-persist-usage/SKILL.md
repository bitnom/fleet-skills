---
name: pi-persist-usage
description: How pi-persist injects text into every request on this machine — the section channel that lives in the cached prefix versus the trailing channel that is never cached, the on/off switch behind /pi-persist-toggle, the CLI verbs and template placeholders, why to check `pi-persist list` after an edit, and the sizing rules that keep trailing items cheap. Use when adding, editing, or debugging context that must reach every lane on every request, when a lane's context looks missing, when a literal {{...}} placeholder appears in a prompt, or when deciding between a section and a trailing item.
---

# pi-persist: per-request context injection

`pi-persist` (`~/.pi/agent/pi-persist.json`, installed from `~/Code/pi-persist`) puts short text in front of the model on **every request, for every lane in this space**. Understand it before touching it.

## Two channels, opposite economics

| Channel | Where it lands | Cached? | Use for |
|---|---|---|---|
| `section` | the leading system prompt, inside the prefix | **yes** — changing it re-renders the cached prefix | session-constant facts: shell, platform, mode flags |
| `trailing` | appended as a `developer` message after the last tool result | **never** — small per-request cost, zero prefix invalidation | values that change or must be read every request: clocks, branches, task counts |

This is the same trade-off that governs pi-modes overlays and `pi-subdir-agents`: **mutate the tail, not the prefix.**

## CLI

File-only; no pi process needed.

```sh
pi-persist list                 # items, expanded against this machine
pi-persist add <id> <content> [--channel trailing|section] [--priority n]
                                [--providers a,b] [--tools x,y]
pi-persist remove <id> [--channel trailing|section]
pi-persist preset               # restore the shipped current_datetime item
```

- Takes effect on the next `/reload` or session start. Hand-editing the JSON is equivalent to the CLI.
- **Run `pi-persist list` after any edit.** It expands templates now, which catches a broken `exec:` before it renders literally in every lane's prompt.

## The switch

`/pi-persist-toggle` turns the extension on and off. Off injects **nothing**: no section, no
trailing message, no `exec:` command on the request path. The items stay in the file, so turning
it back on restores exactly what was there before.

- The state is `piPersist.enabled` in `~/.pi/agent/settings.json`. It is **global**, so a project
  cannot turn the operator's context on or off.
- **Check `pi-persist list` first when a lane's context looks missing.** It prints the state.
- `/pi-persist-toggle` flips it, `on` and `off` set it, `status` reports it.
- The command applies immediately; a hand edit of `settings.json` takes effect on the next
  `/reload` or session start.
- A session that starts with the switch off says so once, so a missing clock is not a mystery.

## Templates

| Template | Expands to |
|---|---|
| `{{datetime}}` | local datetime; variants `:iso`, `:date`, `:time`, `:unix` |
| `{{exec:<command>}}` | stdout of a shell command |

There is no environment-variable syntax — use `{{exec:echo $HOME}}`.

- Unknown placeholders stay **verbatim** and are reported. A literal `{{...}}` in a payload means an unresolved template.
- Malformed items are skipped, not fatal.
- `{{exec:…}}` runs arbitrary shell on every request. It is not a privilege boundary (a writer of the file can already run commands), but read items before adding, and never add one on your own initiative that reaches outside this machine.

## Current config

```json
{
  "version": 1,
  "items": [
    { "id": "current_datetime", "channel": "trailing", "content": "{{datetime}}", "priority": -100 },
    { "id": "todo_reminder", "channel": "trailing", "content": "Update your TODOs before starting new tasks and immediately after completing each one. Nested TODOs are supported." }
  ]
}
```

Both trailing — correct. Keep it that way.

## Do not

- **Do not put long text in a trailing item.** It is uncached and resent on every request of every tool loop in the turn.
- **Do not use a section for a value that changes during a session.** Every change re-renders the prefix and invalidates the cache for everything after it.
- **Do not inject `bd prime`, memory output, or anything that changes per-turn into a section.** Memories change on every `bd remember`; a change near the front invalidates everything after it. On-demand tool results are appended, so they never touch the prefix — that is the correct place for changing content.
- **Do not assume `current_datetime` is required.** It is an ordinary item; deleting it only removes the clock.
- **Do not flip the switch to quiet one item down.** The switch silences every lane at once — the clock, the section, and anything another extension contributed. Edit the item instead.

## Related prompt surfaces

pi-persist is one of six surfaces that shape what a lane reads. It is **outside** pi-modes and pi-profile-switch, so no mode or profile can reorder, suppress, or version it. Changing it changes every lane at the next `/reload`.