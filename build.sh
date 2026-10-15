#!/bin/zsh
# Builds Nabd.app and a `nabd` command-line shortcut next to this script.
set -euo pipefail
cd "$(dirname "$0")"

APP=Nabd.app
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 Nabd.swift -o "$APP/Contents/MacOS/Nabd"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" 2>/dev/null
ln -sf "$APP/Contents/MacOS/Nabd" nabd
echo "Built $APP — run: open $APP   or   ./nabd status"
