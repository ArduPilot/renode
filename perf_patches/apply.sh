#!/bin/sh
# Apply the performance patches to the src/Infrastructure and tlib submodules.
# Run from anywhere after "git submodule update --init"; idempotent -
# does nothing for patches already applied. See perf_lessons.md.
set -e
cd "$(dirname "$0")/.."

repo_root=$(pwd)

apply_series()
{
    target=$1
    shift

    if [ ! -e "$target/.git" ]; then
        echo "$target is not initialized; run git submodule update --init --recursive" >&2
        exit 1
    fi

    last_applied=
    for p in $(printf '%s\n' "$@" | sort -r); do
        if git -C "$target" apply --check --reverse "$repo_root/$p" 2>/dev/null; then
            last_applied="$p"
            break
        fi
    done

    for p in "$@"; do
        if [ -n "$last_applied" ]; then
            echo "already applied $p"
            if [ "$p" = "$last_applied" ]; then
                last_applied=
            fi
            continue
        fi
        if ! git -C "$target" apply "$repo_root/$p" 2>/dev/null; then
            echo "FAILED to apply $p" >&2
            echo "$target must be the commit recorded by this branch" >&2
            echo "with an ordered prefix of this patch stack applied" >&2
            exit 1
        fi
        echo "applied $p"
    done
}

apply_series src/Infrastructure perf_patches/0*.patch
apply_series src/Infrastructure/src/Emulator/Cores/tlib perf_patches/tlib/0*.patch
