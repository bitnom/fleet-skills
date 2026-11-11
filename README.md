# fleet-skills — the fleet's own agent skills, under version control

**Public mirror:** <https://github.com/bitnom/fleet-skills> (the operator's own account; the fleet's
own remotes live under the Apothic-AI org, so this one is deliberate).

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
| `herdr` | `src/skills/fleet-skills/herdr` (fleet manual; product support stays in Herdr) |
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
| `herdr` | `~/.agents/skills/herdr` |
| `beads` | `~/.agents/skills/beads` |
| `lane-identity` | `~/.agents/skills/lane-identity` |
| `pi-goal-contracts` | `~/.agents/skills/pi-goal-contracts` |
| `pi-rooms-protocol` | `~/.agents/skills/pi-rooms-protocol` |
| `context-economy` | `~/.agents/skills/context-economy` |
| `pi-hermes-memory-usage` | `~/.agents/skills/pi-hermes-memory-usage` |
| `pi-persist-usage` | `~/.agents/skills/pi-persist-usage` |
| `agents-cron` | `~/.agents/skills/agents-cron` |
| `subrouter-provider-ops` | `~/.agents/skills/subrouter-provider-ops` |
| `llm-provider-benchmark` | `~/.agents/skills/llm-provider-benchmark` |

`subrouter-provider-ops` and `llm-provider-benchmark` arrived here on 2026-11-10 from the
load path itself: both were hand-authored straight into `~/.agents/skills` as plain
directories, with no history to diff and no copy anywhere else. This tree is now their
home, and both have a `repo` row in `skills/skills.tsv` so `skills-sync.sh install`
links them on any host. The load-path directories are still real directories until that
link replaces them — a follow-up for the parent of the FT-15 change, not part of the
copy itself.

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

## Spawn instruction boundary

`herdr/SKILL.md` is the fleet-owned derivative of the stable Herdr skill, not a
package patch. Keep CLI compatibility facts when refreshing it, but keep fleet
launch examples Pi/pil-only and role-neutral. `skills/skills.tsv` selects this
manual rather than the product skill. Do not copy the upstream spawn examples
back into the fleet load path. No live symlink change is implied by a candidate.

Run the native discovery/regression check from the Yellowstone root:

```bash
python3 src/skills/fleet-skills/check_spawn_instructions.py --repo .
python3 -m unittest discover -s src/skills/fleet-skills/tests -v
```

The discovery JSON records every inspected file and Codex occurrence, including
allowed historical/product-support references. Unknown Codex text on an active
instruction surface fails closed for review; support exceptions are exact text,
not a directory-wide exemption for fleet skills.

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

### The `profile-config` mishap, self-contained

On 2026-11-08 this repo was created by relocating eight skills out of `~/.agents/skills/` — and while
doing it, a ninth file, `~/.pi/agent/skills/profile-config/SKILL.md`, was **deleted by an `rm -rf`
against an assumed path**. It was restored byte-identical (`e157d02c…`, 14892 bytes), and **the
recovery was luck, not process**: only that file had a second copy (it ships from our own
`pi-profile-switch` fork). The **eight skills actually being relocated had no second copy anywhere** —
the same command against any of them would have been unrecoverable.

Full record: `~/Documents/Fleet/pi-fleet-model/INCIDENT-unconfirmed-rm-rf-2026-11-08.md`. These lines
are kept here too, deliberately, so the essentials survive even if `pi-fleet-model/` is ever pruned.

- **Run the same guarded `mv && ln` step for every item, including the last.** The eight real moves ran
  inside a `for` loop carrying a `[ -d ] && [ ! -L ]` guard; the ninth was hand-written outside it,
  which is what dropped the guard. The guard was right — leaving the loop removed it.
- **`profile-config` must stay a real file, never a symlink** (the `postinstall` rule above).
- **Scope a verification to what it actually read.** "No broken symlinks under `~/.agents/skills`",
  claimed from `find … -maxdepth 1`, was false: four nested ones exist (unrelated, not ours, not from
  this work). Use `find ~/.agents/skills -xtype l` for the whole tree.
- **A symlink changes who owns a file.** Versioning a *shipped* artifact by symlinking it freezes the
  upstream refresh path; versioning an *authored* one is the point.
