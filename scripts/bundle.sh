#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build -c release --product CCDesk
BIN="$(swift build -c release --show-bin-path)/CCDesk"
APP="build/CCDesk.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/CCDesk"
cp scripts/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "$APP"
