#!/bin/bash
# run.sh — launch the injection target with libpoltergeist.dylib injected via
# DYLD_INSERT_LIBRARIES.
#
# We first TRIED the spec's target, TextEdit:
#   /System/Applications/TextEdit.app/Contents/MacOS/TextEdit
# The dylib DOES load into TextEdit (AMFI is relaxed here), but TextEdit runs in the
# App Sandbox, which denies the shim's writes to /tmp/poltergeist and its bind() on
# /tmp/poltergeist.sock. So we fall back to a tiny non-sandboxed AppKit app,
# Target.app, and inject the SAME dylib into it. Pass "textedit" to try TextEdit anyway.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
DYLIB="$DIR/libpoltergeist.dylib"

if [ "$1" = "textedit" ]; then
    TARGET="/System/Applications/TextEdit.app/Contents/MacOS/TextEdit"
else
    TARGET="$DIR/Target.app/Contents/MacOS/Target"
fi

rm -f /tmp/poltergeist/loaded.txt /tmp/poltergeist.sock
mkdir -p /tmp/poltergeist

echo "Injecting $DYLIB into $TARGET"
DYLD_INSERT_LIBRARIES="$DYLIB" \
DYLD_LIBRARY_PATH="$DIR" \
    "$TARGET" &
echo "launched pid $!"
