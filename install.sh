#!/usr/bin/env bash
# MacPatch BigSur - self-installer
# Compiles the SwiftUI dashboard and installs to /Applications/MacPatch Dashboard.app
# No SIP disabling required.
set -euo pipefail

APPNAME="MacPatch Dashboard"
APPBUNDLE="/Applications/MacPatch Dashboard.app"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWIFT_SRC="$SCRIPT_DIR/MacPatchDashboard.swift"
PATCH_SCRIPT="$SCRIPT_DIR/patch-app.sh"

log() { printf "  -> %s\n" "$*"; }
ok()  { printf "  OK %s\n" "$*"; }
die() { printf "  ERROR: %s\n" "$*" >&2; exit 1; }
hr()  { echo "----------------------------------------------------"; }

hr
echo "  MacPatch Dashboard - Installer"
echo "  Patches app bundles so macOS 12+ apps run on Big Sur."
echo "  SIP does not need to be disabled."
hr
echo ""

# Preflight

[[ -f "$SWIFT_SRC" ]]    || die "MacPatchDashboard.swift not found next to install.sh"
[[ -f "$PATCH_SCRIPT" ]] || die "patch-app.sh not found next to install.sh"

OS_VER=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
log "macOS $OS_VER - OK"

if ! command -v swiftc &>/dev/null; then
    echo "  Xcode Command Line Tools are required."
    echo "  Opening installer - re-run this script after installation completes."
    xcode-select --install 2>/dev/null || true
    exit 1
fi

SWIFT_VER=$(swiftc --version 2>&1 | head -1 | sed 's/Swift version //')
log "Swift $SWIFT_VER - OK"

# Compile

echo ""
log "Compiling dashboard (first run takes ~30 seconds)..."

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

BINARY="$BUILD_DIR/MacPatchDashboard"
COMPILE_LOG="$BUILD_DIR/compile.log"

# Swift requires top-level executable code to be in a file named main.swift
cp "$SWIFT_SRC" "$BUILD_DIR/main.swift"

set +e
swiftc \
    "$BUILD_DIR/main.swift" \
    -o "$BINARY" \
    -sdk "$(xcrun --show-sdk-path)" \
    -target "$(uname -m)-apple-macos11.0" \
    -framework SwiftUI \
    -framework AppKit \
    -framework Foundation \
    > "$COMPILE_LOG" 2>&1
COMPILE_EXIT=$?
set -e

if [[ $COMPILE_EXIT -ne 0 || ! -f "$BINARY" ]]; then
    cat "$COMPILE_LOG"
    die "Compilation failed - see output above"
fi
ok "Compilation complete"

# Assemble .app bundle

echo ""
log "Assembling .app bundle..."

BUNDLE="$BUILD_DIR/MacPatch Dashboard.app"
CONTENTS="$BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$RESOURCES_DIR/plugins"

cp "$BINARY"       "$MACOS_DIR/MacPatchDashboard"
cp "$PATCH_SCRIPT" "$RESOURCES_DIR/patch-app.sh"
# Bundle the hardware probe and store plugins so the Store tab can verify + gate
[[ -f "$SCRIPT_DIR/probe.sh" ]] && cp "$SCRIPT_DIR/probe.sh" "$RESOURCES_DIR/probe.sh"
if compgen -G "$SCRIPT_DIR/plugins/*.mplugin" >/dev/null; then
    cp "$SCRIPT_DIR"/plugins/*.mplugin "$RESOURCES_DIR/plugins/"
fi
chmod +x "$MACOS_DIR/MacPatchDashboard" "$RESOURCES_DIR/patch-app.sh"
[[ -f "$RESOURCES_DIR/probe.sh" ]] && chmod +x "$RESOURCES_DIR/probe.sh"

cat > "$MACOS_DIR/patch-app.sh" <<'WRAPPER'
#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$DIR/../Resources/patch-app.sh" "$@"
WRAPPER
chmod +x "$MACOS_DIR/patch-app.sh"

# Try to build an icon from a system resource
if command -v iconutil &>/dev/null && command -v sips &>/dev/null; then
    ICONSET="$BUILD_DIR/AppIcon.iconset"
    mkdir -p "$ICONSET"
    ICON_SRC="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/KEXT.icns"
    if [[ -f "$ICON_SRC" ]]; then
        for SIZE in 16 32 64 128 256 512; do
            sips -z $SIZE $SIZE "$ICON_SRC" \
                --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null 2>&1 || true
        done
        iconutil -c icns "$ICONSET" -o "$RESOURCES_DIR/AppIcon.icns" 2>/dev/null || true
    fi
fi

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>MacPatch Dashboard</string>
    <key>CFBundleDisplayName</key>       <string>MacPatch Dashboard</string>
    <key>CFBundleIdentifier</key>        <string>com.macpatch.bigsur.dashboard</string>
    <key>CFBundleVersion</key>           <string>2.0</string>
    <key>CFBundleShortVersionString</key><string>2.0</string>
    <key>CFBundleExecutable</key>        <string>MacPatchDashboard</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>    <string>11.0</string>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>MacPatch needs administrator access to patch app bundles.</string>
</dict>
</plist>
PLIST

ok "Bundle assembled"

# Install

echo ""
log "Installing to $APPBUNDLE..."

if [[ -d "$APPBUNDLE" ]]; then
    log "Removing previous installation..."
    rm -rf "$APPBUNDLE"
fi

cp -R "$BUNDLE" "$APPBUNDLE"
ok "Installed: $APPBUNDLE"

if command -v codesign &>/dev/null; then
    codesign --force --deep --sign - "$APPBUNDLE" 2>/dev/null && ok "Signed (ad-hoc)" || true
fi

xattr -dr com.apple.quarantine "$APPBUNDLE" 2>/dev/null || true

echo ""
hr
ok "Installation complete!"
echo ""
echo "  Launch:  open -a 'MacPatch Dashboard'"
echo "  Or double-click it in /Applications"
hr
echo ""

read -r -p "  Open MacPatch Dashboard now? [Y/n] " ans
if [[ ! "$ans" =~ ^[Nn] ]]; then
    open "$APPBUNDLE"
fi
