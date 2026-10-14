# NetMenu

[![Latest release](https://img.shields.io/github/v/release/SokolskyNikita/mac-net-monitor-toolbar)](https://github.com/SokolskyNikita/mac-net-monitor-toolbar/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-lightgrey)

A macOS menu bar app that shows live internet latency, connection health, throughput and top bandwidth users, with a speed test and a per-minute history log.

NetMenu is built for unreliable networks such as hotels, airports, planes and phone hotspots. It filters suspected local ping replies from captive portals and in-flight proxies. It also checks that ordinary websites load, since ping can work while web access is blocked. There are no accounts or analytics; monitoring history and app-usage details stay on your Mac. Network requests are limited to its probes, supporting DNS lookups and the speed tests you start.

<img src="docs/images/mac-net-monitor-screenshot.png" alt="NetMenu menu showing latency, connection health, throughput and top bandwidth apps" width="395">

## Install

Requires macOS 14 (Sonoma) or later on Apple silicon or Intel.

### Homebrew (recommended)

```bash
brew tap SokolskyNikita/netmenu https://github.com/SokolskyNikita/mac-net-monitor-toolbar
brew trust sokolskynikita/netmenu
brew install --cask netmenu
```

The [`brew trust` command](https://docs.brew.sh/Manpage) allows Homebrew to load this third-party tap. Run it if installation or upgrading reports `Refusing to load cask ... from untrusted tap`. Older Homebrew versions without this command can skip it.

```bash
brew update && brew upgrade --cask netmenu      # update
brew uninstall --cask netmenu                   # uninstall
rm -rf ~/Library/Application\ Support/NetMenu   # optional: delete stats history
rm -rf ~/Library/Logs/NetMenu                   # optional: delete diagnostic logs
```

### Manual download

Download `NetMenu-<version>.zip` from the [latest release](https://github.com/SokolskyNikita/mac-net-monitor-toolbar/releases/latest), unzip it and move `NetMenu.app` to `/Applications`.

### First launch

Builds are signed ad hoc unless a release is configured with an Apple Developer ID certificate. If your downloaded build isn't notarized, macOS may block it the first time you open it. Click **Open Anyway** in **System Settings → Privacy & Security**, or run:

```bash
xattr -dr com.apple.quarantine /Applications/NetMenu.app
```

macOS may also ask for two optional permissions:

| Permission | Used only for | If denied |
| --- | --- | --- |
| Location | Reading the Wi‑Fi network name and access point (SSID/BSSID) | The log may use a generic network label and omit the access point |
| Local Network (macOS 15+) | Checking your router’s health and latency | Local router health and latency may be unavailable |

## What you see

The menu bar shows **latency** and **connection health**, for example `9ms │ 100%`.

| Latency | Meaning |
| --- | --- |
| `24ms` | Median of the latest five successful ping rounds, using the fastest trusted target in each round. Suspected local replies from hotel or in-flight equipment are ignored. |
| `~180ms` | Ping is blocked on this network, so this is the time to load a small web page instead. |
| `✕` | No trustworthy latency measurement is available yet, or the last one is over a minute old. |

**Connection health** estimates interactive usability over the last minute, with newer measurements weighted more heavily (a 15-second half-life). It combines latency and jitter into an estimated delay budget, then applies a packet-loss penalty. For example, 20ms latency with 50ms jitter and no loss scores 100%; 5% loss on that connection scores 50%. This is a network-health heuristic, not a measured Zoom call-quality rating. A spinner shows for the first few seconds while it calibrates. A confirmed website outage drops health to **0%** and the menu says **internet sites unreachable**, even if ping still works.

The menu adds:

- **Internet health** with its probe type, loss, jitter and round-trip time (RTT)
- A brief menu-bar warning for recent loss, latency spikes, jitter or web-access failures
- **N reconnects in past 5 mins**, shown after at least three completed reconnects
- **Local router** health, with the same score and packet loss, plus jitter and RTT rounded to the nearest millisecond. Supports IPv4 and IPv6 routers behind a VPN. If ping fails, it can use direct DNS, TCP or IPv4 DHCP INFORM replies instead. The row names the protocol; a router that answers none shows unavailable.
- **Traffic**: current download and upload rate, averaged over 5 seconds. Turn on **Options → Show throughput in menu bar** to show it next to health too.
- **Top apps**: the apps using the most bandwidth over the last 10 seconds, up to three, with their share of all traffic, such as `Top apps (~81%): Firefox`
- **Peak**: the highest rates since you joined this network. It resets when NetMenu detects a change of network or access point.
- **Speed test** results and controls
- **Wi-Fi scans**: a warning when repeated scans from the Wi-Fi settings page overlap slow router pings. **Quit System Settings to stop scans** quits the entire Settings app when clicked; Wi-Fi stays connected. Detection depends on readable macOS Wi-Fi logs. See [Wi-Fi scan warnings](docs/HOW-IT-WORKS.md#wi-fi-scan-warnings) for its limits.

For exactly how each number is measured, see [How NetMenu works](docs/HOW-IT-WORKS.md).

## Speed test

Click **Run speed test** in the menu, and **Cancel speed test** to stop it. Clicking either keeps the menu open so you can watch progress and see the result; click outside or press Escape to dismiss it. The result row is hidden until a test starts; completed results stay visible for five minutes. It tests download and upload against Cloudflare and takes from about 5 seconds on fast connections to about 30 on slow ones. The result looks like **Last test: 268↓ / 41↑ Mbps · 9ms, 38ms loaded**: download and upload speed, latency when idle, and latency while the connection is busy. A big jump under load means a busy connection will make calls and games lag.

It uses as little data as it can:

| Network | Data used |
| --- | --- |
| Most connections | Up to 32 MB |
| Very fast connections (150 Mbps and up) | Up to 64 MB, since 32 MB lasts under two seconds there |
| Low Data Mode, or a metered network such as an iPhone hotspot | Up to 8 MB |

A result with `≥`, such as **≥480↓**, means the connection was still speeding up when the data allowance ran out, so the real speed is at least that.

## Your data

- **Stats history.** Once a minute NetMenu records latency, health, throughput and Wi‑Fi details to a file on your Mac, plus every speed test. Open it with **Diagnostics → Open stats file**. It's capped at 100 MB.
- **Diagnostic log.** A detailed log for troubleshooting, rotating at 10 MB with two older files retained. Open it with **Diagnostics → Open diagnostic log**. If NetMenu shows something that doesn't look right, this log has the details to explain it.

Both stay on your Mac. Formats are described in [Logs](docs/LOGS.md).

## More

- [How NetMenu works](docs/HOW-IT-WORKS.md): probes, health scoring, top apps, speed test, reliability
- [Logs](docs/LOGS.md): stats file fields and the diagnostic log
- [Development](docs/DEVELOPMENT.md): building from source, tests, project layout, code signing
- [Releasing](docs/RELEASING.md)

## License

NetMenu is released under the [MIT License](LICENSE).
