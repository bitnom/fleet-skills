#!/bin/sh
# Admission control for the shared Fly build server.
#
# WHY THIS EXISTS
#
# The box is shared by several projects and several agents at once, and that is
# by design: cargo-remote keys one target/ tree per project path, so two projects
# never collide, and the per-build `jobs = 4` ceiling on 8 cores divides the
# machine instead of oversubscribing it. Concurrency was never the problem.
#
# The problem is that the only way to stop billing is `flyctl machine stop`,
# which is an outside-the-box operation: it has no idea who is building. A
# `pgrep cargo` check before stopping does not close the hole, because the window
# between the check and the stop is exactly when a sibling agent starts its next
# command. That is not hypothetical -- it happened, and killed a `cargo test`
# belonging to another project's lane mid-run.
#
# So builds take a lease on the box itself and a stop is refused while any lease
# is live. Registration and the decision read the same lock, so a `park` either
# runs before a build registers or sees it.
#
# THE LOCK
#
# /data/state/lease.lock is held SHARED by every in-flight build and EXCLUSIVELY
# by `park`. Shared holders do not block each other, which is what makes N
# parallel builds work; an exclusive acquire succeeds only when no shared holder
# remains, which is what makes a park safe. A single exclusive lock per build
# would not do: the second build could not take it, would run unlocked, and
# would be invisible to park the moment the first one finished.
#
# Leases are also recorded one file per build under /data/state/leases/, so
# `status` and a refused `park` can name who to talk to. Those files are
# descriptive only; the lock is the authority, and a killed build leaves a stale
# file that status prunes by checking the recorded pid.
#
# INSTALLED AS: /usr/local/bin/builder-state, with /data/bin/builder-state as the
# on-volume copy that survives a stop (see provision-debian.sh). /usr/local/bin
# is the path, not /data/bin, because the root filesystem is ephemeral: /data/bin
# is not on a non-login ssh shell's PATH, so `command -v builder-state` fails
# there and every build would warn that it holds no lease.
#
# CONTRACT
#
#   builder-state lease <name> -- <command...>   run command holding a lease
#   builder-state status [--json]                live leases, idle seconds
#   builder-state park [--force] [--wait=<secs>] refuse to park while leased
#
# `lease` exits with the command's own status.
#
# --force exists for a wedged box and writes an audit line naming the leases it
# ignored. It is not a routine flag.

set -u

STATE_DIR=${BUILDER_STATE_DIR:-/data/state}
LOCK_FILE="$STATE_DIR/lease.lock"
LEASE_DIR="$STATE_DIR/leases"
IDLE_FILE="$STATE_DIR/idle-since"
LOG_FILE="$STATE_DIR/events.log"

mkdir -p "$LEASE_DIR"

now() { date -u +%s; }

audit() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG_FILE"; }

# A non-blocking shared acquire always succeeds, including while other builds
# hold shared locks, so this measures "can a build register" and never blocks.
can_take_shared() { ( flock -n -s 9 ) 9>>"$LOCK_FILE"; }

# Succeeds only when no build holds a shared lock, i.e. it is safe to stop.
can_take_exclusive() { ( flock -n -x 9 ) 9>>"$LOCK_FILE"; }

# Drop records whose process is gone. A stopped machine kills builds, and those
# builds cannot remove their own files.
prune_leases() {
    for f in "$LEASE_DIR"/*; do
        [ -e "$f" ] || continue
        pid=$(sed -n 's/^pid=\([0-9]*\).*/\1/p' "$f" 2>/dev/null | head -1)
        if [ -z "$pid" ] || [ ! -d "/proc/$pid" ]; then
            rm -f "$f"
        fi
    done
}

list_leases() {
    prune_leases
    for f in "$LEASE_DIR"/*; do
        [ -e "$f" ] || continue
        cat "$f"
        echo
    done
}

lease_count() {
    # `grep -c` already prints 0 when nothing matches and still exits 1; letting
    # that 1 escape would append a second 0 to the count.
    n=$(list_leases | grep -c '^name=' 2>/dev/null)
    printf '%s' "${n:-0}"
}

json_escape() { sed 's/\\/\\\\/g; s/"/\\"/g'; }

cmd_status() {
    if [ "${1:-}" = "--json" ]; then
        if can_take_exclusive; then leased=false; else leased=true; fi
        idle_since=$(cat "$IDLE_FILE" 2>/dev/null || echo "")
        if [ "$idle_since" = "" ]; then idle_for=-1; else idle_for=$(( $(now) - idle_since )); fi
        # One JSON object per lease, built from its key=value record.
        body=$(list_leases | awk '
            function flush() { if (n++) printf ","; printf "{%s}", buf; buf = "" }
            /^$/ { flush(); next }
            {
                i = index($0, "=")
                if (!i) next
                k = substr($0, 1, i - 1); v = substr($0, i + 1)
                gsub(/\\/, "\\\\", v); gsub(/"/, "\\\"", v)
                if (buf != "") buf = buf ","
                buf = buf "\"" k "\":\"" v "\""
            }
            END { if (buf != "") flush() }')
        printf '{"leased":%s,"idleSeconds":%s,"leaseCount":%s,"leases":[%s]}\n' \
            "$leased" "$idle_for" "$(lease_count)" "$body"
        return 0
    fi

    if can_take_exclusive; then
        echo "leased: no"
    else
        echo "leased: yes"
    fi
    idle_since=$(cat "$IDLE_FILE" 2>/dev/null || echo "")
    if [ "$idle_since" = "" ]; then
        echo "idle-seconds: -1"
    else
        echo "idle-seconds: $(( $(now) - idle_since ))"
    fi
    echo "--- live leases ---"
    out=$(list_leases)
    if [ -n "$out" ]; then printf '%s\n' "$out"; else echo "(none recorded)"; fi
}

cmd_lease() {
    name=${1:?lease needs a name}
    shift
    [ "${1:-}" = "--" ] && shift
    [ $# -gt 0 ] || { echo "lease $name: no command given" >&2; exit 2; }

    if ! can_take_shared; then
        # Only possible if a park is mid-flight holding the exclusive lock. Wait
        # rather than starting a build that a concurrent stop could kill.
        echo "lease $name: a park is in progress, waiting for it to finish" >&2
        exec 9>>"$LOCK_FILE"
        flock -s 9
    fi

    record="$LEASE_DIR/$$-$name"
    {
        printf 'name=%s\n' "$name"
        printf 'pid=%s\n' "$$"
        printf 'host=%s\n' "$(hostname)"
        printf 'cwd=%s\n' "$(pwd)"
        printf 'started=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        [ -n "${STARLA_REMOTE_PROJECT:-}" ] && printf 'project=%s\n' "$STARLA_REMOTE_PROJECT"
    } >"$record"
    audit "lease-start name=$name pid=$$"

    # Take the shared lock for the command's lifetime. `exec 9>>` plus a blocking
    # `flock -s` in this shell keeps the lock held by the fd the shell owns, so it
    # is released by process exit even if the command crashes.
    exec 9>>"$LOCK_FILE"
    flock -s 9

    rm -f "$IDLE_FILE"
    # `9>&-` closes the lock fd in the CHILD. Without it the command inherits the
    # descriptor, so the shared lock outlives the process that recorded the lease:
    # measured 2026-11-02, a killed `builder-state lease` left its `sleep` child
    # holding /data/state/lease.lock while the record had already been pruned, and
    # `status` then reported `leased: yes` with no lease to name. An unattributable
    # lock is worse than no lock -- it blocks every stop and explains nothing.
    "$@" 9>&-
    rc=$?

    audit "lease-end name=$name pid=$$ rc=$rc"
    rm -f "$record"
    record_idle
    exit "$rc"
}

record_idle() { now >"$IDLE_FILE"; }

cmd_park() {
    wait_s=${BUILDER_PARK_WAIT:-0}
    force=0
    for arg in "$@"; do
        case "$arg" in
            --force) force=1 ;;
            --wait=*) wait_s=${arg#--wait=} ;;
            *) echo "park: unknown option $arg" >&2; exit 2 ;;
        esac
    done

    deadline=$(( $(now) + wait_s ))
    while ! can_take_exclusive; do
        if [ "$force" = 1 ]; then
            audit "park-FORCED by=${USER:-unknown} leases=$(list_leases | tr '\n' ' ')"
            echo "park: forced past live leases" >&2
            break
        fi
        if [ "$(now)" -ge "$deadline" ]; then
            echo "park: REFUSED -- builds are in flight:" >&2
            list_leases >&2
            echo "park: retry with --wait=<secs>, or check 'builder-state status'" >&2
            exit 1
        fi
        sleep 5
    done

    audit "park-ok by=${USER:-unknown}"
    record_idle
    echo "park: no builds in flight"
}

case "${1:-}" in
    lease) shift; cmd_lease "$@" ;;
    status) shift; cmd_status "$@" ;;
    park) shift; cmd_park "$@" ;;
    *)
        echo "usage: builder-state lease <name> -- <command...> | status [--json] | park [--force] [--wait=<secs>]" >&2
        exit 2
        ;;
esac
