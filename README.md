# NetMenu

[![Latest release](https://img.shields.io/github/v/release/SokolskyNikita/mac-net-monitor-toolbar)](https://github.com/SokolskyNikita/mac-net-monitor-toolbar/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-lightgrey)

A lightweight macOS menu bar app that shows your live **internet latency**, **download rate**, and **upload rate** at a glance.

![NetMenu in the macOS menu bar showing latency and throughput](images/mac-net-monitor-screenshot.png)

NetMenu is built for unreliable networks: hotels, airports, planes, and phone hotspots. It filters out fake low pings from captive portals and in-flight proxies, and checks ordinary HTTPS sites separately so working ping cannot disguise blocked internet access.

## Features

- **Honest latency.** Pings public DNS servers and `google.com` every 3 seconds and ignores replies from the local network path.
- **Connection health.** A 0–100% score next to the latency that checks website access, then combines packet loss, latency stability, and latency level.
- **Captive portal aware.** Shows 0% health when ordinary internet sites are unreachable, even if ping or an allowlisted connectivity endpoint still works.
- **Live throughput.** Download and upload rates from the network interface counters, averaged over 5 seconds, in the menu or optionally in the menu bar.
- **Built-in speed test.** Adaptive Cloudflare-backed transfers work on slow links with an 8 MB payload budget, including retries.
- **Local history.** Writes a per-minute summary to a JSON Lines file you can analyze later.
- **Private by design.** No accounts, no analytics, nothing uploaded.

## Install

Requires macOS 14 (Sonoma) or later on Apple silicon or Intel.

### Homebrew (recommended)

```bash
brew tap SokolskyNikita/netmenu https://github.com/SokolskyNikita/mac-net-monitor-toolbar
brew trust sokolskynikita/netmenu
brew install --cask netmenu
```

Homebrew 7 and later only load casks from third-party taps you've trusted. If you see `Refusing to load cask ... from untrusted tap`, run the `brew trust` line once.

### Manual download

Download `NetMenu-<version>.zip` from the [latest release](https://github.com/SokolskyNikita/mac-net-monitor-toolbar/releases/latest), unzip it, and move `NetMenu.app` to `/Applications`.

### First launch

NetMenu isn't notarized by Apple yet, so macOS may block it the first time you open it. To allow it, go to **System Settings → Privacy & Security** and click **Open Anyway**, or run:

```bash
xattr -dr com.apple.quarantine /Applications/NetMenu.app
```

macOS may also ask for two permissions. Both are optional:

| Permission | Used for | If denied |
| --- | --- | --- |
| Location | Reading the Wi‑Fi network name (SSID and BSSID) | Network name is missing from the stats log |
| Local Network | Pinging your router | Router latency is missing from the stats log |

## Update and uninstall

```bash
# Update (run `brew trust sokolskynikita/netmenu` once first on Homebrew 7+)
brew update && brew upgrade --cask netmenu

# Uninstall
brew uninstall --cask netmenu
rm -rf ~/Library/Application\ Support/NetMenu   # optional: delete stats history
```

## Reading the menu bar

The menu bar shows latency and connection health. Download (`↓`) and upload (`↑`) rates are in the menu; turn on **Show throughput in menu bar** to show them next to the health as well.

| Latency display | Meaning |
| --- | --- |
| `24ms` | Round-trip time measured with ICMP ping |
| `~180ms` | Approximate: ping is blocked, so this is the time for an HTTPS request to Cloudflare |
| `✕` | No trustworthy latency reading: no usable ping or HTTPS fallback answered in the last 60 seconds |

The number is the median of the last five measurements, so a single spike won't make it jump.

Click the icon to see the health breakdown, current and peak rates, run a speed test, or open the stats file. **Peak this connection** resets whenever NetMenu detects a network change, including switching Wi‑Fi networks or access points.

### Connection health

The percentage next to the latency first checks ordinary internet access. Each probe cycle fetches `https://example.com/` and `https://www.google.com/robots.txt` in parallel, requiring a successful HTTPS response with the expected content from at least one site. Redirects, login pages, DNS resolution, and TCP/TLS handshakes do not count. Requests bypass caches and have an 8-second timeout. If neither site passes, health shows **0%** as soon as the cycle completes, even while ping continues to show a valid latency or displays `✕`. The menu explains **internet sites unreachable**. A working Apple captive check or Cloudflare trace alone cannot establish internet access. This is a two-site reachability check, not a guarantee that every website works.

When website access works, health rates the last minute of probes. It's averaged over 10 seconds and changes at most once every 10 seconds. For the first three probe cycles a spinner shows in its place while it calibrates. Website failure bypasses calibration and smoothing; verified recovery restores normal scoring without averaging in the forced zero.

A connection that meets Zoom's [recommended limits](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0070504) for HD video (latency up to 150ms, jitter up to 40ms, packet loss up to 2%) scores 100%. Past those limits, three things lower the score, and their effects multiply, so one bad factor is enough to pull it down:

| Factor | Measured as | Example effect |
| --- | --- | --- |
| Packet loss | Share of pings lost, counting only targets that answered at least once in the window | 5% loss costs about 32%, 10% about 67% |
| Instability (jitter) | Average change between consecutive measurements, ignoring the largest 10%, scaled relative to median latency above 200ms | Flipping between 15ms and 100ms costs about 60%; between 600ms and 700ms adds no jitter penalty; a single spike costs nothing |
| High latency | Median latency | 300ms costs about 11%, 600ms about 44%, and it never costs more than 70% |

A server that never answers pings on your network doesn't count as packet loss. When every ping is blocked and NetMenu falls back to HTTPS, a probe cycle that got no answer counts as lost.

Jitter scoring uses `effective jitter = measured jitter / max(1, median latency / 200ms)`, then applies the existing penalty curve (40ms free, with a gradual increase beyond that). This preserves sensitivity on fast links while allowing variation up to **20% of median latency** on slow links. Both the allowance and penalty ramp scale together, so larger relative swings still hurt. The menu continues to report actual jitter in milliseconds. For example, alternating between 600ms and 700ms scores the same as a steady 650ms link: about **53%** with no packet loss and working website access, versus about 17% under the old jitter rule. This is a connection-stability heuristic; high latency still carries its own penalty.

## How latency is measured

Every 3 seconds, NetMenu runs these checks in parallel:

1. It pings `1.1.1.1`, `1.0.0.1`, `8.8.8.8`, `9.9.9.9`, and `google.com`.
2. It checks Apple's captive portal page (`captive.apple.com`), the same one macOS uses to show Wi‑Fi login screens.
3. It checks the ordinary HTTPS sites described above for connection health.
4. It pings your router, when it has permission.

It then decides what to show:

- **Real ping replies arrived:** the fastest one. Replies that come from within a few network hops, or about as fast as your router, are discarded because the local network sent them, not the destination.
- **No usable ping:** unless a login page was detected, the time to fetch a Cloudflare trace page over HTTPS. NetMenu checks the page contents, so a proxy can't fake the answer.
- **Ping works but websites do not:** keep the ping reading and show 0% health.
- **Nothing trustworthy:** no latency number. A bare TCP or TLS connection time is never shown, because in-flight and hotel proxies answer those locally in a few milliseconds.

## Stats log

Once a minute, NetMenu appends one JSON object per line to:

```text
~/Library/Application Support/NetMenu/stats.jsonl
```

Open it from the menu with **Reveal stats file**. The main fields are:

| Field | Description |
| --- | --- |
| `ts` | Timestamp (ISO 8601, UTC) |
| `type`, `network` | Connection type (`wifi`, `ethernet`, `tether`, `vpn`, `offline`) and network name |
| `lat_ms`, `lat_min`, `lat_max` | Median, minimum, and maximum latency for the minute |
| `lat_src` | How latency was measured: `icmp` or `http` (older entries may also contain `tcp` or `tls`) |
| `gw_ms` | Median router latency |
| `loss` | Fraction of probes that failed or were rejected |
| `health` | Connection health score (0–100) at the end of the minute, or `null` if not enough fresh data; forced to 0 when internet checks fail |
| `internet_reachable` | Whether at least one ordinary HTTPS site passed in the latest probe cycle |
| `internet_checks` | Latest per-site results for `example.com` and `www.google.com` |
| `captive` | Whether Apple’s captive check detected a login page in the latest cycle |
| `down_Bps`, `up_Bps` | Average throughput in bytes per second |
| `rssi`, `noise`, `channel`, `tx_rate_mbps` | Wi‑Fi signal details |

Speed test results, including failures, are logged as separate entries with `"event": "speedtest"`. They include `status` (`ok`, `partial`, or `failed`), fractional `down_mbps` and `up_mbps` (or `null`), per-direction `errors`, completed `down_bytes` / `up_bytes`, and `bytes_reserved` (the conservative payload allowance consumed by all attempts, including failed attempts).

### Speed tests on slow connections

Each direction starts with 32 KB, then adjusts transfer sizes to aim for three seconds per request. There is no mandatory large warm-up download. Sampling normally ends after about 20 seconds per direction or after 4 MB downloaded / 1.5 MB uploaded; a direction has a 45-second deadline. Transient failures get up to two retries with smaller payloads. All attempts share an 8 MB payload budget; protocol overhead is additional.

If one direction fails, any usable result from the other is retained as a **Partial test**. Completed chunks from an interrupted phase also remain usable, with failed-attempt time included to avoid inflating the rate. Slow speeds are shown with decimals. The menu reports the failing direction and reason, such as **upload: timed out**. Failed or partial tests can be retried after 15 seconds; successful tests retain a 60-second cooldown. Tests stop when a network change is detected.

## Building from source

Requires the Xcode Command Line Tools (`xcode-select --install`). The full Xcode app isn't needed.

```bash
git clone https://github.com/SokolskyNikita/mac-net-monitor-toolbar.git
cd mac-net-monitor-toolbar
make run
```

| Command | What it does |
| --- | --- |
| `make run` | Build, bundle, sign ad hoc, and open `NetMenu.app` |
| `make test` | Run the unit tests in `Tests/NetMenuTests` (Swift Testing) |
| `make check` | Print a single measurement as JSON |
| `make build` | Build the universal binary only, to `build/NetMenu` |
| `make dist` | Package a release zip into `dist/` |
| `make clean` | Remove build output |

To take one measurement without the menu bar UI or any permission prompts, run:

```bash
./build/NetMenu --sample
```

### Code signing

By default, builds are signed ad hoc (`SIGN_ID=-`). macOS ties permission grants to the signature, so every rebuild asks for Location and Local Network again. To avoid that, create a stable local signing identity:

1. Open **Keychain Access → Certificate Assistant → Create a Certificate**.
2. Name it `netmenu-selfsign` and set the type to **Code Signing**.
3. Build with it:

   ```bash
   make app SIGN_ID=netmenu-selfsign && open NetMenu.app
   ```

For Developer ID signing, notarization, and publishing releases, see [RELEASING.md](RELEASING.md).

## Privacy

Everything NetMenu records stays in the stats file on your Mac. It sends only the network probes described above, plus the speed test when you start it. Location access is used only to read the Wi‑Fi network name, and Local Network access only to ping your router.

## License

NetMenu is released under the [MIT License](LICENSE).
