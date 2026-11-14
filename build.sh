#!/bin/zsh
# Builds Hum.app with swiftc (no Xcode required): a universal binary
# (Apple Silicon + Intel) for macOS 13 or later.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Hum.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library \
    -target "$arch-apple-macos13.0" \
    Sources/HumCore/*.swift Sources/Hum/*.swift \
    -o "build/Hum-$arch"
done
lipo -create -output "$APP/Contents/MacOS/Hum" build/Hum-arm64 build/Hum-x86_64
rm build/Hum-arm64 build/Hum-x86_64

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Hum</string>
  <key>CFBundleDisplayName</key><string>Hum</string>
  <key>CFBundleIdentifier</key><string>io.github.boyanangelov.hum</string>
  <key>CFBundleExecutable</key><string>Hum</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
