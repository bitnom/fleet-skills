#!/bin/sh
# Scale the shared build server to zero when nothing is using it.
#
# WHY THIS EXISTS, AND WHY IT IS NOT `uptime`
#
# The box bills per second while started, and the observed leak was not one long
# forgotten build -- it was that any lane starts the machine on demand and nobody
# stops it. Twenty-one recorded start invocations across sessions, with stop paths
# that depend on someone remembering. That is the thing to fix, and it has to be a
# policy the box enforces about itself rather than a script in a runbook.
#
# Load average cannot be the signal. A futex-blocked test binary -- five threads,
# zero CPU, zero sockets, waiting on a channel -- contributes the same load average
# as an idle box, and an operator stop based on `load ~ 0.00` killed a box that five
# dxdb lanes were actively using. So "idle" here is defined as the ABSENCE of work,
# measured three ways, and any single one is enough to keep the box up:
#
#   1. A builder-state lease exists.     Leases are the admission-control truth:
#                                        a running build holds one, so a leased box
#                                        is never idle regardless of CPU.
#   2. Any cargo/rustc/wasm-pack runs.   Catches builds that did not take a lease
#                                        (another project's Makefile, a hand-run
#                                        ssh command, a lane that predates the lease
#                                        protocol). Zombies never count.
#   3. CPU time advanced since the last sample.
#                                        Catches everything else -- a test binary
#                                        doing real work without a cargo process
#                                        above it. Compares cumulative
#                                        user+system jiffies, so it measures WORK
#                                        DONE, never instantaneous load.
#   4. A file under the build roots changed recently.
#                                        Catches a build BETWEEN processes -- sync,
#                                        fetch, unpack -- where nothing is running
#                                        and CPU is quiet, which is the window an
#                                        unleased project is most exposed to.
#
# Idleness must persist for IDLE_GRACE seconds before the box stops itself, so a
# brief gap between two chained builds (rsync, then compile) does not trigger a stop
# mid-tranche. The box cannot enforce that itself (no Fly credential -- see below),
# so `--status` carries the counter instead: each poll advances it while the answer
# stays `idle` and any other answer resets it, and the host stops only once it has
# reached the grace. Every sample and every decision is written to
# /data/state/idle.log so a stop can always be explained after the fact.
#
# HOW IT STOPS: the machine's own Fly metadata is the authority, not a local script.
# It starts `flyctl`-free -- the box calls the Fly machines API through its own
# machine token, which is why this needs no flyctl on the box and no operator
# credentials.
#
# USAGE
#   builder-idle            run the watchdog in the foreground (mostly for testing)
#   builder-idle --once     take one sample, report, and exit (no stop)
#   builder-idle --status    print the current verdict as JSON
#
# ENV: IDLE_GRACE (seconds of confirmed idleness before stopping, default 900),
#      IDLE_INTERVAL (sample period, default 60), BUILDER_STATE_DIR,
#      BUILD_IDLE_DISABLE=1 (keep the box up; logs why it would have stopped).

set -u

STATE_DIR=${BUILDER_STATE_DIR:-/data/state}
LOG=$STATE_DIR/idle.log
CPU_SAMPLE=$STATE_DIR/cpu-sample
IDLE_SINCE_FILE=$STATE_DIR/idle-since
PENDING_FILE=$STATE_DIR/idle-pending-since
GRACE=${IDLE_GRACE:-900}
INTERVAL=${IDLE_INTERVAL:-60}
# Threshold as a percentage of one core: 10 means "less than 10% busy is idle".
# 2 was never measurable over ssh: the sampler itself (ssh handshake, login shell,
# the churn scan) costs a few CPU-seconds per poll, which is a real share of 2% of
# a core across a five-minute window, while a build is hundreds of CPU-seconds in
# that window. 10% keeps a wide margin on both sides.
IDLE_CPU_RATE_HUNDREDTHS=${IDLE_CPU_RATE_HUNDREDTHS:-10}
# How long a lease is trusted on its own word with no compile under it. Covers the
# gap between taking the lease and cargo starting (a couple of seconds), and nothing
# longer: a lease is a promise a CLIENT makes, so a killed client leaves the promise
# standing forever -- the holder is a `while read` under sshd whose client is gone,
# which never sees EOF and never releases. Measured 2026-11-01: one killed wrapper
# left the box `leased` permanently, `park` refused, and this script's `leased`
# verdict told the host never to stop, so a machine nobody was using billed all
# night. Past this grace with no cargo and no churn the lease is stale and must not
# gate the stop; the box stopping is itself what clears it.
LEASE_START_GRACE=${LEASE_START_GRACE:-180}
# A live process set that stops making progress is a WEDGE, not a build.
#
# Measured on this box by the dxdb lanes: an orphaned box-side `cargo` parked in
# `do_wait` on a deadlocked test-binary child, 0.00 load, no churn, for 20-38
# minutes, with seven lanes queued behind it and nothing able to progress. `procs`
# alone cannot see that -- it reports `building` for as long as the process lives --
# so this uses the two signals a wedge cannot produce: work (cumulative CPU) and
# churn. The window is much longer than IDLE_GRACE on purpose: from inside the box a
# legitimately sleeping test is indistinguishable from a deadlock, so only a long,
# unbroken absence of both counts, and a build whose client is still attached (see
# lease_watched) is never stopped by this rule at all. Killing the child is what
# releases such a tree -- not any lock -- so nothing here tries to tidy up a build.
WEDGE_GRACE=${WEDGE_GRACE:-1200}
WEDGE_FILE=$STATE_DIR/wedge-since

mkdir -p "$STATE_DIR"

now() { date -u +%s; }
# When this boot began. Idleness cannot predate it, and a marker left over from a
# previous boot must not be inherited -- that is the one way the idle counter could
# ever stop a box too early.
boot_time() {
    up=$(awk '{ print int($1) }' /proc/uptime 2>/dev/null || echo 0)
    printf '%s\n' "$(( $(now) - up ))"
}
iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '%s %s\n' "$(iso)" "$*" >>"$LOG"; }

# Cumulative CPU WORK across every core: user+nice+system+irq+softirq+steal.
# Fields 5 and 6 (idle, iowait) are deliberately excluded.
#
# This used to sum the whole line, which counts wall time, not work: on an N-core
# box the total advances at N*100 jiffies per second whether or not anything runs,
# so `rate_hundredths` was N*100 (400 on this 4-core machine) and always above the
# threshold. `cpu-active` was therefore the permanent answer, and the few `idle`
# verdicts ever produced were artifacts of a sample left by a previous boot, where
# the delta went negative and was clamped to zero -- the check read a *busy* box as
# idle. Measured on this box 2026-11-01: 801 jiffies in 2s, almost all of it idle.
# The whole design leans on this signal (load average cannot see a futex-blocked
# test binary), so it has to measure work.
cpu_jiffies() {
    awk '/^cpu /{ print $2+$3+$4+$7+$8+$9; exit }' /proc/stat 2>/dev/null || echo 0
}

# CPU-seconds burned per wall-second, in hundredths of one core, or empty when there
# is no usable baseline (first sample, no elapsed time, or a sample from a previous
# boot). Every call UPDATES the stored baseline, so verdict() calls this EXACTLY
# ONCE per poll and reuses the answer for both decisions. It is taken before the
# process check because the wedge rule needs a rate while processes are alive; a
# second sample for the idle decision would then compare against the baseline this
# same poll had just written, which is elapsed 0, no rate, and a `warmup` answer on
# every poll forever. Measured on this host: no cargo, no churn, 1% of a core,
# and the answer was `warmup` for ten seconds straight while the committed version
# answered `idle` on the same seeds. A negative delta is not clamped to zero -- that
# reads a freshly booted box as idle, which is the wrong direction for a stop.
cpu_rate_hundredths() {
    prev_line=$(cat "$CPU_SAMPLE" 2>/dev/null || echo "")
    cur=$(cpu_jiffies)
    cur_ts=$(now)
    if [ -z "$prev_line" ]; then
        printf '%s %s\n' "$cur" "$cur_ts" >"$CPU_SAMPLE"
        return 0
    fi
    prev=$(printf '%s' "$prev_line" | awk '{print $1}')
    prev_ts=$(printf '%s' "$prev_line" | awk '{print $2}')
    # A baseline with no timestamp is not a baseline, and a box patched on top of an
    # older one has exactly that file: earlier versions seeded cpu-sample with the
    # jiffy count alone. Arithmetic on the missing field treats it as 0, so elapsed
    # becomes the whole epoch (~1.7e9) and a 54-jiffy delta divides down to a rate of
    # 0 -- which is `idle`, claimed from no evidence at all. Rewrite it properly and
    # answer `warmup`, the fail-closed direction.
    if [ -z "$prev" ] || [ -z "$prev_ts" ]; then
        printf '%s %s\n' "$cur" "$cur_ts" >"$CPU_SAMPLE"
        return 0
    fi
    printf '%s %s\n' "$cur" "$cur_ts" >"$CPU_SAMPLE"
    elapsed=$(( cur_ts - prev_ts ))
    [ "$elapsed" -gt 0 ] || return 0
    delta=$(( cur - prev ))
    [ "$delta" -ge 0 ] || return 0
    # Jiffies are USER_HZ (100/s) on Linux, so delta/elapsed is hundredths of a core.
    printf '%s\n' "$(( delta / elapsed ))"
}

build_processes() {
    # -x matches the exact command name, so this cannot be fooled by a shell whose
    # argv merely mentions the word (which is how a naive `pgrep -f cargo` reports
    # its own grep, or a wrapper script, as a build).
    #
    # Zombies do not count. A killed build leaves children whose command name
    # outlives them and which burn no CPU ever again, and nothing guarantees PID 1
    # here reaps them; counting those pins the verdict at `building` for the rest
    # of the boot, which is one way a genuinely idle box never scales to zero.
    # Output is `name/pid` so a `building` verdict can say WHICH process it saw.
    for name in cargo rustc wasm-pack rustdoc; do
        for pid in $(pgrep -x "$name" 2>/dev/null); do
            state=$(awk -F')' '{ print $2 }' "/proc/$pid/stat" 2>/dev/null | awk '{ print $1 }')
            [ "$state" = Z ] && continue
            printf '%s/%s\n' "$name" "$pid"
        done
    done
}

leased() {
    if command -v builder-state >/dev/null 2>&1; then
        builder-state status --json 2>/dev/null | grep -q '"leased":true'
        return $?
    fi
    # No builder-state: fail closed (treat as busy) rather than stopping a box we
    # cannot prove is unused.
    return 0
}

# Live lease facts from ONE call, as "<recordCount> <youngestAgeSeconds|->".
#
# Two different things matter here and they are not interchangeable. `leaseCount`
# counts lease RECORDS, i.e. builds that can be named; `leased` is a flock probe, and
# a lock can be held by a child that inherited the fd after its recorded holder died
# (measured 2026-11-02: `leased: true`, zero records, the lock held by an orphaned
# `sleep`). Nothing can be named as waiting on that lock, so it must not veto a stop
# on its own. The YOUNGEST record is what the age rule needs: one fresh build must
# keep a batch of stale records from looking old.
lease_facts() {
    json=$(builder-state status --json 2>/dev/null) || return 1
    count=$(printf '%s' "$json" | sed -n 's/.*"leaseCount":\([0-9][0-9]*\).*/\1/p')
    [ -n "$count" ] || return 1
    youngest=$(printf '%s' "$json" \
        | grep -o '"started":"[^"]*"' \
        | sed 's/.*"started":"//; s/"$//' \
        | while read -r iso; do
              epoch=$(date -u -d "$iso" +%s 2>/dev/null) || continue
              printf '%s\n' "$epoch"
          done \
        | sort -n | tail -1)
    if [ -n "$youngest" ]; then
        printf '%s %s\n' "$count" "$(( $(now) - youngest ))"
    else
        printf '%s -\n' "$count"
    fi
}

# Seconds this sample has been part of an unbroken no-progress run, starting one if
# there is none. Boot-clamped for the same reason the idle marker is: a marker left
# by a previous boot is not evidence about this one.
wedge_since() {
    first=$(cat "$WEDGE_FILE" 2>/dev/null || echo "")
    boot=$(boot_time)
    if [ -z "$first" ] || [ "$first" -lt "$boot" ]; then
        first=$(now); printf '%s\n' "$first" >"$WEDGE_FILE"
    fi
    printf '%s\n' "$(( $(now) - first ))"
}
clear_wedge() { rm -f "$WEDGE_FILE"; }

# Processes running from a compiled test binary (…/target/{debug,release}/deps/…).
# Deliberately separate from build_processes: `procs` is what `park` refuses on and
# what the verdict quotes, and a running test is not a compile. This exists because
# churn is evidence about COMPILATION and says nothing about test execution -- a
# running test binary writes no files -- so a test tree is the one case where "no
# CPU and no churn" does not imply "no progress". Measured by dxdb: both of their
# wedges were `wrapper-…` / `storage_matrix-…` under target/*/deps/ with a `cargo`
# parent parked in do_wait, a shape indistinguishable from a long legitimate test.
test_binaries() {
    for proc in /proc/[0-9]*; do
        pid=${proc#/proc/}
        exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || continue
        case "$exe" in
            */target/debug/deps/*|*/target/release/deps/*)
                printf '%s/%s\n' "$(cat "/proc/$pid/comm" 2>/dev/null)" "$pid"
                ;;
        esac
    done
}

# True when a lease exists that is young enough to be a client still watching its
# build. Deliberately generous, because the cost of both mistakes is not symmetric:
# being generous delays stopping a wedge by one WEDGE_GRACE, while being strict can
# kill a build somebody is attached to. Unreadable lease state counts as watched.
lease_watched() {
    facts=$(lease_facts) || return 0
    count=${facts%% *}
    age=${facts##* }
    [ "$count" -gt 0 ] || return 1
    [ "$age" = "-" ] && return 0
    [ "$age" -lt "$WEDGE_GRACE" ] && return 0
    return 1
}

# A build can be BETWEEN processes -- rsyncing sources, waiting on a fetch, or
# unpacking a seed -- with no cargo running and CPU near zero. Leases cover the
# projects that take them, so this is the signal for the ones that do not.
# -print -quit makes the cost proportional to activity: it returns at the first
# recent file while a build is live, and only walks the whole tree when the box
# looks quiet. Both roots are scanned because starla builds under
# /data/projects/<slug>/builds and the older projects still use /data/builds.
recent_churn() {
    find /data/builds /data/projects -maxdepth 6 \
        -newermt "-${CHURN_WINDOW_MIN:-10} minutes" -print -quit 2>/dev/null
}

# No argument: every caller gets the same comparison, and every call UPDATES the
# stored CPU baseline. That is safe because idleness is judged as a RATE, not a
# bare delta. A bare delta cannot work here: the only caller of `--status` is the
# host supervisor, so leaving the baseline alone would compare against a stale
# sample and the box could never be judged idle -- which is how the first version
# of this script would have failed to scale anything to zero. The consequence is
# that the CPU window is the gap between two polls (5 minutes at the installed
# supervisor cadence), never a fixed sample.
verdict() {
    # A missing builder-state must not read as `leased`: fail closed either way
    # (the host stops only on `idle`), but a quote-verdict should say what is
    # actually wrong. This happened for real on 2026-10-30 -- a restart left
    # /usr/local/bin empty and the box silently dropped its admission control.
    if ! command -v builder-state >/dev/null 2>&1; then
        echo "no-lease-tool"
        return
    fi
    # One sample per call, used by the wedge check (which needs the rate while
    # processes exist) and by the idle decision below.
    rate=$(cpu_rate_hundredths)
    pids=$(build_processes)
    if [ -n "$pids" ]; then
        # Alive processes are `building` -- the direct, observed fact -- unless they
        # are demonstrably making no progress. A wedge looks exactly like a build to
        # `procs`, so it needs its own evidence: no CPU work, no churn, nobody
        # attached, and that state unbroken for WEDGE_GRACE.
        if [ -n "$rate" ] && [ "$rate" -lt "$IDLE_CPU_RATE_HUNDREDTHS" ] \
            && [ -z "$(recent_churn)" ] && ! lease_watched; then
            if [ -n "$(test_binaries)" ]; then
                # A test binary is running and writing nothing. The box genuinely
                # cannot tell a sleeping test from a deadlocked one, and the client is
                # the only thing that can, so this rule declines to judge. dxdb's
                # `make remote-orphans` lists those trees for a human instead.
                clear_wedge
            else
                wedge_for=$(wedge_since)
                if [ "$wedge_for" -ge "$WEDGE_GRACE" ]; then
                    log "wedged: ${pids} alive with cpu rate ${rate}% and no churn for ${wedge_for}s (>= ${WEDGE_GRACE}s); no progress is possible"
                    echo "wedged"
                    return
                fi
            fi
        else
            clear_wedge
        fi
        echo "building"
        return
    fi
    clear_wedge
    facts=$(lease_facts) || facts=""
    if [ -z "$facts" ]; then
        # The box cannot say who is building. Fail closed: a stop we cannot justify
        # is worse than one poll spent running a box nobody is using.
        echo "leased"
        return
    fi
    lease_count=${facts%% *}
    lease_age=${facts##* }
    if [ "$lease_count" -gt 0 ]; then
        # No compile, but a named build promises one. Either the few seconds between
        # taking the lease and cargo appearing, or a promise nobody will ever
        # withdraw. Distinguish them by age, and only pay for a churn scan once the
        # lease is old enough for the question to matter.
        if [ "$lease_age" = "-" ] || [ "$lease_age" -lt "$LEASE_START_GRACE" ]; then
            echo "leased"
            return
        fi
        if [ -n "$(recent_churn)" ]; then
            # A long build between processes -- seed extraction, a fetch, an rsync.
            echo "leased"
            return
        fi
        log "stale lease: newest of ${lease_count} is ${lease_age}s old (>= ${LEASE_START_GRACE}s) with no cargo and no churn; not counting it as busy"
    elif leased; then
        # The lock is held but no lease record exists, so nothing can be named as
        # waiting on it. Ignoring it is what turns a stranded lock back into a box
        # that scales to zero; a real build still shows up in `procs` above.
        log "unattributable lease lock (0 lease records); not counting it as busy"
    fi
    if [ -n "$(recent_churn)" ]; then
        echo "churning"
        return
    fi

    # Reuses the rate sampled at the top of this verdict -- see the note there on
    # why sampling again here is what made `idle` unreachable.
    if [ -z "$rate" ]; then
        # No usable baseline: do not claim idleness on no evidence.
        echo "warmup"
        return
    fi
    if [ "$rate" -ge "$IDLE_CPU_RATE_HUNDREDTHS" ]; then
        echo "cpu-active"
        return
    fi
    echo "idle"
}

stop_machine() {
    # The Fly machines API from inside the machine: no flyctl, no operator token.
    #
    # This path is normally UNAVAILABLE by design, not by accident: the box was
    # created with `machine run` on /bin/sleep, so it carries no FLY_* environment
    # and no machine token, and planting one would put a standing credential on a
    # shared box any build could read. The host applies the stop; this function
    # exists only for a box that someone deliberately equipped.
    # FALLBACK_ORDER matters -- a stop that fails must be visible, never silent.
    for path in \
        /usr/local/bin/fly-machine-stop \
        /data/bin/fly-machine-stop
    do
        if [ -x "$path" ]; then
            "$path" && return 0
        fi
    done
    # Last resort that needs no API at all: Fly restarts an exited init, so this is
    # NOT equivalent to a stop -- it is deliberately not attempted here. Report
    # instead of pretending.
    log "no fly-machine-stop on this box (expected: the host owns the stop)"
    return 1
}

one_cycle() {
    v=$(verdict)
    if [ "$v" = "idle" ]; then
        pending=$(cat "$PENDING_FILE" 2>/dev/null || echo "")
        [ -n "$pending" ] || { pending=$(now); printf '%s\n' "$pending" >"$PENDING_FILE"; }
        idle_for=$(( $(now) - pending ))
        log "idle confirmed ${idle_for}s/${GRACE}s"
        if [ "$idle_for" -ge "$GRACE" ]; then
            if [ "${BUILD_IDLE_DISABLE:-0}" = "1" ]; then
                log "would stop now, but BUILD_IDLE_DISABLE=1"
                return 0
            fi
            log "idle ${idle_for}s >= ${GRACE}s; scaling to zero"
            if stop_machine; then
                log "stop issued"
                printf '%s\n' "$(now)" >"$IDLE_SINCE_FILE"
                return 0
            fi
            log "stop FAILED; will retry next cycle"
        fi
    else
        if [ -f "$PENDING_FILE" ]; then
            log "activity ($v); idle timer cleared"
            rm -f "$PENDING_FILE"
        fi
    fi
}

case "${1:-}" in
    --once)
        v=$(verdict)
        printf '{"verdict":"%s","time":"%s"}\n' "$v" "$(iso)"
        exit 0
        ;;
    --status)
        v=$(verdict)
        # A --status poll IS a sample, so it maintains the idle marker exactly as
        # the foreground loop would: set on idle, cleared by any activity. This
        # matters because the box-side loop cannot own the grace period -- the box
        # has no Fly credential by design, so the host is the only sampler. Without
        # this the grace is dead code and a single idle sample stops the box, which
        # re-opens the race that once killed five lanes: start the box, let the
        # supervisor poll before the build takes its lease, lose the build.
        if [ "$v" = "idle" ]; then
            pending=$(cat "$PENDING_FILE" 2>/dev/null || echo "")
            boot=$(boot_time)
            if [ -z "$pending" ] || [ "$pending" -lt "$boot" ]; then
                pending=$(now); printf '%s\n' "$pending" >"$PENDING_FILE"
            fi
        else
            rm -f "$PENDING_FILE"
        fi
        pending=$(cat "$PENDING_FILE" 2>/dev/null || echo "")
        if [ -n "$pending" ]; then idle_for=$(( $(now) - pending )); else idle_for=0; fi
        # `procs` names what is actually running, and it is reported for EVERY
        # verdict, not just `building`: it is the only field here that is direct
        # evidence rather than inference from a CPU rate, a lease or a churn scan.
        # A consumer making a destructive decision -- scripts/build-server.sh park --
        # must see a live compile even when the verdict came out `warmup` (stale CPU
        # baseline) or `cpu-active`. Gating this on `building` is exactly how a park
        # guard read an empty process list while a sibling project's
        # `cargo test --workspace` was mid-run, and stopped the box underneath it.
        # It is computed here rather than reused from verdict() because verdict() runs
        # in a command substitution, so its variables do not survive the subshell.
        procs=$(build_processes | tr '\n' ',' | sed 's/,$//')
        printf '{"verdict":"%s","idleSeconds":%s,"grace":%s,"procs":"%s","time":"%s"}\n' \
            "$v" "$idle_for" "$GRACE" "$procs" "$(iso)"
        exit 0
        ;;
esac

log "watchdog starting (grace=${GRACE}s interval=${INTERVAL}s pid=$$)"
# Seed the CPU baseline so the first real cycle compares against something. The
# timestamp matters as much as the jiffies: a one-field file leaves the next sample
# no elapsed time to divide by, and the unset field arithmetics to 0.
printf '%s %s\n' "$(cpu_jiffies)" "$(now)" >"$CPU_SAMPLE"
while :; do
    one_cycle
    sleep "$INTERVAL"
done
