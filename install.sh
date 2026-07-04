#!/usr/bin/env bash
# MacPatch BigSur — self-installer
# Compiles MacPatchDashboard.swift into a native .app and installs it
# alongside patch.sh into /Applications/MacPatch Dashboard.app
set -euo pipefail

APP_NAME="MacPatch Dashboard"
APP_BUNDLE="/Applications/${APP_NAME}.app"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWIFT_SRC="$SCRIPT_DIR/MacPatchDashboard.swift"
PATCH_SH="$SCRIPT_DIR/patch.sh"

log()  { echo "  [install] $*"; }
die()  { echo "  [install] ERROR: $*" >&2; exit 1; }
hr()   { echo "────────────────────────────────────────────────────"; }

hr
echo "  MacPatch BigSur — Dashboard Installer"
hr

# ── Preflight ──────────────────────────────────────────────────────────────

[[ -f "$SWIFT_SRC" ]]  || die "MacPatchDashboard.swift not found at $SWIFT_SRC"
[[ -f "$PATCH_SH" ]]   || die "patch.sh not found at $PATCH_SH"

if ! command -v swiftc &>/dev/null; then
    echo ""
    echo "  Xcode Command Line Tools are required to compile the dashboard."
    echo "  Install them now? (This will open the system installer)"
    read -r -p "  [y/N] " ans
    if [[ "$ans" =~ ^[Yy] ]]; then
        xcode-select --install
        echo "  After installation completes, re-run this installer."
    fi
    exit 1
fi

SWIFT_VERSION=$(swiftc --version 2>&1 | head -1)
log "Compiler: $SWIFT_VERSION"

# ── Build ──────────────────────────────────────────────────────────────────

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

BINARY="$BUILD_DIR/MacPatchDashboard"

log "Compiling SwiftUI app (this takes ~30 seconds on first run)…"
swiftc \
    "$SWIFT_SRC" \
    -o "$BINARY" \
    -sdk "$(xcrun --show-sdk-path)" \
    -target "$(uname -m)-apple-macos11.0" \
    -framework SwiftUI \
    -framework AppKit \
    -framework Foundation \
    2>&1 | sed 's/^/    /'

[[ -f "$BINARY" ]] || die "Compilation failed — see output above."
log "Compilation succeeded."

# ── Assemble .app bundle ───────────────────────────────────────────────────

log "Assembling .app bundle…"

CONTENTS="$BUILD_DIR/${APP_NAME}.app/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

mkdir -p "$MACOS" "$RESOURCES"

cp "$BINARY"   "$MACOS/MacPatchDashboard"
cp "$PATCH_SH" "$RESOURCES/patch.sh"
chmod +x "$MACOS/MacPatchDashboard" "$RESOURCES/patch.sh"

# patch.sh is resolved by the Swift app relative to the .app bundle;
# write a small wrapper so the app can find it regardless of cwd
cat > "$MACOS/patch.sh" <<'EOF'
#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$DIR/../Resources/patch.sh" "$@"
EOF
chmod +x "$MACOS/patch.sh"

# Info.plist
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>             <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>      <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>       <string>com.macpatch.bigsur.dashboard</string>
    <key>CFBundleVersion</key>          <string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleExecutable</key>       <string>MacPatchDashboard</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>LSMinimumSystemVersion</key>   <string>11.0</string>
    <key>NSPrincipalClass</key>         <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>  <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

log "Bundle assembled."

# ── Install ────────────────────────────────────────────────────────────────

if [[ -d "$APP_BUNDLE" ]]; then
    log "Removing existing installation…"
    rm -rf "$APP_BUNDLE"
fi

log "Installing to $APP_BUNDLE…"
cp -R "$BUILD_DIR/${APP_NAME}.app" "$APP_BUNDLE"

# Also install patch.sh globally for convenient CLI use
GLOBAL_PATCH="/usr/local/bin/macpatch"
if [[ -w /usr/local/bin ]]; then
    ln -sf "$APP_BUNDLE/Contents/Resources/patch.sh" "$GLOBAL_PATCH"
    log "CLI shortcut installed: macpatch apply / restore / status"
fi

hr
echo "  Installed: $APP_BUNDLE"
echo ""
echo "  Launch: open -a 'MacPatch Dashboard'"
echo "  Or:     open '$APP_BUNDLE'"
echo ""
echo "  CLI (if /usr/local/bin is writable):"
echo "    sudo macpatch apply"
echo "    sudo macpatch restore"
echo "    sudo macpatch status"
hr
echo ""

read -r -p "  Open the dashboard now? [Y/n] " open_ans
if [[ ! "$open_ans" =~ ^[Nn] ]]; then
    open "$APP_BUNDLE"
fi
