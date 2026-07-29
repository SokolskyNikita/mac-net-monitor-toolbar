# NetMenu

macOS menu bar app that shows live **WAN latency**, **download**, and **upload** rates.

```
15ms   2K↓   1K↑
```

## Features

- ICMP latency probes to `1.1.1.1` / `8.8.8.8` (TCP connect fallback when ICMP is blocked)
- Interface throughput from `en*` link counters
- Optional gateway ping to separate Wi‑Fi hop latency from internet RTT
- Session peak rates and a Cloudflare-backed speed test (~7 MB)
- Per-minute JSONL samples under `~/Library/Application Support/NetMenu/stats.jsonl`

## Requirements

- macOS (Apple silicon recommended)
- Xcode Command Line Tools (`swiftc`)
- First launch may prompt for **Location** (SSID/BSSID) and **Local Network** (gateway ping). Denying either leaves those fields empty; the rest still works.

## Build and run

```bash
make run          # build, bundle, codesign (ad-hoc), open
make check        # one-shot sample JSON to stdout
make build        # binary only → build/NetMenu
```

Ad-hoc signing (`SIGN_ID=-`) is the default. TCC grants reset when the signature changes. For a stable local identity:

1. Keychain Access → Certificate Assistant → Create a Certificate  
2. Name: `netmenu-selfsign`, type: **Code Signing**  
3. `make app SIGN_ID=netmenu-selfsign && open NetMenu.app`

## Sample mode

```bash
./build/NetMenu --sample
```

Prints a one-line summary plus a JSON sample (no menu bar UI). Uses TCC-free identity resolution (no CoreWLAN / Location).

## Privacy

Stats are written only on disk under Application Support. Nothing is uploaded. Location and Local Network permissions are used only to tag Wi‑Fi identity and measure gateway latency.

## License

MIT — see [LICENSE](LICENSE).
