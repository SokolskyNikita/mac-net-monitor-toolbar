# NetMenu

[![Latest release](https://img.shields.io/github/v/release/SokolskyNikita/mac-net-monitor-toolbar)](https://github.com/SokolskyNikita/mac-net-monitor-toolbar/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-lightgrey)

A macOS menu bar app that shows live internet latency, connection health, throughput and top bandwidth users, with a speed test and a per-minute history log.

NetMenu is built for unreliable networks such as hotels, airports, planes and phone hotspots. It discards fake low pings answered by captive portals and in-flight proxies. It also checks that ordinary websites load, since ping can work while web access is blocked. There are no accounts or analytics; apart from its probes and the speed tests you start, nothing leaves your Mac.

<img src="docs/images/mac-net-monitor-screenshot.png" alt="NetMenu menu showing latency, connection health, throughput and top bandwidth apps" width="395">

## Install

Requires macOS 14 (Sonoma) or later on Apple silicon or Intel.

### Homebrew (recommended)

```bash
brew tap SokolskyNikita/netmenu https://github.com/SokolskyNikita/mac-net-monitor-toolbar
brew trust sokolskynikita/netmenu
brew install --cask netmenu
```

The `brew trust` line is required on Homebrew 7 and later, which refuse casks from untrusted third-party taps (`Refusing to load cask ... from untrusted tap`). If you installed NetMenu on an older Homebrew, run that line once before your next upgrade.

```bash
brew update && brew upgrade --cask netmenu      # update
brew uninstall --cask netmenu                   # uninstall
rm -rf ~/Library/Application\ Support/NetMenu   # optional: delete stats history
rm -rf ~/Library/Logs/NetMenu                   # optional: delete diagnostic logs
```

### Manual download

Download `NetMenu-<version>.zip` from the [latest release](https://github.com/SokolskyNikita/mac-net-monitor-toolbar/releases/latest), unzip it and move `NetMenu.app` to `/Applications`.

### First launch

NetMenu isn't notarized yet, so macOS may block it the first time you open it. Click **Open Anyway** in **System Settings → Privacy & Security**, or run:

```bash
xattr -dr com.apple.quarantine /Applications/NetMenu.app
```

macOS may also ask for two optional permissions:

| Permission | Used only for | If denied |
| --- | --- | --- |
| Location | Reading the Wi‑Fi network name | Network name is missing from the stats log |
| Local Network | Pinging your router | Router latency is missing from the stats log |

## What you see

The menu bar shows **latency** and **connection health**, for example `9ms │ 100%`.

| Latency | Meaning |
| --- | --- |
| `24ms` | Round trip to the internet, from the fastest of several ping targets. Fake replies from hotel or in-flight equipment are ignored. |
| `~180ms` | Ping is blocked on this network, so this is the time to load a small web page instead. |
| `✕` | Nothing trustworthy got through for a minute. |

**Connection health** is a score for the last minute. A connection good enough for an HD video call (latency up to 150ms, jitter up to 40ms, packet loss up to 2%) scores 100%. Worse loss, jitter or latency pulls it down, and one bad factor is enough. A spinner shows for the first few seconds while it calibrates. If websites stop loading, health drops to **0%** and the menu says **internet sites unreachable**, even if ping still works.

The menu adds:

- **Connection health** with its loss, jitter and latency
- **Throughput**: current download and upload rate, averaged over 5 seconds. Turn on **Show throughput in menu bar** to show it next to health too.
- **Top apps**: the apps using the most bandwidth over the last 10 seconds, up to three, with their share of all traffic, such as `Top apps (~81%): Firefox`
- **Peak this connection**: the highest rates since you joined this network. It resets when you switch networks or access points.
- **Speed test** results and controls

For exactly how each number is measured, see [How NetMenu works](docs/HOW-IT-WORKS.md).

## Speed test

Choose **Run speed test** in the menu, and **Cancel speed test** to stop it. It tests download and upload against Cloudflare and takes from about 5 seconds on fast connections to about 30 on slow ones. The result looks like **Last test: 268↓ / 41↑ Mbps · 9ms, 38ms loaded**: download and upload speed, latency when idle, and latency while the connection is busy. A big jump under load means a busy connection will make calls and games lag.

It uses as little data as it can:

| Network | Data used |
| --- | --- |
| Most connections | Up to 32 MB |
| Very fast connections (150 Mbps and up) | Up to 64 MB, since 32 MB lasts under two seconds there |
| Low Data Mode, or a metered network such as an iPhone hotspot | Up to 8 MB |

A result with `≥`, such as **≥480↓**, means the connection was still speeding up when the data allowance ran out, so the real speed is at least that.

## Your data

- **Stats history.** Once a minute NetMenu records latency, health, throughput and Wi‑Fi details to a file on your Mac, plus every speed test. Open it with **Reveal stats file**. It's capped at 100 MB.
- **Diagnostic log.** A detailed log for troubleshooting, capped at 30 MB (about three days). Open it with **Reveal diagnostic log**. If NetMenu shows something that doesn't look right, this log has the details to explain it.

Both stay on your Mac. Formats are described in [Logs](docs/LOGS.md).

## More

- [How NetMenu works](docs/HOW-IT-WORKS.md): probes, health scoring, top apps, speed test, reliability
- [Logs](docs/LOGS.md): stats file fields and the diagnostic log
- [Development](docs/DEVELOPMENT.md): building from source, tests, project layout, code signing
- [Releasing](docs/RELEASING.md)

## License

NetMenu is released under the [MIT License](LICENSE).
