#!/usr/bin/env bash
# patch-app.sh — patch or restore a single .app bundle's LSMinimumSystemVersion
# Usage: patch-app.sh apply|restore /Applications/SomeApp.app
# Does NOT require SIP disabled. Re-signs with ad-hoc signature after patching.
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

ACTION="${1:-}"
APP="${2:-}"

[[ "$ACTION" == "apply" || "$ACTION" == "restore" ]] \
    || die "Usage: $0 apply|restore /path/to/App.app"
[[ -d "$APP" ]] || die "Not a directory: $APP"

PLIST="$APP/Contents/Info.plist"
BACKUP="$PLIST.macpatch-backup"

[[ -f "$PLIST" ]] || die "Info.plist not found: $PLIST"

if [[ "$ACTION" == "apply" ]]; then
    [[ -f "$BACKUP" ]] && { echo "Already patched: $APP"; exit 0; }

    # Backup original plist
    cp -p "$PLIST" "$BACKUP"

    # Lower minimum system version to 11.0
    /usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 11.0" "$PLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 11.0" "$PLIST"

    # Ad-hoc re-sign (required after modifying a signed bundle; no cert needed)
    if command -v codesign &>/dev/null; then
        codesign --force --deep --sign - "$APP" 2>/dev/null || true
    fi

    echo "Patched: $APP"

elif [[ "$ACTION" == "restore" ]]; then
    [[ -f "$BACKUP" ]] || { echo "No backup found, nothing to restore: $APP"; exit 0; }

    cp -p "$BACKUP" "$PLIST"
    rm -f "$BACKUP"

    # Re-sign with original signature info (ad-hoc, since we can't restore original cert)
    if command -v codesign &>/dev/null; then
        codesign --force --deep --sign - "$APP" 2>/dev/null || true
    fi

    echo "Restored: $APP"
fi
