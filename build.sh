#!/bin/sh
# Builds Seam.app. Signed with your Apple Development identity so the
# Accessibility permission survives rebuilds (ad-hoc signing loses it).
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/Seam.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Seam "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.iprabin.seam</string>
  <key>CFBundleName</key><string>Seam</string>
  <key>CFBundleExecutable</key><string>Seam</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
IDENTITY=$(security find-identity -p codesigning -v | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "built $APP"
