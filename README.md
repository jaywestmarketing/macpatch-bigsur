# macpatch-bigsur

Spoof the macOS version on **Big Sur (11.x)** to report as **Monterey (12+)** or higher, so software with a minimum-version gate of 12+ will launch on older hardware.

## How it works

macOS apps check `sw_vers` and `/System/Library/CoreServices/SystemVersion.plist` to determine the OS version. `patch.sh` rewrites that plist with the version you choose, tricks version-gated apps into believing they are running on a newer OS, then provides a one-command restore to undo the change.

> **This does not add missing OS features or APIs.** It only bypasses the version check. Apps that require a newer API (e.g. a Metal shader only in 12+) may still crash after bypassing the gate.

---

## Prerequisites

| Requirement | Why |
|---|---|
| macOS 11 Big Sur | Target OS |
| SIP disabled | `SystemVersion.plist` is in a SIP-protected path |
| `sudo` / root | Writing to `/System/Library/CoreServices/` |

### Disable SIP

1. Shut down the Mac.
2. Boot to Recovery (Apple Silicon: hold power; Intel: hold ⌘R).
3. Open Terminal from the Utilities menu.
4. Run `csrutil disable` and reboot.

---

## Usage

```bash
# Clone
git clone https://github.com/jaywestmarketing/macpatch-bigsur.git
cd macpatch-bigsur
chmod +x patch.sh

# Spoof to Monterey 12.6.9 (default)
sudo ./patch.sh apply

# Spoof to a specific version/build
sudo ./patch.sh apply 13.6.9 22G931   # Ventura

# Check current state
sudo ./patch.sh status

# Undo — always restore before running a system update
sudo ./patch.sh restore
```

---

## Build string reference

### macOS 12 Monterey

| Version | Build |
|---|---|
| 12.0 | 21A559 |
| 12.3 | 21E230 |
| 12.6 | 21G115 |
| 12.6.9 | 21G931 |
| 12.7.6 | 21H1320 |

### macOS 13 Ventura

| Version | Build |
|---|---|
| 13.0 | 22A380 |
| 13.5 | 22G74 |
| 13.6.9 | 22G931 |
| 13.7.6 | 22H625 |

---

## Known limitations

- **Kernel version (`uname -r`) is not spoofed.** A small number of apps check this directly instead of `sw_vers`. Spoofing `uname` would require a kernel extension, which is out of scope here.
- **Metal/API availability is not spoofed.** Newer graphics APIs physically don't exist in Big Sur; bypassing the version gate won't add them.
- **Apple silicon vs Intel.** Tested on both. The plist path is the same on both architectures.
- **Restore before updates.** Running a macOS update with the plist patched may confuse the installer. Always run `sudo ./patch.sh restore` first.

---

## Reverting

```bash
sudo ./patch.sh restore
```

The original plist is backed up to `/System/Library/CoreServices/SystemVersion.plist.bigsur-backup` and is restored verbatim.

---

## Legal / disclaimer

Patching system files is unsupported by Apple. Use at your own risk. This tool is provided for educational purposes and legitimate compatibility testing on hardware you own.
