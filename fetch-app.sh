#!/usr/bin/env bash
# fetch-app.sh - download an app and install its .app into /Applications,
# then it can be patched. Handles the "app won't download on Big Sur" case by
# fetching the raw .app from a DMG or ZIP directly, bypassing an installer that
# refuses to run on the old OS.
#
# Usage: fetch-app.sh <download_url> <expected_app_name>
#   e.g. fetch-app.sh https://example.com/Claude.dmg "Claude.app"
set -euo pipefail

URL="${1:-}"
APP_NAME="${2:-}"
[[ -n "$URL" && -n "$APP_NAME" ]] || { echo "Usage: $0 <url> <App.app>" >&2; exit 1; }

log() { echo "[fetch] $*"; }
die() { echo "[fetch] ERROR: $*" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; [[ -n "${MOUNT:-}" ]] && hdiutil detach "$MOUNT" -quiet 2>/dev/null || true' EXIT

DEST="/Applications/$APP_NAME"
FILE="$TMP/download"

log "Downloading $URL"
# -L follow redirects, -f fail on HTTP error, --retry for flaky networks
curl -fL --retry 3 --retry-delay 2 -o "$FILE" "$URL" \
    || die "Download failed. Check the URL or your connection."

# Detect file type
KIND="$(file -b "$FILE" 2>/dev/null || echo unknown)"
log "Downloaded ($KIND)"

install_from_dir() {
    local src_dir="$1"
    local found
    found="$(find "$src_dir" -maxdepth 3 -name "$APP_NAME" -type d 2>/dev/null | head -1)"
    [[ -n "$found" ]] || die "Could not find $APP_NAME inside the download"
    log "Installing $found -> $DEST"
    rm -rf "$DEST"
    ditto "$found" "$DEST" || cp -R "$found" "$DEST"
    # Clear quarantine so it opens cleanly
    xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
}

case "$KIND" in
    *"disk image"*|*"UDIF"*|*"DMG"*)
        log "Mounting disk image..."
        MOUNT="$(hdiutil attach "$FILE" -nobrowse -noverify -readonly \
                 | grep -o '/Volumes/[^ ]*' | tail -1)"
        [[ -n "$MOUNT" ]] || die "Failed to mount DMG"
        install_from_dir "$MOUNT"
        hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
        MOUNT=""
        ;;
    *"Zip archive"*)
        log "Unzipping..."
        unzip -q "$FILE" -d "$TMP/unz" || die "Unzip failed"
        install_from_dir "$TMP/unz"
        ;;
    *)
        # Maybe it's already a .app in a folder, or an unknown container
        die "Unsupported download type: $KIND (expected .dmg or .zip)"
        ;;
esac

[[ -d "$DEST" ]] || die "Install did not produce $DEST"
log "Installed: $DEST"
echo "$DEST"
