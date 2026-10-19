#!/bin/bash
# Build HT07Menu.app (menu-bar QCY HT07 controller). No Xcode project needed.
set -e
cd "$(dirname "$0")"
APP=HT07Menu.app
BIN=HT07Menu

echo "[1/3] compiling…"
swiftc HT07Menu.swift -o "$BIN" -O \
  -framework SwiftUI -framework CoreBluetooth -framework AppKit \
  -parse-as-library -target arm64-apple-macos14.0

echo "[2/3] bundling…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>HT07Menu</string>
  <key>CFBundleIdentifier</key><string>com.local.ht07menu</string>
  <key>CFBundleName</key><string>HT07Menu</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>Control the QCY Arcbuds HT07 (ANC, battery, touch) over Bluetooth LE.</string>
</dict>
</plist>
PLIST
cp "$BIN" "$APP/Contents/MacOS/$BIN"
codesign --force --sign - --identifier com.local.ht07menu "$APP" >/dev/null 2>&1 || true

echo "[3/3] done: $PWD/$APP"
