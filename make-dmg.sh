#!/bin/bash
# Build HT07Menu.app and package it into a distributable .dmg with a drag-to-
# Applications layout. The app is ad-hoc signed and NOT notarized, so anyone who
# downloads the result must right-click > Open (or strip quarantine). See README.
set -e
cd "$(dirname "$0")"

./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" HT07Menu.app/Contents/Info.plist 2>/dev/null || echo "1.0")
DMG="HT07Menu-$VERSION.dmg"
STAGE="$(mktemp -d)"

cp -R HT07Menu.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "HT07Menu" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "built: $PWD/$DMG"
shasum -a 256 "$DMG"
