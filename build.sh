#!/bin/bash
# Build winctl with a STABLE code identity:
#   - Info.plist (bundle id com.nscake.winctl) embedded in __TEXT,__info_plist
#   - codesigned with Tanner's Apple Development cert, so the designated
#     requirement is (identifier com.nscake.winctl AND that leaf cert) —
#     stable across rebuilds (NOT an ad-hoc cdhash that changes every build).
# The stable DR is what lets a single TCC grant keep working after a rebuild.
set -euo pipefail
cd "$(dirname "$0")"

SIGN_ID="Apple Development: Tanner Bennett (JWB6AQ4N38)"

clang -arch arm64 -fobjc-arc -fmodules -O2 \
  -framework Cocoa -framework ApplicationServices -framework IOSurface \
  -lsqlite3 \
  -sectcreate __TEXT __info_plist winctl.plist \
  -o winctl winctl.m

codesign --force --sign "$SIGN_ID" --identifier com.nscake.winctl winctl

echo "built + signed. designated requirement:"
codesign -dr - winctl 2>&1 | sed 's/^/  /'
