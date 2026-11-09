#!/bin/sh
# Give each project its own user, build root and seed on the shared build server.
#
# WHY
#
# Every build on this box ran as uid 1000/root under /data/builds/<hash>/ and shared
# one /data/libs. The hash isolates target/ directories, but nothing isolated the
# path-dependency seed, so the last project to seed /data/libs decided which
# openai-oxide (or primadb, or rust-bash) every concurrent build saw. That is not
# theoretical: a starla workspace pinned to openai-oxide 0.14.0 failed to resolve
# against a seed holding 0.17.0, and the error ("candidate versions found which
# didn't match") reads like a broken Cargo.toml rather than cross-project bleed.
#
# Sharing one uid also means any project can read, modify or delete another's build
# tree and its ~/.cargo, and that a `cargo clean` typo can reach across projects.
#
# THE MODEL
#
#   /data/projects/<slug>/libs      that project's path-dependency seed
#   /data/projects/<slug>/builds    its cargo-remote trees (--temp-dir)
#   /data/projects/<slug>/{cargo,rustup}   optional per-user caches
#   user <slug> (uid allocated by the system), home = /data/projects/<slug>
#
# Each project's builds run as its own user, so the kernel -- not a convention --
# enforces that one project cannot touch another's artifacts. The seed is per
# project, so two checkouts of different vintages never collide.
#
# This is additive on purpose: existing root-based builds keep working, and a
# project migrates by adopting the env this prints. Nothing here restarts the box or
# interrupts a running build.
#
# USAGE
#   builder-project ensure <slug>     create user + dirs if absent; print the env
#   builder-project env <slug>        print the env for an existing project
#   builder-project list              every project, user, size and last activity
#
# The env it prints is what a cargo-remote invocation needs:
#   -t /data/projects/<slug>/builds   so ../../libs resolves inside the project
#   and the build runs as <slug> via sudo.
#
# Slug rules: [a-z0-9][a-z0-9-]{0,19}, because it becomes a unix username.

set -u

ROOT=${BUILDER_PROJECTS_ROOT:-/data/projects}

die() { echo "builder-project: $*" >&2; exit 1; }

valid_slug() {
    case "$1" in
        ''|*[!a-z0-9-]*) return 1 ;;
        -*) return 1 ;;
    esac
    [ "${#1}" -le 20 ]
}

ensure() {
    slug=${1:-}
    valid_slug "$slug" || die "invalid slug '$slug' (use [a-z0-9-], max 20, no leading -)"

    home="$ROOT/$slug"
    mkdir -p "$home"

    # /etc/passwd is on the ephemeral rootfs, so a restart deletes the project user
    # while /data/projects/<slug> survives on the volume. That makes ensure() a boot
    # step, not a one-off, and a boot step must not churn identity: letting --system
    # pick a fresh uid each restart rewrites the recursive chown below over a
    # multi-GB tree and invalidates anything keyed on the project's uid. Reuse the
    # uid that already owns the home, as long as nothing else has claimed it.
    owner_uid=$(stat -c %u "$home" 2>/dev/null || echo 0)
    if ! id "$slug" >/dev/null 2>&1; then
        # A system user with a home on the volume: --system keeps it out of the way
        # in passwd ordering, and the home is created here so ownership is right from
        # the first file rather than fixed up later.
        uid_opt=""
        if [ "$owner_uid" -ge 100 ] && ! getent passwd "$owner_uid" >/dev/null 2>&1; then
            uid_opt="--uid $owner_uid"
        fi
        # Deliberate word splitting: $uid_opt is either empty or two arguments.
        useradd --system --create-home --home-dir "$home" --shell /bin/sh $uid_opt \
            --comment "build project $slug" "$slug" \
            || die "could not create user $slug"
    fi

    mkdir -p "$home/libs" "$home/builds"
    # Skip the recursive walk when ownership is already right, which is the normal
    # boot path once the uid above is preserved.
    if [ "$owner_uid" != "$(id -u "$slug")" ]; then
        chown -R "$slug:$slug" "$home"
    fi
    chmod 750 "$home"
    printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ) ensured" >"$home/.builder-project"
    chown "$slug:$slug" "$home/.builder-project"

    print_env "$slug"
}

print_env() {
    slug=$1
    home="$ROOT/$slug"
    cat <<EOF
BUILDER_PROJECT=$slug
BUILDER_USER=$slug
BUILDER_HOME=$home
BUILDER_TEMP_DIR=$home/builds
BUILDER_LIBS_SEED=$home/libs
EOF
}

list_projects() {
    printf '%-20s %-8s %6s  %s\n' SLUG UID SIZE 'LAST BUILD'
    for d in "$ROOT"/*/; do
        [ -d "$d" ] || continue
        slug=$(basename "$d")
        [ -f "$d/.builder-project" ] || continue
        uid=$(id -u "$slug" 2>/dev/null || echo -)
        size=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
        last=$(find "$d/builds" -maxdepth 2 -name target -printf '%TY-%Tm-%Td\n' 2>/dev/null | sort | tail -1)
        printf '%-20s %-8s %6s  %s\n' "$slug" "$uid" "${size:--}" "${last:--}"
    done
}

case "${1:-}" in
    ensure) shift; ensure "${1:-}" ;;
    env) shift; valid_slug "${1:-}" || die "invalid slug"; print_env "${1}" ;;
    list) list_projects ;;
    *)
        echo "usage: builder-project ensure <slug> | env <slug> | list" >&2
        exit 2
        ;;
esac
