#!/bin/bash
# Runs the real standalone (LÖVE, on a virtual screen) with a test script driving it like a player, e.g.
#   tools/love_test/run.sh tools/love_test/walkthrough.lua <cache dir> <out dir>
# The map cache is linked into LÖVE's save folder so it plays offline from what is cached. Needs love, xvfb-run.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$(dirname "$HERE")")
SCRIPT=$(realpath "$1"); CACHE=$(realpath "$2"); OUT=$(realpath -m "$3")
BUILD=$(mktemp -d)
python3 "$REPO/tools/build_love.py" "$BUILD/game" > /dev/null
SAVE="$HOME/.local/share/love/tinyatlas/tinyatlas"
mkdir -p "$SAVE"
[ -e "$SAVE/cache" ] || ln -s "$CACHE" "$SAVE/cache"
mkdir -p "$OUT"
cd "$OUT"
TA_AUTOTEST="$SCRIPT" TA_TEST_OUT="$OUT" TA_TEST_LIB="$HERE/lib.lua" timeout ${TIMEOUT:-600} \
  xvfb-run -a -s "-screen 0 1920x1080x24" love "$BUILD/game" 2>&1 | grep -v "ALSA\|Could not open\|pw.conf\|ALSOFT\|^$" || true
rm -rf "$BUILD"
