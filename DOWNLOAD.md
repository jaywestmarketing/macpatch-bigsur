# Download strategy — works on every Mac, every macOS version

Goal: a customer on any Mac (Intel or Apple Silicon) running any macOS from 11 Big Sur
onward can download and open the app with zero friction. No compiling, no Terminal.

## The one rule

**You build the app once. Customers only download.** Never ship a build that compiles on
the customer's machine — that requires Xcode Command Line Tools (multi-GB) and will lose
most customers. `install.sh` (compile-on-device) is for developers only. Customers get the
**DMG** produced by `build-dmg.sh`.

## The four compatibility dimensions

### 1. CPU architecture — Intel vs Apple Silicon

Solved by a **universal binary**. `build-dmg.sh` compiles both `arm64` and `x86_64`
slices and `lipo`s them into one binary, then verifies both are present. One download runs
natively on every Mac.

```bash
lipo -archs "MacPatch Dashboard.app/Contents/MacOS/MacPatchDashboard"
# -> x86_64 arm64
```

### 2. macOS version — 11 through latest

Solved by the **deployment target**. Building with `-target ARCH-apple-macos11.0` means the
app runs on macOS 11 and every newer version. `LSMinimumSystemVersion` = 11.0 in Info.plist
matches. Nothing to do per-version — one build covers them all.

| Customer OS | Runs? |
|---|---|
| macOS 11 Big Sur | ✅ (deployment target) |
| macOS 12 Monterey | ✅ |
| macOS 13 Ventura | ✅ |
| macOS 14 Sonoma | ✅ |
| macOS 15+ | ✅ (forward compatible) |

### 3. Gatekeeper — "unidentified developer" / "app is damaged"

This is the one that costs money to solve fully. Three tiers:

| Tier | Cost | Customer experience |
|---|---|---|
| **Ad-hoc signed** (current) | Free | Right-click → Open, confirm once. Works, slightly scary. |
| **Developer ID signed** | $99/yr Apple Developer | "Open" button, mild warning |
| **Signed + Notarized** | $99/yr | No warning at all — cleanest |

For launch, ad-hoc is fine with clear instructions (below). Notarize once you have revenue.

### 4. Quarantine flag

Any file downloaded from a browser gets `com.apple.quarantine`. Notarization clears it.
Until then, the first-open instructions handle it.

## First-open instructions to ship with every download

> **First time opening MacPatch:**
> 1. Open the DMG, drag **MacPatch Dashboard** to Applications.
> 2. In Applications, **right-click** MacPatch Dashboard → **Open**.
> 3. Click **Open** in the dialog. (Only needed once.)

Right-click-Open bypasses Gatekeeper for unsigned/ad-hoc apps on all macOS versions.

## Detecting the customer's exact setup

The bundled probe reports everything needed for support, read from the real machine:

```bash
./probe.sh machine
# {
#   "os_version": "11.7.11", "os_major": 11,
#   "arch": "x86_64", "chip_kind": "intel",
#   "model_id": "MacBookPro11,3",
#   "cpu_cores": 4, "ram_gb": 16,
#   "metal_max_generation": 2, ...
# }
```

If a customer reports a download problem, `probe.sh machine` output tells you their exact
hardware and OS in one line.

## Build + release checklist

```bash
# On any Mac with Xcode CLT (you, once per release):
./build-dmg.sh            # produces dist/MacPatch.dmg (universal, 11.0+)

# Verify before uploading:
lipo -archs "dist/.../MacPatchDashboard"   # x86_64 arm64
hdiutil verify dist/MacPatch.dmg

# Upload dist/MacPatch.dmg to your store. That single file serves every customer.
```

## Later: automate builds for every release

A GitHub Actions workflow on a macOS runner can build the universal DMG automatically on
each tagged release, so you never build by hand. Ask to add `.github/workflows/release.yml`
when you're ready.
