#!/bin/bash
# Builds a double-clickable Clay.app (release build) in the project folder.
#   Scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Clay
swift build -c release --product ClaySnapshots

APP=Clay.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Clay "$APP/Contents/MacOS/Clay"

# App icon: render the clay vase, then scale it to every size macOS asks for.
WORK=$(mktemp -d)
ICONSET="$WORK/Clay.iconset"
mkdir -p "$ICONSET"
.build/release/ClaySnapshots --icon "$WORK/icon-1024.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$WORK/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$WORK/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Clay.icns"
rm -rf "$WORK"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Clay</string>
  <key>CFBundleDisplayName</key><string>Clay</string>
  <key>CFBundleIdentifier</key><string>com.silverninja71.clay</string>
  <key>CFBundleExecutable</key><string>Clay</string>
  <key>CFBundleIconFile</key><string>Clay</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS will run it locally.
codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"
