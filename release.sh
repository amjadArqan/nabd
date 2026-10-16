#!/bin/zsh
# Builds a universal Nabd.app and packs it as dist/Nabd.dmg and dist/Nabd.zip for a GitHub release.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh universal
rm -rf dist && mkdir -p dist/dmg
ditto -c -k --keepParent Nabd.app dist/Nabd.zip
ditto Nabd.app dist/dmg/Nabd.app
ln -s /Applications dist/dmg/Applications
hdiutil create -volname "Nabd" -srcfolder dist/dmg -ov -format UDZO dist/Nabd.dmg >/dev/null
rm -rf dist/dmg
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
echo "Nabd $version → dist/Nabd.dmg, dist/Nabd.zip"
