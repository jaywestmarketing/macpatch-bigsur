#!/usr/bin/env bash
# MacPatch BigSur — self-installer
# Compiles the SwiftUI dashboard and installs it to /Applications/MacPatch Dashboard.app
# No SIP disabling required.
set -euo pipefail

APP_NAME="MacPatch Dashboard"
APP_BUNDLE="/Applications/${APP_NAME}.app"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWIFT_SRC="$SCRIPT_DIR/MacPatchDashboard.swift"
PATCH_SCRIPT="$SCRIPT_DIR/patch-app.sh"

log()  { printf "  \033[1;34m→\033[0m %s\n" "$*"; }
ok()   { printf "  \033[1;32m✓\033[0m %s\n" "$*"; }
die()  { printf "  \033[1;31m✗\033[0m %s\n" "$*" >&2; exit 1; }
hr()   { printf "%.0s─" {1..52}; echo; }

hr
printf "  \033[1mMacPatch Dashboard — Installer\033[0m\n"
printf "  Patches app bundles so macOS 12+ apps run on Big Sur.\n"
printf "  SIP does not need to be disabled.\n"
hr
echo ""

# ── Preflight checks ──────────────────────────────────────────────────────────

[[ -f "$SWIFT_SRC" ]]    || die "MacPatchDashboard.swift not found next to install.sh"
[[ -f "$PATCH_SCRIPT" ]] || die "patch-app.sh not found next to install.sh"

OS_VER=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
if [[ "$OS_VER" != 11.* && "$OS_VER" != 12.* && "$OS_VER" != 13.* && "$OS_VER" != 14.* ]]; then
    die "Unexpected macOS version: $OS_VER"
fi
log "macOS $OS_VER — OK"

if ! command -v swiftc &>/dev/null; then
    echo ""
    echo "  Xcode Command Line Tools are required."
    echo "  Opening installer — re-run this script after installation completes."
    xcode-select --install 2>/dev/null || true
    exit 1
fi

SWIFT_VER=$(swiftc --version 2>&1 | head -1 | sed 's/Swift version //')
log "Swift $SWIFT_VER — OK"

# ── Compile ───────────────────────────────────────────────────────────────────

echo ""
log "Compiling dashboard (first run takes ~30 seconds)…"

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

BINARY="$BUILD_DIR/MacPatchDashboard"

# Swift only allows top-level executable code in a file named main.swift
cp "$SWIFT_SRC" "$BUILD_DIR/main.swift"

COMPILE_LOG="$BUILD_DIR/compile.log"
swiftc \
    "$BUILD_DIR/main.swift" \
    -o "$BINARY" \
    -sdk "$(xcrun --show-sdk-path)" \
    -target "$(uname -m)-apple-macos11.0" \
    -framework SwiftUI \
    -framework AppKit \
    -framework Foundation \
    > "$COMPILE_LOG" 2>&1

if [[ $? -ne 0 || ! -f "$BINARY" ]]; then
    grep -v "^$" "$COMPILE_LOG" | sed 's/^/    /'
    die "Compilation failed — see output above"
fi
grep "error:" "$COMPILE_LOG" | sed 's/^/    /' || true
ok "Compilation complete"

# ── Build .app bundle ─────────────────────────────────────────────────────────

echo ""
log "Assembling .app bundle…"

BUNDLE="$BUILD_DIR/${APP_NAME}.app"
CONTENTS="$BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BINARY"       "$MACOS_DIR/MacPatchDashboard"
cp "$PATCH_SCRIPT" "$RESOURCES_DIR/patch-app.sh"
chmod +x "$MACOS_DIR/MacPatchDashboard" "$RESOURCES_DIR/patch-app.sh"

# Thin launcher wrapper so the Swift app can resolve patch-app.sh via Bundle
cat > "$MACOS_DIR/patch-app.sh" <<'WRAPPER'
#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$DIR/../Resources/patch-app.sh" "$@"
WRAPPER
chmod +x "$MACOS_DIR/patch-app.sh"

# Generate a simple ICNS-like icon using sips if available
# (uses the macOS built-in shield system icon as placeholder)
if command -v iconutil &>/dev/null && command -v sips &>/dev/null; then
    ICONSET="$BUILD_DIR/AppIcon.iconset"
    mkdir -p "$ICONSET"
    ICON_SRC="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/KEXT.icns"
    if [[ -f "$ICON_SRC" ]]; then
        for SIZE in 16 32 64 128 256 512; do
            sips -z $SIZE $SIZE "$ICON_SRC" \
                --out "$ICONSET/icon_${SIZE}x${SIZE}.png" &>/dev/null || true
        done
        iconutil -c icns "$ICONSET" -o "$RESOURCES_DIR/AppIcon.icns" 2>/dev/null || true
    fi
fi

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>       <string>${APP_NAME}</string>
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
    <string>MacPatch needs to run privileged shell commands to patch app bundles.</string>
</dict>
</plist>
PLIST

ok "Bundle assembled"

# ── Install ───────────────────────────────────────────────────────────────────

echo ""
log "Installing to $APP_BUNDLE…"

if [[ -d "$APP_BUNDLE" ]]; then
    log "Removing previous installation…"
    rm -rf "$APP_BUNDLE"
fi

cp -R "$BUNDLE" "$APP_BUNDLE"
ok "Installed: $APP_BUNDLE"

# Ad-hoc sign the installed app
if command -v codesign &>/dev/null; then
    codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null && ok "Signed (ad-hoc)" || true
fi

# Quarantine-clear so Gatekeeper doesn't block on first launch
xattr -dr com.apple.quarantine "$APP_BUNDLE" 2>/dev/null || true

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
    open "$APP_BUNDLE"
fi
