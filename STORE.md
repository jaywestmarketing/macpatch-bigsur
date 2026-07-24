# MacPatch Store — verified compatibility patches

The store model sells **patches as plugins**, and every patch is **verified against the
buyer's actual hardware before purchase**. No blind sales, no refunds for "it launched
but doesn't work."

## How verification-before-purchase works

```
 Buyer clicks a patch in the Store
            |
            v
 probe.sh verify <plugin>   <-- runs on THEIR machine
            |
            v
   Reads real hardware:            Reads plugin requirements:
   - macOS version                 - min RAM
   - Intel / Apple Silicon         - required arch
   - RAM                           - Metal generation needed
   - Metal GPU + generation        - runtime risk
   - free disk
            |
            v
   Verdict:  GREEN / YELLOW / RED   +  plain-English reasons
            |
            v
   GREEN/YELLOW -> "Buy & Patch" enabled
   RED          -> purchase blocked, reasons shown
```

## CPU / RAM gate — fail-closed, enforced twice

CPU cores, RAM, and architecture are checked as a **hard gate** with no room for a
false pass:

- **Deterministic source.** Values come from `sysctl` (`hw.memsize`, `hw.physicalcpu`,
  `uname -m`) — the same values the OS itself reports. These are not estimates.
- **Fail-closed.** If any value cannot be read with certainty, the gate returns a
  sentinel `-1` and **blocks**. There is no code path that treats an unreadable
  CPU/RAM value as a pass.
- **Enforced in two places.** The dashboard checks before purchase, and
  `patch-app.sh` calls `probe.sh gate` again at install time. Even if the UI were
  bypassed, the patch script itself refuses to modify an app whose CPU/RAM gate fails.

```bash
./probe.sh gate plugins/lmstudio.mplugin
#   BLOCK: needs 16 GB RAM, have 8 GB
#   BLOCK: needs 8 cores, have 4
#   exit code 2  -> install refused
```

What this gate **can** guarantee 100%: the machine meets (or fails) the declared
CPU/RAM/arch numbers. What no tool can guarantee 100%: that an app with met specs will
behave perfectly at runtime — which is why GPU/OS-feature concerns are surfaced
separately as YELLOW warnings rather than folded into the hard gate.

## Verdict meanings

| Verdict | Meaning | Purchase |
|---|---|---|
| 🟢 **GREEN** | Will run fully. Electron/web apps with no native macOS 12 dependency. | Allowed |
| 🟡 **YELLOW** | Launches; some newer-OS/GPU features may not work. | Allowed, with disclosure |
| 🔴 **RED** | A hard requirement (RAM, arch, no Metal GPU) is unmet. | Blocked |

This protects you (the seller) from refunds and builds trust — you're selling honesty.

## Plugin format (`.mplugin`)

A plugin is JSON describing the app, how to patch it, and its real requirements:

```json
{
  "id": "claude",
  "name": "Claude",
  "vendor": "Anthropic",
  "category": "AI Assistant",
  "app_path": "/Applications/Claude.app",
  "patch": { "type": "min_system_version", "set_version": "11.0" },
  "requirements": {
    "min_os_major": 11,
    "arch": "any",                 // any | apple_silicon | intel
    "min_ram_gb": 4,
    "min_disk_gb": 1,
    "requires_metal": false,
    "min_metal_generation": 0,     // Big Sur tops out at Metal 2
    "runtime_risk": "full"         // full | partial | launch_only
  }
}
```

## Launch lineup (AI-focused, matches Stable Diffusion / local-LLM users)

| Plugin | Category | Verdict on typical Big Sur Intel Mac |
|---|---|---|
| **Claude** | AI Assistant | 🟢 Full — Electron, no native dependency |
| **Ollama** | Local LLM | 🟡 Partial — Metal 2 OK for small models |
| **Pinokio** | AI Launcher | 🟡 Partial — launcher runs; installed apps vary |
| **Upscayl** | Image Tools | 🟡 Partial — works, slower on old GPU |
| **LM Studio** | Local LLM | 🔴 Blocked — needs 16GB RAM + Metal 3 |

The RED verdict on LM Studio is the system working correctly: it stops a buyer from
purchasing something their hardware genuinely can't run.

## Testing the probe

```bash
# See this machine's capabilities
./probe.sh machine

# Verify a specific plugin against this machine
./probe.sh verify plugins/claude.mplugin
./probe.sh verify plugins/lmstudio.mplugin
```

## Distribution (one-tap install)

```bash
./build-dmg.sh          # produces dist/MacPatch.dmg
```

The DMG bundles the dashboard, `patch-app.sh`, `probe.sh`, and all plugins. Users
open it, drag to Applications, and launch — no Terminal, no compile.

## Auto-start at login

```bash
./enable-startup.sh          # opens dashboard automatically at login
./enable-startup.sh disable  # turn it off
```

## Honest hardware caveat (say this to buyers)

The patch bypasses the **software version gate** only. It cannot add macOS APIs that
don't exist on Big Sur, and it cannot change your GPU or CPU. That is exactly why every
patch is verified against real hardware before purchase — so a GREEN badge means it will
actually work, not just install.
