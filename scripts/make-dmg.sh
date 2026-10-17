#!/bin/sh
# Builds and signs Yapn.app, then packs it into build/Yapn-<version>.dmg with an Applications shortcut,
# so installing is dragging one icon onto another.
set -eu
cd "$(dirname "$0")/.."

scripts/bundle.sh
APP=build/Yapn.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/Yapn-$VERSION.dmg"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
# ditto, not cp, so the code signature survives the copy.
ditto "$APP" "$STAGE/Yapn.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname Yapn -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "built $DMG"
