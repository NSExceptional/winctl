#!/bin/bash
# Build + ad-hoc sign the hittest target and controller.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

clang -arch arm64 -fmodules -framework Cocoa \
      -o Target.app/Contents/MacOS/Target target.m

clang -arch arm64 -fmodules -framework Cocoa -framework ApplicationServices \
      -o controller.app/Contents/MacOS/controller controller.m

codesign --force --sign - --identifier com.nscake.PoltergeistHittestTarget     Target.app
codesign --force --sign - --identifier com.nscake.PoltergeistHittestController controller.app
echo "built + signed."
