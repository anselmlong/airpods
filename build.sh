#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

BIN=".build/release/airpods"
APP="airpods.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/airpods"
cp "Sources/airpods/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

echo "Built $APP"
echo "Run: ./airpods.app/Contents/MacOS/airpods"
