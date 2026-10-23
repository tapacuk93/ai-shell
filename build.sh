#!/bin/bash
# Compiles the sources and assembles AIShell.app in ./build.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/build/AIShell.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$DIR/Resources/Info.plist" "$APP/Contents/Info.plist"

# Pin the deployment target to Info.plist's LSMinimumSystemVersion. Left to itself swiftc
# targets the newest macOS the toolchain knows, and Launch Services refuses to open a binary
# whose minimum is newer than the running system (error -10825).
echo "Compiling…"
swiftc \
    -O \
    -swift-version 5 \
    -target "$(uname -m)-apple-macos13.0" \
    -framework AppKit \
    -framework ApplicationServices \
    -framework CoreServices \
    -framework Carbon \
    -o "$APP/Contents/MacOS/AIShell" \
    "$DIR"/Sources/*.swift

codesign --force --sign - --identifier com.oeaio.aishell "$APP" >/dev/null 2>&1 \
    || echo "warning: ad-hoc codesign failed"

# NB: do not `tccutil reset Accessibility` here. The stable --identifier above is enough for
# macOS to keep honouring the existing grant across rebuilds; resetting it every build just
# forces a re-grant and leaves the app deaf until someone notices.
echo "Built $APP"
