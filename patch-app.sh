#!/usr/bin/env bash
# patch-app.sh — patch or restore a single .app bundle's LSMinimumSystemVersion
# Usage: patch-app.sh apply|restore /Applications/SomeApp.app [plugin.mplugin]
# Does NOT require SIP disabled. Re-signs with ad-hoc signature after patching.
#
# If a plugin file is passed on `apply`, the CPU/RAM/arch gate MUST pass first.
# This is a hard, fail-closed enforcement point independent of any UI: if the
# gate cannot verify the hardware, the patch is refused.
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

ACTION="${1:-}"
APP="${2:-}"
PLUGIN="${3:-}"

[[ "$ACTION" == "apply" || "$ACTION" == "restore" ]] \
    || die "Usage: $0 apply|restore /path/to/App.app [plugin.mplugin]"

SELF_DIR="$(dirname "${BASH_SOURCE[0]}")"

# Read a value from the plugin's requirements/top-level without jq
plug_val() {
    local file="$1" path="$2"
    /usr/bin/python3 - "$file" "$path" <<'PY' 2>/dev/null || echo ""
import json,sys
try:
    d=json.load(open(sys.argv[1])); cur=d
    for k in sys.argv[2].split('.'):
        cur=cur.get(k,{})
    print(cur if isinstance(cur,str) else "")
except Exception:
    print("")
PY
}

if [[ "$ACTION" == "apply" ]]; then
    # Hard CPU/RAM/arch gate BEFORE anything else (download or patch). Fail-closed.
    if [[ -n "$PLUGIN" ]]; then
        PROBE="$SELF_DIR/probe.sh"
        [[ -x "$PROBE" ]] || die "probe.sh not found next to patch-app.sh; cannot verify hardware"
        if ! "$PROBE" gate "$PLUGIN"; then
            die "Hardware gate failed — CPU/RAM/architecture requirements not met. Patch refused."
        fi
    fi

    # If the app isn't installed yet, download it first (handles the
    # "app won't download on Big Sur" case by fetching the .app directly).
    if [[ ! -d "$APP" ]]; then
        DL_URL=""
        [[ -n "$PLUGIN" ]] && DL_URL="$(plug_val "$PLUGIN" download_url)"
        [[ -n "$DL_URL" ]] || die "App not installed and no download_url in plugin: $APP"
        FETCH="$SELF_DIR/fetch-app.sh"
        [[ -x "$FETCH" ]] || die "fetch-app.sh not found; cannot download the app"
        APP_BASENAME="$(basename "$APP")"
        echo "App not found — downloading $APP_BASENAME..."
        "$FETCH" "$DL_URL" "$APP_BASENAME" || die "Download/install failed"
    fi

    PLIST="$APP/Contents/Info.plist"
    BACKUP="$PLIST.macpatch-backup"
    [[ -f "$PLIST" ]] || die "Info.plist not found after install: $PLIST"
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
    [[ -d "$APP" ]] || die "Not a directory: $APP"
    PLIST="$APP/Contents/Info.plist"
    BACKUP="$PLIST.macpatch-backup"
    [[ -f "$BACKUP" ]] || { echo "No backup found, nothing to restore: $APP"; exit 0; }

    cp -p "$BACKUP" "$PLIST"
    rm -f "$BACKUP"

    # Re-sign with original signature info (ad-hoc, since we can't restore original cert)
    if command -v codesign &>/dev/null; then
        codesign --force --deep --sign - "$APP" 2>/dev/null || true
    fi

    echo "Restored: $APP"
fi
