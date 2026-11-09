#!/bin/sh
# Provision the Fly build server for open-surrealdb-ds.
#
# Idempotent and safe to re-run. Debian bookworm, glibc.
#
#   ssh <host> 'sh -s' < ops/fly-builder/provision-debian.sh
#
# WHY RE-RUNNABLE
#
# Only /data survives a machine restart; the root filesystem is ephemeral, so
# apt packages must be reinstalled every boot. The expensive parts -- the Rust
# toolchain and the crates.io registry -- live on /data and are installed once.
#
# MULTI-PROJECT LAYOUT
#
# This box is shared. More than one project builds on it at a time, so:
#
#   /data/cargo    CARGO_HOME. Shared on purpose: it holds the crates.io
#                  download cache, so two projects depending on the same crates
#                  pay that cost once. Cargo takes a lock on the registry while
#                  fetching, so concurrent builds may block briefly -- correct,
#                  just not instant. Compiled artifacts are NOT shared; they
#                  live in each project's own target/ under /data/builds.
#   /data/rustup   RUSTUP_HOME, so the toolchain survives a restart and every
#                  project compiles with the same rustc. A rustc bump must never
#                  be mistakable for a contract change (see ci.yml's pin).
#   /data/builds   One directory per project. cargo-remote names it after a hash
#                  of the project path, so projects cannot collide and do not
#                  need to agree on a name.
#   /data/ssh      sshd host key, authorized_keys, config.
#   /data/bin      ensure-ready, a single-word bootstrap entry point.
#
# CONCURRENCY
#
# [build] jobs below is a ceiling for one build. Run N builds in parallel and the
# box divides its cores between them, so set the per-build figure to roughly
# cores/N -- and raise it when the machine is the only thing running. Prefer
# CARGO_BUILD_JOBS in the cargo-remote remote's `env` over editing this file,
# since that is per project and this file is shared.
set -e

log() { echo "[provision] $*"; }

VOLUME=/data
# Where this provisioner and the scripts it installs live. Resolved from the script
# itself so the runbook's `ssh fly-builder 'sh -s' < provision-debian.sh` invocation
# works from any cwd.
SKILL_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ ! -f "$SKILL_DIR/builder-state.sh" ]; then
    # Piped over stdin (`sh -s`), so $0 is not the script path; fall back to the
    # conventional install location of the skill.
    SKILL_DIR=${SKILL_DIR_OVERRIDE:-$HOME/.agents/skills/shared-flyio-build-server}
fi
CARGO_HOME_DIR=$VOLUME/cargo
RUSTUP_HOME_DIR=$VOLUME/rustup
SSH_DIR=$VOLUME/ssh
SSHD_CONFIG=$SSH_DIR/sshd_config
SSHD_PORT=2222
TOOLCHAIN=1.95.0
BUILD_JOBS=${BUILD_JOBS:-4}

log "installing packages"
# libssl-dev is here because openssl-sys appears in real dependency trees (starla
# pulls it in through one of its storage features). Without the headers that
# crate's build script exits 101 with "Could not find directory of OpenSSL
# installation", which reads like a feature problem rather than a missing
# package.
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    build-essential cmake pkg-config \
    clang libclang-dev llvm-dev \
    git rsync curl ca-certificates \
    perl python3 \
    libzstd-dev liblz4-dev libsnappy-dev libssl-dev \
    openssh-server openssh-client \
    >/dev/null

# bindgen reaches libclang by dlopen. Its search list is Debian-shaped
# (libclang-N.so.1), which Alpine's libclang.so.17 naming defeats, so point it
# at the directory as well. This is belt and braces on Debian -- it is the
# fix that matters on musl -- but it costs nothing and it means one code path.
LIBCLANG_DIR=$(dirname "$(ls /usr/lib/llvm-*/lib/libclang.so.1 2>/dev/null | head -1)" 2>/dev/null)
[ -n "$LIBCLANG_DIR" ] || LIBCLANG_DIR=/usr/lib/llvm-14/lib

log "verifying the C toolchain and libclang"
command -v cc >/dev/null || { log "FATAL: no C compiler"; exit 1; }
ls "$LIBCLANG_DIR"/libclang.so.1 >/dev/null 2>&1 || { log "WARNING: libclang.so.1 not found under $LIBCLANG_DIR"; }

log "laying out $VOLUME"
mkdir -p "$CARGO_HOME_DIR" "$RUSTUP_HOME_DIR" "$VOLUME/builds" "$SSH_DIR" "$VOLUME/bin"
# cargo-remote sources ~/.cargo/env by default, so ~/.cargo has to resolve to
# the shared CARGO_HOME for every project on the box.
rm -rf /root/.cargo /root/.rustup
ln -s "$CARGO_HOME_DIR" /root/.cargo
ln -s "$RUSTUP_HOME_DIR" /root/.rustup

if [ ! -x "$RUSTUP_HOME_DIR/toolchains/${TOOLCHAIN}-x86_64-unknown-linux-gnu/bin/cargo" ]; then
    log "installing rust $TOOLCHAIN (first run only; the toolchain is on the volume)"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o /tmp/rustup-init.sh
    CARGO_HOME="$CARGO_HOME_DIR" RUSTUP_HOME="$RUSTUP_HOME_DIR" \
    sh /tmp/rustup-init.sh -y --default-toolchain "$TOOLCHAIN" \
        --profile minimal --no-modify-path
    CARGO_HOME="$CARGO_HOME_DIR" RUSTUP_HOME="$RUSTUP_HOME_DIR" \
    "$CARGO_HOME_DIR/bin/rustup" component add clippy
else
    log "rust $TOOLCHAIN already on the volume"
fi

# wasm32 is installed here, not left to each project, because it lives on the
# volume and therefore survives restarts while a project's own `rustup target
# add` does not. A project that checks or builds a browser target would
# otherwise work once and then fail after the next stop.
log "ensuring the wasm32-unknown-unknown target"
CARGO_HOME="$CARGO_HOME_DIR" RUSTUP_HOME="$RUSTUP_HOME_DIR" \
"$CARGO_HOME_DIR/bin/rustup" target list --installed | grep -qx wasm32-unknown-unknown \
    || CARGO_HOME="$CARGO_HOME_DIR" RUSTUP_HOME="$RUSTUP_HOME_DIR" \
    "$CARGO_HOME_DIR/bin/rustup" target add wasm32-unknown-unknown

# rustup writes $CARGO_HOME/env only when allowed to touch the shell profile,
# and this script installs with --no-modify-path. cargo-remote sources that file,
# so without it every remote build fails with "cargo: not found". Write it here
# rather than inherit whatever a previous image happened to leave.
log "writing \$CARGO_HOME/env"
cat > "$CARGO_HOME_DIR/env" <<'ENVFILE'
#!/bin/sh
# rustup shell setup, written by ops/fly-builder/provision-debian.sh.
case ":${PATH}:" in
    *:"$HOME/.cargo/bin":*)
        ;;
    *)
        export PATH="$HOME/.cargo/bin:$PATH"
        ;;
esac
ENVFILE

log "writing cargo config (jobs=$BUILD_JOBS)"
# Written unconditionally, not only when absent: an earlier version guarded this
# with [ ! -f ], so a later edit silently did nothing on any box that already had
# one. That is exactly the failure this comment exists to prevent.
cat > "$CARGO_HOME_DIR/config.toml" <<CFG
# Shared by every project that builds on this machine. Per-project overrides
# belong in the cargo-remote remote's \`env\` field, not here.
[build]
# One build's ceiling. With N builds in parallel, set this to about cores/N.
jobs = $BUILD_JOBS

[env]
LIBCLANG_PATH = "$LIBCLANG_DIR"

[profile.dev]
# Debuginfo is most of a debug build's bulk -- locally \`target/debug\` is 32G,
# of which the surrealdb-ds-server binary alone is 1.8G. Nothing is debugged on
# the build server, so drop it and the whole tree fits comfortably.
debug = 0
incremental = false

[profile.test]
debug = 0
incremental = false
CFG

log "configuring sshd on port $SSHD_PORT"
# Our own sshd, not the platform's on 22. The platform's server argv-splits the
# command instead of running it through a login shell, and cargo-remote needs a
# shell twice: rsync's --rsync-path is "mkdir -p DIR && rsync", and its build
# script is "cd DIR; . env; cargo ...".
[ -f "$SSH_DIR/ssh_host_ed25519_key" ] || \
    ssh-keygen -q -t ed25519 -N '' -f "$SSH_DIR/ssh_host_ed25519_key"
cat > "$SSHD_CONFIG" <<CFG
# Generated by ops/fly-builder/provision-debian.sh. Local edits will be lost.
Port $SSHD_PORT
HostKey $SSH_DIR/ssh_host_ed25519_key
PermitRootLogin yes
PubkeyAuthentication yes
AuthorizedKeysFile $SSH_DIR/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PidFile $SSH_DIR/sshd.pid
LogLevel VERBOSE
Subsystem sftp /usr/lib/openssh/sftp-server
CFG
chmod 700 "$SSH_DIR"
[ -f "$SSH_DIR/authorized_keys" ] && chmod 600 "$SSH_DIR/authorized_keys"

if [ -f "$SSH_DIR/sshd.pid" ] && kill -0 "$(cat "$SSH_DIR/sshd.pid")" 2>/dev/null; then
    log "sshd already running"
else
    log "starting sshd"
    mkdir -p /run/sshd
    /usr/sbin/sshd -f "$SSHD_CONFIG"
    sleep 1
fi

log "writing $VOLUME/bin/ensure-ready"
# The ensure-ready body below is the live one; keep the two in step. It is the
# only thing that runs after a restart, so anything it omits is broken until
# someone notices -- which is how the ~/.cargo symlink went missing for a while.
cat > "$VOLUME/bin/ensure-ready.tmp" <<'ENSURE'
#!/bin/sh
# Single-word bootstrap, reachable as:
#   flyctl machine exec -a <app> --no-container <id> /data/bin/ensure-ready
#
# It has to be one executable because `flyctl machine exec` argv-splits instead
# of using a shell, so it cannot take a script as its argument.
set -e
# `flyctl machine exec` runs this with no login shell and a minimal environment:
# HOME is `/` rather than unset, and rustup's env file expands it, so PATH ends
# up holding `/.cargo/bin` instead of `/root/.cargo/bin`. Every rustup call then
# failed with "rustup: not found" (exit 127) even though apt and sshd had already
# succeeded. Set both explicitly rather than trusting the caller's environment.
HOME=/root
PATH=/data/cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# The volume mount. This body is written out through a QUOTED heredoc, so the
# provisioner's own $VOLUME does not expand into it; every use below was
# therefore testing /bin/builder-state and silently skipping the copy. Leaving it
# undefined made the tool-restore block dead code, which is why a restarted box
# came up without builder-* in /usr/local/bin and had to be repaired from the
# host instead.
VOLUME=${VOLUME:-/data}
export HOME PATH VOLUME
DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    build-essential cmake pkg-config clang libclang-dev llvm-dev \
    git rsync curl ca-certificates perl python3 \
    libzstd-dev liblz4-dev libsnappy-dev libssl-dev \
    openssh-server openssh-client >/dev/null
mkdir -p /run/sshd
# `|| true` is not laziness. This body is re-run on purpose (the host re-runs it
# whenever the completion marker at the end is missing), and on a re-run sshd is
# already listening and exits non-zero -- which under `set -e` would abort the
# whole repair *before* the project users are restored, i.e. before the one thing
# a re-run exists to do. A genuinely broken sshd config is not silent: it lands in
# the bootstrap log above, and the host refuses to report the box ready without
# the marker.
/usr/sbin/sshd -f /data/ssh/sshd_config || true
sleep 1

# Keep a record of what this run did. The host used to fire this with its output
# sent to /dev/null, and that is why a bootstrap which dies halfway was invisible:
# sshd already answers (it is started above, ~line 31 of this file), so every host
# check says the box is healthy while nothing past this point has run. A build
# failure hours later was the first symptom, and by then the evidence was gone
# because the root filesystem is ephemeral. /data survives, so log there, and trim
# so a long-lived volume cannot grow it without bound.
mkdir -p "$VOLUME/state"
# Serialize concurrent runs. A boot run and a host-triggered re-run can overlap, and
# two `apt-get install` invocations contend for the dpkg lock -- one of them fails,
# and under `set -e` that is a failed repair. Holding a lock for the life of the run
# makes the second one wait and then repeat an already-idempotent repair. Guarded so
# a box without flock still bootstraps instead of aborting at this line.
if command -v flock >/dev/null 2>&1; then
    exec 8>>"$VOLUME/state/bootstrap.lock"
    flock -x 8
fi
if [ -f "$VOLUME/state/bootstrap.log" ] && [ "$(wc -c <"$VOLUME/state/bootstrap.log")" -gt 200000 ]; then
    tail -c 100000 "$VOLUME/state/bootstrap.log" >"$VOLUME/state/bootstrap.log.tmp"
    mv "$VOLUME/state/bootstrap.log.tmp" "$VOLUME/state/bootstrap.log"
fi
printf '=== bootstrap %s boot_id=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(cat /proc/sys/kernel/random/boot_id)" \
    >>"$VOLUME/state/bootstrap.log"
exec >>"$VOLUME/state/bootstrap.log" 2>&1

# Only /data survives a stop. /root/.cargo and /root/.rustup are symlinks that
# live on the ephemeral root filesystem, so they are gone after every restart
# even though the toolchain they point at is still on the volume. cargo-remote
# sources ~/.cargo/env, so with the links missing every build fails with
# "cargo: command not found" -- which reads like a broken box rather than a
# missing symlink. Restoring the links is the entire repair; apt above is the
# slow part.
if [ "$(readlink /root/.cargo)" != /data/cargo ]; then
    rm -rf /root/.cargo
    ln -sfn /data/cargo /root/.cargo
fi
if [ "$(readlink /root/.rustup)" != /data/rustup ]; then
    rm -rf /root/.rustup
    ln -sfn /data/rustup /root/.rustup
fi

# Skipped on a fresh volume, where no toolchain exists yet and
# provision-debian.sh installs one.
if [ -x /data/cargo/bin/rustup ]; then
    CARGO_HOME=/data/cargo
    RUSTUP_HOME=/data/rustup
    export CARGO_HOME RUSTUP_HOME
    . /root/.cargo/env
    # Pin the default so a `cargo remote-3000` invoked without -d cannot float
    # the compiler by installing and switching to stable.
    rustup default 1.95.0 >/dev/null
    # Browser targets: starla and other projects check --target wasm32.
    rustup target list --installed | grep -qx wasm32-unknown-unknown \
        || rustup target add wasm32-unknown-unknown
    cargo --version
    rustc --version
    rustup target list --installed
fi

# /data/bin is NOT on a non-login ssh shell's PATH, and the root filesystem is
# ephemeral, so anything that must be found by `command -v` has to be copied to
# /usr/local/bin on every boot. builder-state and builder-idle are load-bearing
# and were missing here at some point, which is what made a restart silently
# downgrade the box: builds ran unleased (so a stop could kill them) and nothing
# enforced scale-to-zero. builder-project was missing from this list too, so the
# one tool that can recreate a project user was unreachable exactly when a reboot
# had deleted them all.
for tool in builder-state builder-idle builder-project; do
    if [ -x "$VOLUME/bin/$tool" ]; then
        cp "$VOLUME/bin/$tool" /usr/local/bin/$tool
        chmod 755 /usr/local/bin/$tool
    fi
done

# /etc/passwd is ephemeral for the same reason /usr/local/bin is, so a restart
# deletes every project user while /data/projects/<slug> survives on the volume.
# Without its user a project still has files but no identity: remote-cargo.sh
# probes `id <slug>`, the probe fails, and the build falls back to the
# vintage-keyed seed root -- which nothing has ever created -- so the first rsync
# dies with "mkdir ...: No such file or directory" and every build on the box
# fails. One boot was enough to do this. Re-ensure each surviving project home;
# builder-project ensure is idempotent and reuses the owner uid, so the file
# tree is not re-chowned on every restart.
for home in "$VOLUME"/projects/*/; do
    [ -d "$home" ] || continue
    [ -f "$home/.builder-project" ] || continue
    slug=$(basename "$home")
    # Deliberately fatal, not a warning. A project whose user cannot be restored
    # has no working build path at all: remote-cargo.sh's `id` probe fails and
    # every rsync dies against a seed root nothing creates. Swallowing that as a
    # warning lets the host print `box ready` over a box that cannot build, which
    # is exactly what happened on 2026-11-02 and cost a full gate sweep to find.
    # `set -e` aborts here, before the completion marker is written, so the host
    # reports the failure instead of inheriting it.
    "$VOLUME/bin/builder-project" ensure "$slug"
done

# NOTE: the box deliberately does NOT run its own stop loop. It has no Fly
# credentials -- it was created with `machine run` on /bin/sleep, so PID 1 carries no
# FLY_* environment and there is no machine token on the volume -- and planting an API
# token here would put a standing credential on a shared box that any build can read.
# builder-idle therefore only ANSWERS "is anyone using me"; the host enforces the stop
# via scripts/build-server-supervise.sh on a systemd timer. Decision data comes from
# where the work is; authority comes from where the credentials are.

# The completion marker is what makes "ready" mean ready. The host compares this
# against /proc/sys/kernel/random/boot_id, so a marker left by a previous boot is
# not mistaken for this one's, and it does not infer completion from "ssh answers"
# -- which is only true from ~line 31 of this file onward. Everything above has
# succeeded when this exists.
printf '%s\n' "$(cat /proc/sys/kernel/random/boot_id)" >"$VOLUME/state/bootstrap-complete.tmp"
mv -f "$VOLUME/state/bootstrap-complete.tmp" "$VOLUME/state/bootstrap-complete"
echo READY
ENSURE
# Write then rename. A body written in place can be read by a run that started
# before the write, and this file is executed directly.
chmod 755 "$VOLUME/bin/ensure-ready.tmp"
mv -f "$VOLUME/bin/ensure-ready.tmp" "$VOLUME/bin/ensure-ready"

# The admission-control and idle-watchdog scripts live in this skill directory and
# are installed onto the volume, not written inline: they are long enough that
# keeping a second copy in this file would drift.
for script in builder-state.sh builder-idle.sh builder-project.sh; do
    if [ -f "$SKILL_DIR/$script" ]; then
        install -m 755 "$SKILL_DIR/$script" "$VOLUME/bin/${script%.sh}"
        log "installed $VOLUME/bin/${script%.sh}"
    else
        log "WARNING: $SKILL_DIR/$script missing; the box will run without it"
    fi
done

# Pin the default toolchain explicitly: without it the rustup shim resolves
# whatever was last set, which is how a stray `stable` install became the default
# and silently floated the compiler away from the version CI verifies.
CARGO_HOME="$CARGO_HOME_DIR" RUSTUP_HOME="$RUSTUP_HOME_DIR" \
    "$CARGO_HOME_DIR/bin/rustup" default "$TOOLCHAIN" >/dev/null

log "versions"
CARGO_HOME="$CARGO_HOME_DIR" RUSTUP_HOME="$RUSTUP_HOME_DIR" \
    "$CARGO_HOME_DIR/bin/cargo" --version
CARGO_HOME="$CARGO_HOME_DIR" RUSTUP_HOME="$RUSTUP_HOME_DIR" \
    "$CARGO_HOME_DIR/bin/rustc" --version
log "volume"
df -h "$VOLUME" | tail -1
log "PROVISION_OK"