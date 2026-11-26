#!/bin/sh
# Stages Warm-up.app for local use. Bundle layout and LSUIElement setup adapted from Nameplate's
# Scripts/package_app.sh (MIT, Peter Steinberger, revision 2d6efa0354065d7dee875a0d2e9e5a57f715d8d4).
# Removed: bundled CLI helper, Sparkle framework and feed, URL scheme, upstream signing identity.
# Signs ad hoc. It never installs, launches, or touches the engine, LaunchAgent or preferences.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
OUT=${1:-"$ROOT/.build/stage"}
case "$OUT" in /*) ;; *) echo "output must be absolute" >&2; exit 2 ;; esac
BUNDLE_ID=local.warmup.menu
VERSION=0.7.0
APP="$OUT/Warm-up.app"
cd "$ROOT"
swift build -c release --product WarmupMenu
BIN="$(swift build -c release --show-bin-path)/WarmupMenu"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Warm-up</string>
    <key>CFBundleDisplayName</key><string>Warm-up</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>WarmupMenu</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>17</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>Includes code adapted from Nameplate, MIT License, Copyright (c) 2026 Peter Steinberger.</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null
cp "$BIN" "$APP/Contents/MacOS/WarmupMenu"
chmod 755 "$APP/Contents/MacOS/WarmupMenu"
cp "$ROOT/NOTICE.md" "$ROOT/LICENSES/Nameplate-MIT.txt" "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
codesign --force --sign - --options runtime --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict --verbose=1 "$APP"
shasum -a 256 "$APP/Contents/MacOS/WarmupMenu"
