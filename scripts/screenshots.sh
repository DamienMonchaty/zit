#!/bin/bash
# The documentation's screenshots, taken again: a made-up repository, then
# the "docs screenshots" test, which writes docs/screenshots/*.png. Run from
# the repository's root, on a desktop — the shots are drawn by the GPU.
set -e
cd "$(dirname "$0")/.."
bash scripts/demo-repo.sh /tmp/acme-web >/dev/null
# The suite runs whole, as zig build test does: what fails for want of a
# GPU in it says nothing of the shots.
ZIT_SHOTS=1 zig build test -- --test-filter "docs screenshots" || true
ls -1 docs/screenshots
