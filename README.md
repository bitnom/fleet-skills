# fleet-skills — the fleet's own agent skills, under version control

These are the skills **this fleet authored and maintains**, as opposed to the ~140 vendor and
project skills that live beside them in `~/.agents/skills/`. They are on the load path of every
leader lane, so two lanes editing one silently — with no history to diff — is a real hazard. It
happened on 2026-11-08: `overlord-operations` was patched by `self-improvement-leader` while the
overlord was preparing a patch to the same file, and nothing recorded either edit.

## The convention

A skill lives in the repository it belongs to and is **symlinked** into the load root. That is already
how this machine does it for everything else:

| Skill | Lives in |
|---|---|
| `herdr` | `~/Code/yellowstone/herdr/skills/herdr` |
| `unblock` | `~/Code/apothic-monorepo-workspace/tooling/unblock/skills/unblock` |
| `yellowstone`, `hotshot` | `~/Code/yellowstone/...` |
| `dagr-producer` | the herdr plugin that ships it |
| `profile-config` | `~/Code/pi-profile-switch/skills/profile-config` (**exception — see below**) |

```bash
ln -sfn ~/Code/fleet-skills/<name> ~/.agents/skills/<name>
```

## Contents

| Skill | Symlinked at |
|---|---|
| `beads` | `~/.agents/skills/beads` |
| `lane-identity` | `~/.agents/skills/lane-identity` |
| `pi-goal-contracts` | `~/.agents/skills/pi-goal-contracts` |
| `pi-rooms-protocol` | `~/.agents/skills/pi-rooms-protocol` |
| `context-economy` | `~/.agents/skills/context-economy` |
| `pi-hermes-memory-usage` | `~/.agents/skills/pi-hermes-memory-usage` |
| `pi-persist-usage` | `~/.agents/skills/pi-persist-usage` |
| `agents-cron` | `~/.agents/skills/agents-cron` |

Two fleet-authored skills deliberately live elsewhere, because the convention is "the repo it belongs
to", and they belong to a space or a package rather than to the fleet at large:

- **`overlord-operations`** → `~/.overlord/skills/overlord-operations` (the overlord's own space repo,
  symlinked into `~/.agents/skills/`). It is the overlord's procedure, so the overlord owns and edits
  it, in its own history.
- **`new-space`** → `~/Code/new-space-skill` (its own repo, symlinked into the two spaces that may read
  it — `~/Documents/Fleet/.agents/skills/` and `~/.overlord/.agents/skills/`).

## The profile-config exception — do not symlink it

`profile-config` is **not** a fleet-authored standalone skill: it is a *shipped* artifact of the
`pi-profile-switch` package. Its `postinstall` writes `skills/profile-config/SKILL.md` into
`~/.pi/agent/skills/profile-config/` **only when that file does not exist**
(`test/postinstall.test.ts`, "First install - writes shipped skill when skills/profile-config does not
exist").

So it must stay a **real file**, not a symlink:

- a symlink would satisfy the installer's `existsSync` check, so package updates would silently stop
  refreshing the skill — a quieter and worse failure than an untracked copy;
- the version history it needs is the package's: `~/Code/pi-profile-switch` is our fork, and that repo
  is where an edit belongs.

To restore or re-sync it, copy from the source rather than editing in place:

```bash
cp ~/Code/pi-profile-switch/skills/profile-config/SKILL.md ~/.pi/agent/skills/profile-config/SKILL.md
```

As of 2026-11-08 the fork's copy, the installed package's copy and the load-path copy are all
**byte-identical**: `e157d02cb0f874dda1885392de97ad0522a94b7ee52004a6aa30736251c3f4ed`, 14892 bytes.

## Verifying the whole arrangement

```bash
for s in beads lane-identity pi-goal-contracts pi-rooms-protocol context-economy \
         pi-hermes-memory-usage pi-persist-usage agents-cron overlord-operations; do
  printf '%-26s %s\n' "$s" "$(readlink -f ~/.agents/skills/$s/SKILL.md || echo BROKEN)"
done
sha256sum ~/.pi/agent/skills/profile-config/SKILL.md   # must equal the pi-profile-switch fork's
```

A broken symlink is worse than a plain directory: the lane loses the skill with no error. `readlink -f`
is the check, not `ls`.

## Pitfalls learned here

- **Never `rm -rf` a path you have not first confirmed you moved.** Relocating `profile-config` was
  attempted on the assumption it was in the same root as the others; it was not, and the real file was
  deleted. It was recovered byte-for-byte only because the package it ships from is our fork — had it
  been genuinely untracked, the content would have been gone.
- **`mv` then `ln` in one command, per item**, so the window where a skill path is absent is
  milliseconds rather than a whole loop.
- **A symlink changes who owns a file.** Versioning a *shipped* artifact by symlinking it freezes the
  upstream refresh path; versioning an *authored* one is the point.
