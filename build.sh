#!/bin/zsh
# Builds Nabd.app (macOS 13 or later) and a `nabd` command-line shortcut next to this script.
#   ./build.sh            for this Mac's architecture
#   ./build.sh universal  Apple Silicon + Intel in one app (used for releases)
set -euo pipefail
cd "$(dirname "$0")"

APP=Nabd.app
mkdir -p "$APP/Contents/MacOS"
if [[ "${1:-}" == universal ]]; then
  work=$(mktemp -d)
  for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" Nabd.swift -o "$work/Nabd-$arch"
  done
  lipo -create "$work/Nabd-arm64" "$work/Nabd-x86_64" -output "$APP/Contents/MacOS/Nabd"
  rm -rf "$work"
else
  swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" Nabd.swift -o "$APP/Contents/MacOS/Nabd"
fi
cp Info.plist "$APP/Contents/Info.plist"
# Translations: one Localizable.strings per language, picked by macOS from the user's preferred languages.
rm -rf "$APP/Contents/Resources" && mkdir -p "$APP/Contents/Resources"
cp -R Localization/*.lproj "$APP/Contents/Resources/"
codesign --force --sign - "$APP" 2>/dev/null
ln -sf "$APP/Contents/MacOS/Nabd" nabd
echo "Built $APP — run: open $APP   or   ./nabd status"
