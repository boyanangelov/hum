#!/bin/zsh
# Builds Drift.app with swiftc (no Xcode required).
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Drift.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -parse-as-library \
  -target "$(uname -m)-apple-macos13.0" \
  Sources/DriftCore/*.swift Sources/Drift/*.swift \
  -o "$APP/Contents/MacOS/Drift"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Drift</string>
  <key>CFBundleDisplayName</key><string>Drift</string>
  <key>CFBundleIdentifier</key><string>local.drift.menubar</string>
  <key>CFBundleExecutable</key><string>Drift</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
echo "Run:     open $APP"
echo "Install: cp -R $APP /Applications/"
