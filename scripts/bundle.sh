#!/bin/bash
# build/TrackpadRunner.app を作る。既存の .app は上書きする。
# キーチェーンに自己署名証明書「TrackpadRunner Dev」があればそれで署名し、
# 作り直してもアクセシビリティ等の権限が外れないようにする。なければアドホック署名。
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP=build/TrackpadRunner.app
mkdir -p "$APP/Contents/MacOS"
cp .build/release/trackpad-runner "$APP/Contents/MacOS/trackpad-runner"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.madebyjun.trackpad-runner</string>
  <key>CFBundleName</key><string>TrackpadRunner</string>
  <key>CFBundleExecutable</key><string>trackpad-runner</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
IDENTITY="TrackpadRunner Dev"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
echo "$APP"
