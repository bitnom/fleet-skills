#!/bin/sh
# Provision the Fly build server for open-surrealdb-ds.
#
# WHY THIS EXISTS, AND WHY IT MUST BE RE-RUNNABLE
#
# The machine's root filesystem is ephemeral. `apk add` writes to /, so every
# `fly machine start` after a stop brings a machine with no compiler, no rsync
# and no sshd. Only the 50 GB volume at /data survives. That split is the whole
# reason this script is idempotent and separate from the image: rustup and
# CARGO_HOME live on /data and are installed once, while apk packages are
# reinstalled every boot and take about a minute.
#
# The durable fix is to bake an image with all of this in it. See
# docs/remote-builds.md, "Next step".
#
# Run it over ssh:
#     ssh fly-builder 'sh -s' < ops/fly-builder/provision.sh
set -e

log() { echo "[provision] $*"; }

VOLUME=/data
CARGO_HOME_DIR=$VOLUME/cargo
RUSTUP_HOME_DIR=$VOLUME/rustup
SSH_DIR=$VOLUME/ssh
SSHD_CONFIG=$SSH_DIR/sshd_config
SSHD_PORT=2222

log "installing packages"
# Named explicitly, and including the openssh-client-* trio together: the rchab
# image ships them one patch level behind the repository, and asking apk for
# only openssh-server makes it try to reconcile a single package and fail with
# a "breaks" conflict. Naming all four lets it upgrade them as a set.
apk add --no-cache \
    bash rsync git curl ca-certificates \
    build-base cmake pkgconf \
    clang-dev llvm-dev \
    perl python3 \
    zstd-dev lz4-dev snappy-dev \
    libgcc \
    openssh-client-default openssh-client-common openssh-server openssh-sftp-server \
    >/dev/null

# rustc and cargo link against libgcc_s.so.1 for unwinding. Alpine does not
# install it by default, and without it every cargo invocation dies with
# "symbol not found: _Unwind_Resume" rather than anything that names the cause.
log "verifying libgcc"
ldconfig 2>/dev/null || true
[ -e /usr/lib/libgcc_s.so.1 ] || [ -e /lib/ld-musl-x86_64.so.1 ] || {
    log "WARNING: libgcc_s.so.1 not found; cargo may fail to run"
}

log "laying out the volume"
mkdir -p "$CARGO_HOME_DIR" "$RUSTUP_HOME_DIR" "$VOLUME/builds" "$SSH_DIR"
# ~/.cargo must resolve to the volume because cargo-remote sources ~/.cargo/env
# by default, and that file has to exist for the remote build script to find it.
rm -rf /root/.cargo /root/.rustup
ln -s "$CARGO_HOME_DIR" /root/.cargo
ln -s "$RUSTUP_HOME_DIR" /root/.rustup

TOOLCHAIN=1.95.0
if [ ! -x "$RUSTUP_HOME_DIR/toolchains/${TOOLCHAIN}-x86_64-unknown-linux-musl/bin/cargo" ]; then
    log "installing rust $TOOLCHAIN (first run only; this is on the volume)"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o /tmp/rustup-init.sh
    CARGO_HOME="$CARGO_HOME_DIR" RUSTUP_HOME="$RUSTUP_HOME_DIR" \
        sh /tmp/rustup-init.sh -y --default-toolchain "$TOOLCHAIN" \
        --profile minimal --no-modify-path
    CARGO_HOME="$CARGO_HOME_DIR" RUSTUP_HOME="$RUSTUP_HOME_DIR" \
        "$CARGO_HOME_DIR/bin/rustup" component add clippy
else
    log "rust $TOOLCHAIN already on the volume"
fi

log "writing cargo config"
# Written unconditionally, not only when absent. An earlier version guarded this
# with [ ! -f ], which meant a later edit to this script silently did nothing on
# any machine that already had a config -- exactly the failure this comment
# exists to prevent.
cat > "$CARGO_HOME_DIR/config.toml" <<'CFG'
# Remote build tuning for the Fly builder: shared-cpu-8x, 8 GB RAM, ~39 GB free.
#
# A debug build of SurrealDB is ~32 GB locally with full debuginfo, which does
# not fit this volume. Two changes make it fit:
#   debug = 0          debuginfo is most of a debug build's bulk, and nothing is
#                      debugged on the build server.
#   incremental = false  drops the incremental cache, which nothing reuses across
#                      our few distinct invocations.
# jobs is capped because eight concurrent rustc processes over SurrealDB's crate
# graph exhausts 8 GB of RAM. Raise it if the machine is ever resized.
[build]
jobs = 3

# bindgen reaches libclang by dlopen. Alpine names it libclang.so.17, while
# clang-sys probes the Debian/Ubuntu names (libclang-17.so.1) first and does not
# reliably fall back to the bare soname, so librocksdb-sys's build script panics
# with "Unable to find libclang" even though libclang.so is installed and
# loadable. Pointing it at the directory is the documented workaround.
[env]
LIBCLANG_PATH = "/usr/lib"

[profile.dev]
debug = 0
incremental = false

[profile.test]
debug = 0
incremental = false
CFG

# Our own sshd, on a port other than 22, because Fly's Hallpass owns 22 and does
# not interpret shell metacharacters -- cargo-remote needs a login shell for both
# rsync's --rsync-path and its build script. See docs/remote-builds.md.
# cargo-remote builds its remote script as
#   [ -f ~/.cargo/env ] && . ~/.cargo/env; rustup default <toolchain>; cd DIR; cargo ...
# so $CARGO_HOME/env must exist or every cargo invocation is "not found". rustup
# writes that file only when it is allowed to modify the shell profile, and this
# script installs with --no-modify-path, so we write it ourselves. This is
# rustup's own env file, reproduced rather than guessed.
cat > "$CARGO_HOME_DIR/env" <<'ENVFILE'
#!/bin/sh
# rustup shell setup, written by ops/fly-builder/provision.sh.
case ":${PATH}:" in
    *:"$HOME/.cargo/bin":*)
        ;;
    *)
        export PATH="$HOME/.cargo/bin:$PATH"
        ;;
esac
ENVFILE

log "configuring sshd on port $SSHD_PORT"
[ -f "$SSH_DIR/ssh_host_ed25519_key" ] || \
    ssh-keygen -q -t ed25519 -N '' -f "$SSH_DIR/ssh_host_ed25519_key"
cat > "$SSHD_CONFIG" <<CFG
# Generated by ops/fly-builder/provision.sh. Local edits will be overwritten.
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
Subsystem sftp /usr/lib/ssh/sftp-server
CFG
chmod 700 "$SSH_DIR"
chmod 600 "$SSH_DIR/authorized_keys" 2>/dev/null || true

if [ -f "$SSH_DIR/sshd.pid" ] && kill -0 "$(cat "$SSH_DIR/sshd.pid")" 2>/dev/null; then
    log "sshd already running"
else
    log "starting sshd"
    /usr/sbin/sshd -f "$SSHD_CONFIG"
    sleep 1
fi

# Pin the default toolchain explicitly. Without this the rustup shim resolves
# whatever was last set, which is how a stray `stable` install became the
# default and silently floated the compiler away from the version CI verifies.
CARGO_HOME="$CARGO_HOME_DIR" RUSTUP_HOME="$RUSTUP_HOME_DIR" \
    "$CARGO_HOME_DIR/bin/rustup" default "$TOOLCHAIN" >/dev/null

log "versions"
CARGO_HOME="$CARGO_HOME_DIR" RUSTUP_HOME="$RUSTUP_HOME_DIR" \
    "$CARGO_HOME_DIR/bin/cargo" --version
"$CARGO_HOME_DIR/bin/rustc" --version
log "PROVISION_OK"