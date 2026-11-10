#!/bin/bash
# Builds AustialCast.app (menu bar sender) from the Swift package.
#   ./scripts/build-mac-app.sh            -> dist/AustialCast.app
#   ./scripts/build-mac-app.sh --install  -> also copies it to /Applications
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/AustialCast.app"
VERSION="1.0.0"

# Universal binary (Apple silicon + Intel) so one build works everywhere; UNIVERSAL=0 builds for this Mac only.
ARCHS=(--arch arm64 --arch x86_64)
[ "${UNIVERSAL:-1}" = "0" ] && ARCHS=()

echo "Building release binary…"
(cd "$ROOT/mac" && swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --product AustialCastApp 2>&1 | tail -2 && swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --product austialcast 2>&1 | tail -2)
BIN="$(cd "$ROOT/mac" && swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/AustialCastApp" "$APP/Contents/MacOS/AustialCast"
cp "$BIN/austialcast" "$APP/Contents/Resources/austialcast"

echo "Rendering icon…"
ICONSET="$(mktemp -d)/AppIcon.iconset"
swift "$ROOT/scripts/make-icon.swift" "$ROOT/docs/assets/logo.svg" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>AustialCast</string>
    <key>CFBundleDisplayName</key><string>AustialCast</string>
    <key>CFBundleIdentifier</key><string>app.austial.cast.mac</string>
    <key>CFBundleExecutable</key><string>AustialCast</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>AustialCast finds TVs on your network and streams your screen to them.</string>
    <key>NSBonjourServices</key>
    <array><string>_austialcast._tcp</string></array>
    <key>NSScreenCaptureUsageDescription</key>
    <string>AustialCast captures your screen to show it on your TV.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: gives macOS a stable identity so the Screen Recording permission sticks.
codesign --force --deep --sign - "$APP" >/dev/null
codesign --verify --deep --strict "$APP" && echo "Signed (ad-hoc)."
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
  rm -rf /Applications/AustialCast.app
  cp -R "$APP" /Applications/AustialCast.app
  echo "Installed to /Applications/AustialCast.app"
fi
