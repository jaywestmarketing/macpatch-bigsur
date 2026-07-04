# macpatch-bigsur

Run macOS 12+ apps on **Big Sur (11.x)** without disabling System Integrity Protection.

Instead of touching system files, the patcher lowers `LSMinimumSystemVersion` inside each app's own bundle and re-signs it with an ad-hoc signature. SIP is not required.

---

## Install

```bash
git clone https://github.com/jaywestmarketing/macpatch-bigsur.git
cd macpatch-bigsur
chmod +x install.sh patch-app.sh
./install.sh
```

The installer compiles the SwiftUI dashboard and drops it in  
`/Applications/MacPatch Dashboard.app`. Xcode Command Line Tools are required  
(the installer will prompt to install them if they're missing).

After installation, double-click the app in `/Applications` or run:

```bash
open -a "MacPatch Dashboard"
```

---

## Dashboard

The app opens with a **welcome screen → install progress screen → dashboard**.

| What you see | What it does |
|---|---|
| App list | All apps in /Applications requiring macOS 12 or higher |
| Status badges | Shows which apps are already patched |
| Patch / Restore buttons | One click — prompts for your password via native macOS dialog |
| Change log | Timestamped record of every action this session |
| Rescan button | Re-scans /Applications for new apps |

---

## How it works

For each app you patch:

1. Backs up `App.app/Contents/Info.plist` → `Info.plist.macpatch-backup`
2. Sets `LSMinimumSystemVersion` to `11.0`
3. Ad-hoc re-signs the bundle with `codesign --force --deep --sign -`

To restore, the original `Info.plist` is copied back and the app is re-signed.

No system directories are modified. SIP does not need to be disabled.

---

## CLI (optional)

```bash
# Patch a specific app
sudo ./patch-app.sh apply  /Applications/SomeApp.app

# Restore a specific app
sudo ./patch-app.sh restore /Applications/SomeApp.app
```

---

## Limitations

- **Missing APIs still crash.** Bypassing the version gate doesn't add macOS 12 APIs. Apps that call APIs that literally don't exist in Big Sur will crash after launch.
- **App Store apps** use hardened runtime + notarization checks and cannot be patched this way.
- **Re-signing breaks the original signature.** The app will show as "unsigned" if you check with `codesign -v`. This is expected.
- **Restore before updating an app.** If you update a patched app through its built-in updater or the App Store, the patch is overwritten automatically (which is fine — just re-patch if needed).

---

## Requirements

| Requirement | Notes |
|---|---|
| macOS 11 Big Sur | Target OS |
| Xcode Command Line Tools | Required to compile the dashboard (install.sh will prompt) |
| SIP | **Does not need to be disabled** |

---

## Legal

Modifying app bundles is done on apps you have installed and own a license to use. This tool does not bypass copy protection or license enforcement — only the OS version gate. Use responsibly on your own hardware.
