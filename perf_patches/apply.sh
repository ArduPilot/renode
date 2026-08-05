#!/bin/sh
# Apply the performance patches to the src/Infrastructure submodule.
# Run from anywhere after "git submodule update --init"; idempotent -
# does nothing if the stack is already applied. See perf_lessons.md.
set -e
cd "$(dirname "$0")/.."
# the last patch only reverse-applies if the whole stack is in place
last=$(ls perf_patches/0*.patch | tail -1)
if git -C src/Infrastructure apply --check --reverse "../../$last" 2>/dev/null; then
    echo "perf patches already applied"
    exit 0
fi
for p in perf_patches/0*.patch; do
    if ! git -C src/Infrastructure apply "../../$p" 2>/dev/null; then
        echo "FAILED to apply $p" >&2
        echo "src/Infrastructure must be a clean checkout of the commit recorded by this branch (git submodule update --init)" >&2
        exit 1
    fi
    echo "applied $p"
done
