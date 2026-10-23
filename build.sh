#!/bin/bash
# Baut TibberPrice.app (ad-hoc signiert) und startet sie.
set -euo pipefail
cd "$(dirname "$0")"

APP="TibberPrice.app"
BIN="$APP/Contents/MacOS/TibberPrice"

swiftc -O -parse-as-library -target arm64-apple-macos13.0 \
  TibberPrice.swift -o /tmp/TibberPrice.build

# Self-Check vor dem Bundle
/tmp/TibberPrice.build --selfcheck

mkdir -p "$APP/Contents/MacOS"
mv /tmp/TibberPrice.build "$BIN"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>TibberPrice</string>
  <key>CFBundleIdentifier</key><string>de.klspn.TibberPrice</string>
  <key>CFBundleName</key><string>TibberPrice</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" 2>/dev/null
pkill -x TibberPrice 2>/dev/null || true
open "$APP"
echo "gestartet: $PWD/$APP"
