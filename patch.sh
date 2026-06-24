#!/usr/bin/env bash
# MacPatch BigSur — spoof macOS version so software requiring 12+ runs on 11.x
# Must be run as root. Tested on macOS 11.0–11.7.
set -euo pipefail

TARGET_VERSION="${1:-12.0}"      # version to report (default: Monterey 12.0)
TARGET_BUILD="${2:-21A559}"      # matching build string
PLIST="/System/Library/CoreServices/SystemVersion.plist"
BACKUP="/System/Library/CoreServices/SystemVersion.plist.bigsur-backup"
RESTORE_MARKER="/var/db/.macpatch-bigsur-active"

# ── helpers ──────────────────────────────────────────────────────────────────

log()  { echo "[macpatch] $*"; }
die()  { echo "[macpatch] ERROR: $*" >&2; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || die "Run with sudo: sudo $0 $*"
}

require_bigsur() {
    local real_ver
    real_ver=$(sw_vers -productVersion 2>/dev/null || true)
    # Allow running if backup already exists (already patched) or on 11.x
    if [[ -f "$BACKUP" ]]; then
        return 0
    fi
    [[ "$real_ver" == 11.* ]] || die "This tool is intended for macOS 11 (Big Sur). Detected: $real_ver"
}

csrutil_check() {
    local status
    status=$(csrutil status 2>/dev/null || true)
    if echo "$status" | grep -q "enabled"; then
        die "System Integrity Protection is enabled. Boot to Recovery and run: csrutil disable"
    fi
}

remount_rw() {
    log "Remounting / read-write..."
    mount -uw / 2>/dev/null || die "Could not remount / read-write. Is SIP disabled?"
}

# ── commands ─────────────────────────────────────────────────────────────────

cmd_apply() {
    require_root
    csrutil_check
    require_bigsur

    if [[ -f "$RESTORE_MARKER" ]]; then
        log "Patch already active. Run '$0 restore' first to re-apply with different version."
        exit 0
    fi

    log "Backing up $PLIST → $BACKUP"
    remount_rw
    cp -p "$PLIST" "$BACKUP"

    log "Patching: macOS $TARGET_VERSION ($TARGET_BUILD)"
    /usr/libexec/PlistBuddy -c "Set :ProductVersion $TARGET_VERSION"   "$PLIST"
    /usr/libexec/PlistBuddy -c "Set :ProductBuildVersion $TARGET_BUILD" "$PLIST"
    # ProductName stays "macOS" on 12+; strip "Big Sur" style suffix
    /usr/libexec/PlistBuddy -c "Set :ProductName macOS" "$PLIST" 2>/dev/null || true
    # ProductUserVisibleVersion should match
    /usr/libexec/PlistBuddy -c "Set :ProductUserVisibleVersion $TARGET_VERSION" "$PLIST" 2>/dev/null || true

    echo "$TARGET_VERSION $TARGET_BUILD" > "$RESTORE_MARKER"

    log "Flushing dyld shared cache version caches..."
    touch /System/Library/CoreServices/SystemVersion.plist 2>/dev/null || true

    log "Done. sw_vers now reports:"
    sw_vers
    log ""
    log "IMPORTANT:"
    log "  • Some apps also check kernel version (uname -r) — this patch does not spoof that."
    log "  • Run '$0 restore' before any system update."
    log "  • Reboot recommended for all processes to pick up the new value."
}

cmd_restore() {
    require_root
    csrutil_check

    if [[ ! -f "$BACKUP" ]]; then
        die "No backup found at $BACKUP — nothing to restore."
    fi

    remount_rw
    log "Restoring $BACKUP → $PLIST"
    cp -p "$BACKUP" "$PLIST"
    rm -f "$BACKUP" "$RESTORE_MARKER"

    log "Restored. sw_vers now reports:"
    sw_vers
}

cmd_status() {
    if [[ -f "$RESTORE_MARKER" ]]; then
        read -r patched_ver patched_build < "$RESTORE_MARKER"
        echo "[macpatch] ACTIVE — spoofed to $patched_ver ($patched_build)"
        echo "[macpatch] Backup: $BACKUP"
    else
        echo "[macpatch] NOT active"
    fi
    echo "[macpatch] Current sw_vers:"
    sw_vers
}

cmd_help() {
    cat <<EOF
Usage: sudo $0 <command> [TARGET_VERSION] [TARGET_BUILD]

Commands:
  apply   [version] [build]   Patch SystemVersion.plist (default: $TARGET_VERSION $TARGET_BUILD)
  restore                     Undo patch, restore original plist
  status                      Show current patch state

Examples:
  sudo $0 apply                       # spoof to macOS 12.0 (Monterey)
  sudo $0 apply 13.6.9 22G931        # spoof to Ventura 13.6.9
  sudo $0 restore

Prerequisites:
  • macOS 11 Big Sur
  • SIP disabled (boot Recovery → Utilities → Terminal → csrutil disable)
  • Run as root (sudo)

Common macOS 12 Monterey build strings:
  12.0   21A559
  12.6   21G115
  12.6.9 21G931
  12.7.6 21H1320

Common macOS 13 Ventura build strings:
  13.0   22A380
  13.6.9 22G931
  13.7.6 22H625
EOF
}

# ── dispatch ─────────────────────────────────────────────────────────────────

COMMAND="${1:-help}"
shift || true

case "$COMMAND" in
    apply)   cmd_apply   ;;
    restore) cmd_restore ;;
    status)  cmd_status  ;;
    help|--help|-h) cmd_help ;;
    *)
        echo "Unknown command: $COMMAND"
        cmd_help
        exit 1
        ;;
esac
