---
name: shared-flyio-build-server
description: Use when a Rust build needs more disk or CPU than the local machine has, when cargo-remote-3000 is mentioned, when compilation must be offloaded to the shared Fly.io build server, or when a remote build fails and the cause is unclear. Covers starting and stopping the box, provisioning it after a restart, cargo-remote-3000 usage and per-project setup, sharing CPU between concurrent projects, and the traps that silently break it.
---

# Shared Fly.io build server

One Debian machine builds any Rust project on request. It exists because local
disks fill up: a single large workspace here had a 32G `target/debug` against
18G free, so building locally was not slow but impossible.

Projects do not install anything global and do not need accounts. A project adds
a cargo-remote-3000 config and runs `cargo remote-3000`.

**Two skills, two halves.** This one is host-specific: the Fly app, the machine,
provisioning, and scale-to-zero. What the *tool* does — lanes, concurrency,
toolchain selection, exit codes — is the contract in the `cargo-remote-build`
skill (`~/.agents/skills/cargo-remote-build`, installed from
`cargo-remote-3000/cargo-remote-build-skill`). When they disagree, the tool's
own `--help` and the `cargo-remote-build` skill win for build behaviour, and
this file wins for host lifecycle.

## The machine

| | |
| --- | --- |
| App | `open-surrealdb-ds-builder` |
| Machine | `87477e0cd01748` |
| Region | `iad` |
| Spec | `performance-4x` — 4 dedicated cores, 16 GB (`nproc` = 4, verified 2026-10-30) |
| Volume | 250 GB at `/data` (grown from 100 GB on 2026-10-25) |
| Base | `debian:bookworm-slim` (glibc) |
| ssh | `fly-builder` alias, port **2222** |
| User | `root`, key-only |

Reached over **Fly 2PN** (wireguard). There is no public SSH port and no public
HTTP service. Do not add one.

## Growing `/data` when it fills up

The volume fills because every project keeps a warm `target/` under
`/data/builds/`. On 2026-10-25 it reached **0 bytes free** with another project
mid-compile. Growth is online and does not disturb running builds.

**Ask the human first.** Extending a shared volume changes the bill and affects
every project on the box. It is a coordination decision, not routine cleanup.

```bash
# 1. find the volume id and its current size
flyctl volumes list -a open-surrealdb-ds-builder

# 2. extend to a new TOTAL size in GB (not an increment). No restart needed here.
flyctl volumes extend vol_vdewd65ldwkqj14 -a open-surrealdb-ds-builder -s 250 -y

# 3. verify the filesystem grew
ssh fly-builder 'df -h /data'
ssh fly-builder 'resize2fs /dev/vdc'   # idempotent; prints "Nothing to do" when already grown
```

`/data` is a **bare ext4 device with no partition table** (`findmnt -no FSTYPE
/data` says `ext4`). That is why no `growpart` step is needed; `growpart` is not
even installed. If the filesystem ever becomes a partition instead, that changes
and step 3 becomes `growpart /dev/vdc 1 && resize2fs /dev/vdc1`.

Both steps are safe while builds run. Confirm with `ps -eo comm= | grep -qxE
'rustc|cargo'` before and after if you want to prove you disrupted nothing.

Check headroom with `df -h /data` **before** a build with a cold dependency
graph. A workspace with SQLite and `wasm-bindgen` uses 2-4 GB, and the box had
accumulated 89 GB across 16 build trees.

## Starting and stopping

```bash
flyctl machine start 87477e0cd01748 -a open-surrealdb-ds-builder
flyctl machine status 87477e0cd01748 -a open-surrealdb-ds-builder
flyctl machine stop  87477e0cd01748 -a open-surrealdb-ds-builder
```

### ALWAYS scale it back to zero when you are done

**The machine bills for every second it runs, whether or not anyone is building.**
A host-side supervisor (below) is the authority and stops an idle box on its own;
this section is for when you want it stopped *now*, or when the supervisor is not
installed. Run `flyctl machine stop` as the last step of a session that needs the
box down immediately, before you report back and before you hand off.

This applies to every exit path, including the messy ones:

| Situation | What to do |
| --- | --- |
| Build finished, gates green | stop it |
| Build failed or you are blocked | stop it; `machine start` restores the same volume |
| Task handed to another agent or session | stop it unless they are mid-build right now |
| Interruption, context reset, `herdr` detach | stop it — an agent that never resumes still leaves it running |
| You only needed `flyctl machine status` or a volume query | you did not need it running; if it was already up, leave it up only if a build is in flight |

Check before you stop, and only then:

```bash
flyctl machine status 87477e0cd01748 -a open-surrealdb-ds-builder
```

`State: started` means you are paying. Two checks worth doing before stopping,
because stopping is not free for another agent:

```bash
# Is anyone actually building right now?
ssh fly-builder 'pgrep -a -f "cargo|rustc|wasm-pack" | head'

# Will they lose anything by losing power?
ssh fly-builder 'du -sh /data/builds/* 2>/dev/null'
```

Nothing on `/data` is lost by a stop. The volume stays attached to the machine,
so the toolchain, the crates.io cache, the `libs/` seed and every warm
`target/` survive; only the root filesystem is discarded. A stop mid-`cargo`
aborts that build, which is why the `pgrep` check comes first — it is the one
case where stopping costs another agent real work.

Two details that make the stop/restart cycle safe:

- `flyctl machine update` leaves a machine **stopped** — start it again after
  any update, or the next command fails with "machine not running".
- A stopped machine still **bills for the volume**. Scale-to-zero removes the
  compute bill, not the storage bill; that is the intended trade, since storage
  is what makes the next build fast.

## After every restart

The root filesystem is ephemeral, so apt packages and `/usr/local/bin/builder-*`
are gone after any stop. Only `/data` persists. Do not hand-roll this — one command
repairs everything, in the order that works:

```bash
cd apps/starla-staging
scripts/build-server.sh start     # transport, bootstrap, ssh, reconcile
scripts/build-server.sh sync      # same repair on a box that is already started
```

What it fixes, and why the order matters: `ensure-ready` (one word, so `flyctl`'s
argv-splitting cannot break it) reinstalls packages and starts sshd, so it must
run **before** anything waits for ssh — a cold boot has no sshd until it does, and
reaches port 2222 about **4m20s** after `machine start` (measured twice on
2026-11-01). `flyctl machine exec` is not a usable success signal: its client times
out at 120–300s while the command keeps running and succeeds on the box, and
retrying on that timeout starts a second `ensure-ready` contending for the dpkg
lock.

```bash
# what the wrapper does, by hand, in this order
flyctl machine start 87477e0cd01748 -a open-surrealdb-ds-builder
flyctl machine exec -a open-surrealdb-ds-builder --no-container \
    87477e0cd01748 /data/bin/ensure-ready   # then poll ssh; do not retry it

# only on a fresh volume, or after changing provision-debian.sh
ssh fly-builder 'sh -s' < "$SKILL_DIR/provision-debian.sh"
```

## Using it

```bash
export PATH="$HOME/.cargo/bin:$PATH"

cargo remote-3000 -r fly -d 1.95.0 check  --workspace --all-targets
cargo remote-3000 -r fly -d 1.95.0 clippy --workspace --all-targets -- --deny warnings
cargo remote-3000 -r fly -d 1.95.0 test   --workspace
```

`-d 1.95.0` is **not optional** — see Traps. Put it in a project `Makefile` so it
cannot be forgotten:

```make
CARGO   := cargo remote-3000 -r fly -d 1.95.0
remote-check:
	$(CARGO) check --workspace --all-targets
```

Artifacts come home **only** with `--copy-back`, so `check`, `clippy` and `test`
return output and nothing else — which is the point. To fetch one binary:

```bash
cargo remote-3000 -r fly -d 1.95.0 build -c=debug/my-app -p my-app
```

`-c` alone copies the whole target tree. Do not: large debug binaries are
 gigabytes and that refills the local disk the server exists to protect.

Long builds block, so run them detached and poll the log rather than holding a
terminal open:

```bash
setsid nohup sh -c 'cargo remote-3000 -r fly -d 1.95.0 test --workspace \
  > /tmp/remote.log 2>&1; echo "EXIT=$?" >> /tmp/remote.log' >/dev/null 2>&1 &
tail -f /tmp/remote.log
```

## Per-project configuration

User-level config already defines the `fly` remote, so most projects need
nothing. A project overrides by adding its own `.cargo-remote-3000.toml` in the
repo root — it merges field-by-field with the user config by remote name.

Nothing project-specific needs arranging by hand: cargo-remote-3000 names each
tree after a hash of the project path and, since 0.5.0, puts it in a **lane**
under `/data/builds/lanes/<lane>/<hash>`. Concurrency is per lane, so several
builds of the same checkout run side by side instead of fighting over one
`target/`. Do not hand out build directories or lock files: use `--lane` when a
particular tree is wanted, and let the tool allocate otherwise.

## Sharing the box between projects

`/data` layout:

| Path | Shared? | Contents |
| --- | --- | --- |
| `/data/cargo` | yes | `CARGO_HOME` — crates.io download cache |
| `/data/rustup` | yes | `RUSTUP_HOME` — the toolchain |
| `/data/builds/lanes/<lane>/<hash>` | no | one tree per (project, lane), each with its own `target/` |
| `/data/builds/lanes/<lane>/<hash>.lock` | no | that lane's lease (the tool holds it for the compile) |
| `/data/builds/incoming/<hash>/<run-id>/` | no | per-run staging, outside every lane; pruned after a day |
| `/data/builds/<hash>` | no | **pre-0.5.0** trees; unused until moved into `lanes/default/` |
| `/data/projects/<slug>/` | no | per-project seed + build root + owner (see below) |
| `/data/ssh` | yes | sshd host key, authorized_keys, config |
| `/data/bin` | yes | `ensure-ready`, `builder-*` (the on-volume copies) |
| `/usr/local/bin/builder-*` | no | same scripts, restored from `/data/bin` each boot |

`CARGO_HOME` is shared deliberately: two projects depending on the same crates
download and extract them once. Cargo locks the registry while fetching, so
concurrent builds can block briefly — correct, just not instant. Compiled
artifacts are **not** shared; they live in each project's own `target/`.

CPU: the shared cargo config caps one build at `[build] jobs = 4`. The machine is
**4 cores / 16 GB**, so one build at `jobs = 4` owns the box and anything running
beside it oversubscribes. cargo-remote-3000 0.5.0 and later handle this: before
compiling, a build counts the lanes already leased and exports
`CARGO_BUILD_JOBS = cores / (others + 1)`. Do not raise the ceiling by hand —
that is how four builds end up with sixteen threads on four cores.

### Per-project isolation: `builder-project`

The path hash isolates `target/`, but nothing isolated the **path-dependency
seed**, and that bit for real: one `starla` workspace pins `openai-oxide 0.14.0`
while another uses `0.17.0`, both resolved `../../libs` to the single
`/data/libs`, and the build failed with

```
failed to select a version for the requirement `openai-oxide = "^0.14.0"`
  candidate versions found which didn't match: 0.17.0
```

which reads like a broken manifest and is actually one project overwriting
another's dependency vintage. `builder-project` gives each project its own unix
user and directory:

```bash
ssh fly-builder 'builder-project ensure starla'   # once per project
ssh fly-builder 'builder-project list'            # size + last activity per project
```

```
/data/projects/<slug>/libs     that project's path-dependency seed
/data/projects/<slug>/builds   its cargo-remote trees (--temp-dir)
```

owned by user `<slug>`, so the kernel enforces who may write what, and two
vintages coexist instead of fighting. A wrapper points `--temp-dir` and the seed
at that root when the project user exists; see starla's
`scripts/remote-cargo.sh`.

**The lane layout moved every build root two levels deeper** (0.5.0):
`<temp-dir>/lanes/<lane>/<hash>` instead of `<temp-dir>/<hash>`. A seed that used
to sit at `<slug>/libs` now has to be at `<slug>/builds/lanes/libs` for the same
`../../` to resolve, and a wrapper that seeds by hand must be re-checked against
`-v` output before its builds are trusted.

**What this does and does not enforce.** The seed and build root are per project,
which is the collision that actually happened. A build still executes as root,
because cargo-remote composes and runs the remote command itself
(`cd DIR; cargo ...`) and offers no hook to switch user; closing that needs a
per-project forced-command ssh endpoint with its own key. Do not describe the box
as "uid-isolated" until that exists. The shared `/data/cargo` registry stays
shared deliberately: it is content-addressed, cargo locks it, and a private copy
per project would cost 1.5 GB each.

### Scale to zero, enforced

The billing leak was never one long build: it was 21 recorded `machine start`
invocations across sessions with stop paths that nobody reliably ran. It is now a
**host-side systemd timer**, not a runbook step:

| Piece | Where |
| --- | --- |
| timer + unit | `~/.config/systemd/user/starla-build-server-supervise.{timer,service}` |
| the supervisor | `apps/starla-staging/scripts/build-server-supervise.sh`, every 5 minutes |
| the verdict | `builder-idle --status`, computed **on the box** |
| transport repair | `apps/starla-staging/scripts/ensure-build-transport.sh` |

There used to be a second, independent stop path (the retired
`fly-builder-idle-stop`, 15-minute timer, now disabled): two opinions about
idleness is a hazard disguised as redundancy, and it lived in a directory that is
in no repo. Its one unique signal — filesystem churn — is now part of the box's
verdict. There is one authority, and it stops the machine only when all four
answers say idle:

1. **`builder-state park` succeeds** — no builder-state lease is held. A lease is
   also **aged** (`LEASE_START_GRACE`, 180s): past that with no compile and no
   churn it is logged as stale and stops vetoing the stop. A lease is a promise
   the *client* makes, so a killed client leaves one standing that nothing can
   withdraw — measured 2026-11-01, one killed wrapper left the box permanently
   `leased`, `park` refused, and this verdict said `leased` forever while a machine
   nobody was using billed all night. The same measurement showed why a lock is
   not a record: an orphaned child that inherited the lock fd keeps it held after
   its recorded holder is pruned, so `leased:true` with `leaseCount:0` names
   nobody. That unattributable lock is logged and ignored; a real build still
   shows up in the process check below;
2. **no `cargo`/`rustc`/`rustdoc`/`wasm-pack` process** — catches builds that
   never took one; a zombie of one of those does not count, because nothing reaps
   it and it would otherwise pin the verdict at `building` for the whole boot.
   Live processes are `building` unless they are **wedged**: no CPU work, no churn,
   no attached client, unbroken for `WEDGE_GRACE` (1200s). That answer is
   `wedged`, which the supervisor treats as a stop, and it exists because a
   process alive is not progress — dxdb measured an orphaned box-side `cargo`
   parked in `do_wait` on a deadlocked test binary with 0.00 load for 20–38
   minutes while seven lanes queued behind it. Killing the child is what releases
   such a tree, not any lock, so nothing on the box tries to tidy it up. A live
   binary under `target/{debug,release}/deps/` vetoes this rule entirely: a
   sleeping test and a deadlocked one are indistinguishable from inside the box,
   and only the client can tell them apart;
3. **CPU below 10% of one core over the gap since the previous poll** — `delta
   jiffies / elapsed seconds` from `/proc/stat`, so it measures work done and a
   futex-blocked *or* CPU-bound test binary cannot hide behind either. It must sum
   work fields only (user+nice+system+irq+softirq+steal): summing the whole line
   includes `idle`, which counts wall time × cores and reads `cpu-active` forever.
   The 10% is the margin over the sampler's own cost (ssh handshake, login shell,
   churn scan — a few CPU-seconds per poll); a build is hundreds in the same window.
   A negative delta means a stale baseline from a previous boot: `warmup`, not `idle`.
   **Sample once per poll and reuse it.** The sampler writes the baseline on every
   call, so calling it twice makes the second call compare against the sample the
   same poll just wrote — elapsed 0, no rate, `warmup` on every poll forever, and
   `idle` unreachable. This was live in the working tree on 2026-11-02 and is what
   the `rate` reuse in `verdict()` exists to prevent;
4. **no churn under `/data/builds` or `/data/projects` for `CHURN_WINDOW_MIN`
   (default 10 minutes)** — `find -maxdepth 6 -newermt`, newest match, so a lane
   tree three levels down is seen. Starla builds under `/data/projects/<slug>`,
   which is why both roots are scanned.

Any answer other than `idle` also clears the accumulated grace, so a batch of
interleaved busy and idle polls can never stop the box.

**Residual risk:** `recent_churn` does not scan `/data/cargo`, so an unleased
build parked for 20+ minutes on a registry download (writes go to the registry
cache, not a build root) is indistinguishable from a wedge and would be stopped.
Every lease-holding build is protected by `lease_watched`, and cargo-remote-3000
holds its own lane lock the host cannot see, which is why this has not bitten yet.
If a build is ever killed this way, add `/data/cargo` to the churn roots rather
than lengthening the grace.

Three things here were fixed only after they bit, and each restored the same
billing leak in a different disguise:

- **"Unreachable" is not a no-op, and the transport is a prerequisite.** The box
  is reached only over its own `/48`, carried by a WireGuard interface (`ds`)
  that is **disabled at boot**; `fly-personal` is a different `/48` and looks like
  a working tunnel. Measured cost: 622 consecutive polls over **~52 hours** with
  the machine started, billed and unreachable, logged at default priority while
  the supervisor did nothing. `ensure-build-transport.sh` now derives the prefix
  from the ssh alias, tests *that* prefix (not the default route — a ProtonVPN
  interface answers `ip -6 route get` for an address nothing can carry), repairs
  the tunnel, and a started box that stays unusable for `UNUSABLE_SECONDS` is
  logged at `user.err` and stopped: every build path here is ssh, so a box nobody
  can reach is doing nobody's work.
- **A cold boot has no sshd for ~4 minutes.** Measured twice: `machine start` →
  sshd accepting at 4m14s and ~4m20s. Anything that waits for ssh before running
  `/data/bin/ensure-ready` (which is what starts sshd) can only succeed by luck.
  `flyctl machine exec` is also not a success signal: its client gives up at
  120–300s while the command keeps running and succeeds, and retrying starts a
  second `ensure-ready` that contends for the dpkg lock. Fire it once, poll sshd.
- **A restart silently downgrades the box.** `/usr/local/bin/builder-*` are on the
  ephemeral root filesystem, so a rebooted box runs builds **unleased** and answers
  `{"verdict":"unknown"}`, which can never be stopped on. The repair existed in
  the provisioner but the copy deployed on the box predated it, so it never ran.
  `start`/`sync` reconcile the tools and the `ensure-ready` body *from the
  provisioner* and verify by asking the box.
- **The grace window has to be accumulated by whoever polls.** The box cannot
  sample itself (no Fly credential, by design), so `--status` maintains the idle
  marker: set on `idle`, cleared by any other verdict, clamped to the current boot
  so a marker from a previous boot cannot short-circuit it. A stranded 142329s
  marker was stopped on once; the supervisor now requires `idleSeconds >= 900`,
  i.e. three consecutive idle polls.
- **`churn_age=0` means "nothing changed in the window", i.e. idle**, and the
  churn window must reach the trees: lanes live at
  `/data/builds/lanes/<lane>/<hash>` and starla builds at
  `/data/projects/<slug>/builds`, so both roots are scanned.

**cargo-remote-3000 0.5.0 and later do not take builder-state leases.** The tool
leases its own lane (`<lane>/<hash>.lock`), which the host cannot see, so answers
2–4 are what protect those builds: compiles by process, CPU-bound tests by the
CPU rate, and the gap between two processes by the churn window. A hand-run
`builder-state lease` is still right for anything the tool does not drive — a
shell running `cargo` by hand, a long import in `psql`.

Verified live on 2026-11-01: a cold-booted box had no `builder-*` at all and
answered `{"verdict":"unknown"}`; the supervisor repaired it and got
`{"verdict":"idle","idleSeconds":0}` and correctly did **not** stop — the grace
window is three polls. A fresh boot also reaches sshd in ~4m20s, so the start path
budgets 480s and polls the port.

The box **cannot** stop itself and should not be given a token to do so: it was
created with `machine run` on `/bin/sleep`, so PID 1 carries no `FLY_*`
environment and there is no machine credential on the volume. Planting one would
put a standing API token on a box that any build can read. So the box answers,
and the host — where `flyctl` already lives — acts.

### Leases: admission control, not a mutex

`builder-state lease <name> -- <cmd>` holds a **shared** `flock` for the command's
lifetime; `builder-state park` needs it **exclusively**. N builds hold leases at
once — parallel builds are the point — and a stop is refused while any is live.
The lock lives on the box so registration and the decision read the same state,
which is what closes the check-then-stop race that killed a sibling build.

Two rules that cost real time:

- **A lease must span only the compile.** An earlier wrapper held one for a whole
  local session, so two shells with no `cargo` descendant looked exactly like a
  stuck build and had to be `park --force`d to resize the machine.
- **Never release by killing the local ssh.** The remote shell reparents to init
  and keeps the lock forever; that leaked a lease that blocked every later park.
  Release by closing the writer's end of a fifo so the remote `read` sees EOF.

## Traps

Each of these cost real time.

**Pin the toolchain, and know what the pin now does.** Up to 0.4.0, `-d` ran
`rustup default <that>` on *every* build, re-pointing the compiler for every other
build on the box; with no `-d` it installed and switched to `stable`. Since
0.5.0, `-d/--rustup-default` (alias `--toolchain`) exports `RUSTUP_TOOLCHAIN`
for that build's process tree only, and there is now a **config-file key**
(`toolchain = "1.95.0"` under `[[remote]]`), which is where it belongs. With no
pin anywhere, the box's own default applies, and a repository's
`rust-toolchain.toml` takes precedence over it. The box has one toolchain,
1.95.0; anything else is installed on demand, announced, and does not become the
default. Pin 1.95.0 in the Makefile so a compiler bump cannot be mistaken for a
contract change.

**A toolchain key that does not parse pins nothing.** Config parsing ignores
unknown keys, so a misspelled field reads like a guarantee. `toolchain` is a real
key as of 0.5.0; verify with `-v` when a pin seems to have no effect.

**`--` before the cargo arguments is not optional.** cargo-remote parses its own
flags *after* the cargo subcommand as well, and `-p` is its `--ssh-port`. So
`cargo remote-3000 -r fly -d 1.95.0 test -p my-app` fails with `invalid value
'my-app' for '--ssh-port <PORT>'` — the value is not a port, so it never gets as
far as cargo. The `--` terminator is what keeps cargo's `-p` away from
cargo-remote's. Every example here carries it.

**`env` in the config is a list of files to source, not `KEY=VALUE`.** Setting it
to a variable name replaces the default `~/.cargo/env`, and every build then
fails with `cargo: command not found`. Use `-b/--build-env` for variables.

**The platform's SSH on port 22 cannot run cargo-remote.** It argv-splits the
command instead of running it through a login shell, so `ssh host 'echo A; echo
B'` prints `A; echo B`. cargo-remote needs a shell twice: rsync's `--rsync-path`
is `mkdir -p DIR && rsync`, and its build script is `cd DIR; . env; cargo ...`.
Hence our own sshd on 2222. It also authenticates only Fly-issued certificates
there, which expire — another reason for 2222, which uses a plain key.

**`flyctl machine exec` and `flyctl ssh console -C` argv-split too.** They cannot
express `sh -c` or any shell syntax, so a bootstrap has to be a single-word
executable on the volume. That is what `/data/bin/ensure-ready` is.

**`rustup --no-modify-path` does not write `$CARGO_HOME/env`.** cargo-remote
sources that file, so without it builds fail with `cargo: command not found`.
`provision-debian.sh` writes it.

**`~/.cargo` must be a symlink to the shared `CARGO_HOME`**, because
cargo-remote sources `~/.cargo/env` while the toolchain lives on `/data`.
Those two symlinks live on the **ephemeral** root filesystem, so they vanish on
every stop even though their targets are on the volume — and the symptom is
`cargo: command not found` on a box that otherwise looks healthy.
`ensure-ready` now restores them, so the documented restart flow is sufficient;
if you ever see that error, check `readlink /root/.cargo` before suspecting the
provisioner.

**Path dependencies outside the project directory do not travel.** cargo-remote
uploads exactly one directory, and cargo resolves path dependencies for *every*
platform, not just the target being built. A crate declaring
`foo = { path = "../../libs/rust/foo" }` therefore fails before compiling
anything:

```
error: failed to get `foo` as a dependency of package `bar`
  failed to load source for dependency `foo`
```

`-w` fixes it only when the wider tree is cheap to upload — one big repo, not a
monorepo with nine checkouts. Otherwise seed the out-of-tree crates once at the
path the crate's own `../../` resolves to. **0.5.0 moved that path**: a tree now
lives at `/data/builds/lanes/<lane>/<hash>/`, so `../../` from the build root is
`/data/builds/lanes`, not `/data`. A seed left at `/data/libs` no longer resolves
and the build fails with the error above. Put it at `/data/builds/lanes/libs`
(the single shared seed `/data/libs` used to be) or, when two projects need
different vintages, `/data/builds/lanes/<lane>/libs` per lane — the same
collision `builder-project` exists to prevent. The volume is `/data`, so either
survives a stop.

**`--check`-style resolution probes must not use `cargo metadata --no-deps`.**
`--no-deps` skips path dependency resolution, so it passes on a box where the
real build fails. Probe with a full `cargo metadata --format-version 1`, which
resolves without compiling.

**C/C++ crates dominate build time.** `librocksdb-sys` alone took over ten
minutes. A first build on a fresh volume is 20–40 minutes; later ones are
minutes. Do not conclude the server is broken from a slow build — check it is
still `Compiling`, and watch `ps` on the box.

**Debian's bookworm has a different toolchain layout from Alpine**, and bindgen
reaches libclang by dlopen. `LIBCLANG_PATH` is set in the shared cargo config
from `provision-debian.sh`; if you build on a musl base instead, expect
`rquickjs-sys` to fail with "Dynamic loading not supported", which reads like a
missing package and is not fixable by installing packages.

## Files here

| File | What |
| --- | --- |
| `provision-debian.sh` | the live provisioner: packages, toolchain, cargo config, sshd, `ensure-ready`, and installing `builder-state`/`builder-idle`/`builder-project` |
| `provision.sh` | the earlier **Alpine** provisioner. Kept only as the record of why Alpine cannot be used: `fly-builder-glowing-aurora-7598` is the account's pre-existing remote builder, not ours, and musl fails as described below. Do not repurpose it again. |
| `fly.glibc.toml` | machine definition for the Debian box (see the warning below) |
| `builder-state.sh` | lease + park admission control (installed to `/usr/local/bin`) |
| `builder-idle.sh` | the idleness verdict (leases, processes, CPU rate, churn, wedge) |
| `builder-project.sh` | per-project user, seed and build root |
| `fly.toml` | machine definition for the Alpine one; documents why a build box must have no HTTP service |

**`fly.glibc.toml` and `fly.toml` do not describe the live machine.** Both name
`app = "fly-builder-glowing-aurora-7598"` and neither carries the 250 GB
`builder_data` mount; the running machine is app `open-surrealdb-ds-builder`,
machine `87477e0cd01748`, 4 CPU / 16 GB after the 2026-10-26 resize, with
`vol_vdewd65ldwdkqj14` at `/data`. Treat the table at the top of this skill as the
authority, and do not apply those files with `flyctl machine update` — that is a
paid-resource change and it would strip the volume mount.

`fly.toml` is worth reading for one non-obvious reason: an idle-stoppable HTTP
service on a build box gets the machine stopped mid-build, with no OOM and
nothing in its logs.

## Adding a project

1. Confirm the box is up (`machine status`). Start it if not: `machine start`, then
   `/data/bin/ensure-ready` — the root filesystem is ephemeral, so sshd and the
   apt packages are gone after every stop.
2. Add a `Makefile` target using `cargo remote-3000 -r fly -d 1.95.0`. Do **not**
   add a lane, a lock file or a stop step: the tool allocates a lane and the
   supervisor stops the box. Pass `-l <name>` only when the project needs one
   particular warm tree (a watch session, a benchmark).
3. Tell the project not to `cargo clean` locally before remote builds work.
4. **Do not add a scale-to-zero step to the build target.** That advice produced
   the 21 forgotten stops and the 35-hour bill; the timer covers every exit path,
   including an agent that never resumes. If a project must have the box down
   immediately, document that separately — the default is to leave it to the
   supervisor.