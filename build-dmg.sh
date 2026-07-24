#!/usr/bin/env bash
# build-dmg.sh - produce a distributable MacPatch.dmg containing the pre-built app
# Run this on a Big Sur (or newer) Mac with Xcode CLT installed.
# The resulting DMG is what you upload to your store for one-tap install.
set -euo pipefail

APPNAME="MacPatch Dashboard"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="$SCRIPT_DIR/dist"
DMG_PATH="$DIST_DIR/MacPatch.dmg"
STAGING="$SCRIPT_DIR/.dmg-staging"

log() { printf "  -> %s\n" "$*"; }
die() { printf "  ERROR: %s\n" "$*" >&2; exit 1; }

# 1. Build the app via the existing installer logic, but into a staging dir
log "Building app bundle..."
rm -rf "$STAGING"; mkdir -p "$STAGING"

BUILD_DIR="$(mktemp -d)"; trap 'rm -rf "$BUILD_DIR" "$STAGING"' EXIT
cp "$SCRIPT_DIR/MacPatchDashboard.swift" "$BUILD_DIR/main.swift"

swiftc "$BUILD_DIR/main.swift" -o "$BUILD_DIR/MacPatchDashboard" \
    -sdk "$(xcrun --show-sdk-path)" \
    -target "$(uname -m)-apple-macos11.0" \
    -framework SwiftUI -framework AppKit -framework Foundation \
    || die "Compilation failed"

BUNDLE="$STAGING/$APPNAME.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources/plugins"
cp "$BUILD_DIR/MacPatchDashboard" "$BUNDLE/Contents/MacOS/MacPatchDashboard"
cp "$SCRIPT_DIR/patch-app.sh"     "$BUNDLE/Contents/Resources/patch-app.sh"
cp "$SCRIPT_DIR/probe.sh"         "$BUNDLE/Contents/Resources/probe.sh"
cp "$SCRIPT_DIR"/plugins/*.mplugin "$BUNDLE/Contents/Resources/plugins/" 2>/dev/null || true
chmod +x "$BUNDLE/Contents/MacOS/MacPatchDashboard" \
         "$BUNDLE/Contents/Resources/patch-app.sh" \
         "$BUNDLE/Contents/Resources/probe.sh"

cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MacPatch Dashboard</string>
    <key>CFBundleDisplayName</key><string>MacPatch Dashboard</string>
    <key>CFBundleIdentifier</key><string>com.macpatch.bigsur.dashboard</string>
    <key>CFBundleVersion</key><string>3.0</string>
    <key>CFBundleShortVersionString</key><string>3.0</string>
    <key>CFBundleExecutable</key><string>MacPatchDashboard</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$BUNDLE" 2>/dev/null || true
log "App built"

# 2. Add an Applications symlink so users can drag-to-install
ln -s /Applications "$STAGING/Applications"

# 3. Create the DMG
mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH"
log "Creating DMG..."
hdiutil create -volname "MacPatch" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG_PATH" >/dev/null

log "Done: $DMG_PATH"
echo ""
echo "  Upload $DMG_PATH to your store."
echo "  Users open it, drag MacPatch to Applications, and launch. One tap."
