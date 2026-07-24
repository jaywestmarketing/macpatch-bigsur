# Target devices — Macs stuck on Big Sur

These Mac models are **officially supported up to macOS 11 Big Sur but blocked from
macOS 12 Monterey**. They are the exact machines your store serves: their owners want
newer apps but Apple won't let them upgrade the OS.

> The probe reads the real machine via `sysctl hw.model`, so verdicts are always based
> on actual hardware. This table is a reference for marketing/support, not the gate.

## Big Sur terminal Macs (max OS = 11)

| Model | Identifier | Max RAM | CPU cores | Metal |
|---|---|---|---|---|
| MacBook Air (Mid 2013) | MacBookAir6,1 | 8 GB | 2 | 2 |
| MacBook Air (Early 2014) | MacBookAir6,2 | 8 GB | 2 | 2 |
| MacBook Pro 13" (Late 2013) | MacBookPro11,1 | 16 GB | 2 | 2 |
| MacBook Pro 15" (Late 2013) | MacBookPro11,2/3 | 16 GB | 4 | 2 |
| MacBook Pro (Mid 2014) | MacBookPro11,1–3 | 16 GB | 2–4 | 2 |
| iMac 21.5" (Mid 2014) | iMac14,4 | 16 GB | 2 | 2 |
| iMac 27" (Late 2013) | iMac14,2/3 | 32 GB | 4 | 2 |
| Mac mini (Late 2014) | Macmini7,1 | 16 GB | 2 | 2 |
| Mac Pro (Late 2013) | MacPro6,1 | 64 GB | 4–12 | 2 |

All are Intel, all cap at Metal 2 (the Big Sur ceiling), all 64-bit.

## Which plugins each device class can run

Based on the CPU/RAM gate + Metal ceiling:

| Device class | Claude | Ollama | Pinokio | Upscayl | LM Studio |
|---|---|---|---|---|---|
| 2-core / 8 GB (Air 2013–14, MBP13 2014) | 🟢 | 🔴 cores | 🔴 cores | 🔴 cores | 🔴 |
| 4-core / 16 GB (MBP15, iMac27, Mac Pro) | 🟢 | 🟡 | 🟡 | 🟡 | 🔴 Metal3 |
| 4-core / 8 GB (Mac mini upgraded) | 🟢 | 🟡 | 🟡 | 🟡 | 🔴 |

Key takeaways:
- **Claude runs on every Big Sur Mac** — 2 cores / 4 GB minimum. Your safest, widest product.
- **LM Studio is blocked on all of them** — it wants Metal 3, which no Big Sur Mac has.
  The gate correctly stops these sales.
- The 4-core / 16 GB machines are your best customers for the AI-adjacent apps.

## How to identify a customer's device

```bash
# Model identifier
sysctl -n hw.model            # e.g. MacBookPro11,3

# Full probe (what the store actually uses)
./probe.sh machine
```

The probe returns `cpu_cores`, `ram_gb`, `arch`, and `metal_max_generation` — everything
the gate needs, read directly from the machine rather than inferred from a model list.

## Adding device intelligence to a plugin (optional)

You can add a human-readable `recommended_devices` field to any `.mplugin` for display
in the store, without affecting the gate (which stays hardware-based):

```json
"recommended_devices": [
  "MacBook Pro 15\" (2013–2014)",
  "iMac 27\" (2013)",
  "Mac Pro (2013)"
]
```
