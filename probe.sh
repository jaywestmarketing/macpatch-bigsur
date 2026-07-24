#!/usr/bin/env bash
# probe.sh - hardware + OS compatibility probe for MacPatch
# Emits a JSON report of this machine's capabilities so the dashboard can
# decide, BEFORE purchase, whether a given app will actually run.
#
# Usage: probe.sh            -> prints machine capability JSON
#        probe.sh verify FILE -> compares machine against a .mplugin file,
#                                prints verdict JSON {verdict, reasons[]}
set -euo pipefail

# ---- Gather machine facts ---------------------------------------------------

OS_VER="$(sw_vers -productVersion 2>/dev/null || echo 0)"
OS_MAJOR="${OS_VER%%.*}"

ARCH="$(uname -m)"                       # arm64 (Apple Silicon) or x86_64 (Intel)
if [[ "$ARCH" == "arm64" ]]; then
    CHIP_KIND="apple_silicon"
else
    CHIP_KIND="intel"
fi

# RAM in GB (rounded)
RAM_BYTES="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
RAM_GB=$(( RAM_BYTES / 1073741824 ))

# CPU model string
CPU_MODEL="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"

# GPU / Metal support. Metal 3 requires macOS 13+, so on Big Sur the max is Metal 2.
# We detect whether a Metal-capable GPU is present and its family via system_profiler.
GPU_NAME="$(system_profiler SPDisplaysDataType 2>/dev/null \
            | awk -F': ' '/Chipset Model/ {print $2; exit}' || echo unknown)"
METAL_SUPPORTED="$(system_profiler SPDisplaysDataType 2>/dev/null \
            | grep -qi 'Metal' && echo true || echo false)"

# Metal generation ceiling: Big Sur tops out at Metal 2 regardless of hardware.
if [[ "$OS_MAJOR" -ge 13 ]]; then
    METAL_MAX=3
elif [[ "$OS_MAJOR" -ge 11 ]]; then
    METAL_MAX=2
else
    METAL_MAX=1
fi

# Free disk in GB on the boot volume
DISK_FREE_GB="$(df -g / 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)"

emit_machine_json() {
    cat <<JSON
{
  "os_version": "$OS_VER",
  "os_major": $OS_MAJOR,
  "arch": "$ARCH",
  "chip_kind": "$CHIP_KIND",
  "cpu_model": "$CPU_MODEL",
  "ram_gb": $RAM_GB,
  "gpu_name": "$GPU_NAME",
  "metal_supported": $METAL_SUPPORTED,
  "metal_max_generation": $METAL_MAX,
  "disk_free_gb": $DISK_FREE_GB
}
JSON
}

# ---- Read a value from a .mplugin JSON without jq ---------------------------
# Very small JSON reader for flat "requirements" keys we control.

plug_get() {
    local file="$1" key="$2"
    /usr/bin/python3 - "$file" "$key" <<'PY' 2>/dev/null || echo ""
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    req = data.get("requirements", {})
    val = req.get(sys.argv[2], "")
    print(val if val is not None else "")
except Exception:
    print("")
PY
}

plug_meta() {
    local file="$1" key="$2"
    /usr/bin/python3 - "$file" "$key" <<'PY' 2>/dev/null || echo ""
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    print(data.get(sys.argv[2], ""))
except Exception:
    print("")
PY
}

# ---- Verify machine against a plugin ----------------------------------------

verify_plugin() {
    local file="$1"
    [[ -f "$file" ]] || { echo '{"verdict":"error","reasons":["Plugin file not found"]}'; exit 1; }

    local name;            name="$(plug_meta "$file" name)"
    local min_ram;         min_ram="$(plug_get "$file" min_ram_gb)"
    local min_metal;       min_metal="$(plug_get "$file" min_metal_generation)"
    local needs_metal;     needs_metal="$(plug_get "$file" requires_metal)"
    local arch_req;        arch_req="$(plug_get "$file" arch)"           # any|apple_silicon|intel
    local min_disk;        min_disk="$(plug_get "$file" min_disk_gb)"
    local risk;            risk="$(plug_get "$file" runtime_risk)"       # full|partial|launch_only

    : "${min_ram:=0}"; : "${min_metal:=0}"; : "${min_disk:=0}"
    : "${needs_metal:=false}"; : "${arch_req:=any}"; : "${risk:=partial}"

    local reasons=()
    local blocking=false
    local warning=false

    # RAM
    if [[ "$RAM_GB" -lt "$min_ram" ]]; then
        reasons+=("Needs ${min_ram} GB RAM, this Mac has ${RAM_GB} GB")
        blocking=true
    fi

    # Architecture
    if [[ "$arch_req" != "any" && "$arch_req" != "$CHIP_KIND" ]]; then
        reasons+=("Requires ${arch_req//_/ } Mac, this is ${CHIP_KIND//_/ }")
        blocking=true
    fi

    # Disk
    if [[ "$DISK_FREE_GB" -lt "$min_disk" ]]; then
        reasons+=("Needs ${min_disk} GB free disk, only ${DISK_FREE_GB} GB available")
        blocking=true
    fi

    # Metal presence
    if [[ "$needs_metal" == "true" && "$METAL_SUPPORTED" != "true" ]]; then
        reasons+=("Requires a Metal-capable GPU; none detected")
        blocking=true
    fi

    # Metal generation ceiling (this is the Big Sur hard limit)
    if [[ "$min_metal" -gt "$METAL_MAX" ]]; then
        reasons+=("App wants Metal ${min_metal}; Big Sur tops out at Metal ${METAL_MAX} (feature will be unavailable)")
        warning=true
    fi

    # Runtime risk declared by the plugin
    case "$risk" in
        launch_only)
            reasons+=("App will launch but GPU/runtime features are likely broken on Big Sur")
            warning=true ;;
        partial)
            reasons+=("App launches; some newer-OS features may not work")
            warning=true ;;
        full)
            : ;;  # no note
    esac

    # Decide verdict
    local verdict
    if [[ "$blocking" == "true" ]]; then
        verdict="red"
    elif [[ "$warning" == "true" ]]; then
        verdict="yellow"
    else
        verdict="green"
    fi

    # Build reasons JSON array
    local reasons_json="["
    local first=true
    for r in "${reasons[@]:-}"; do
        [[ -z "$r" ]] && continue
        if [[ "$first" == true ]]; then first=false; else reasons_json+=","; fi
        # escape quotes
        r_esc="${r//\"/\\\"}"
        reasons_json+="\"$r_esc\""
    done
    reasons_json+="]"

    cat <<JSON
{
  "app": "$name",
  "verdict": "$verdict",
  "reasons": $reasons_json,
  "machine": $(emit_machine_json | tr '\n' ' ')
}
JSON
}

# ---- Dispatch ---------------------------------------------------------------

case "${1:-machine}" in
    machine) emit_machine_json ;;
    verify)  verify_plugin "${2:?Usage: probe.sh verify plugin.mplugin}" ;;
    *) echo "Usage: $0 [machine | verify FILE]"; exit 1 ;;
esac
