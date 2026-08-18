#!/bin/sh
# Apply the performance patches to the src/Infrastructure submodule.
# Run from anywhere after "git submodule update --init"; idempotent -
# does nothing for patches already applied. See perf_lessons.md.
set -e
cd "$(dirname "$0")/.."

last_applied=
for p in $(ls perf_patches/0*.patch | sort -r); do
    if git -C src/Infrastructure apply --check --reverse "../../$p" 2>/dev/null; then
        last_applied="$p"
        break
    fi
done

for p in perf_patches/0*.patch; do
    if [ -n "$last_applied" ]; then
        echo "already applied $p"
        if [ "$p" = "$last_applied" ]; then
            last_applied=
        fi
        continue
    fi
    if ! git -C src/Infrastructure apply "../../$p" 2>/dev/null; then
        echo "FAILED to apply $p" >&2
        echo "src/Infrastructure must be the commit recorded by this branch" >&2
        echo "with an ordered prefix of this patch stack applied" >&2
        exit 1
    fi
    echo "applied $p"
done
