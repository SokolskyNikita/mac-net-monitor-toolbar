# Logs

NetMenu keeps two files on your Mac. Neither is sent anywhere.

| File | Open with | Size limit | Purpose |
| --- | --- | --- | --- |
| `~/Library/Application Support/NetMenu/stats.jsonl` | **Diagnostics → Open stats file** | 100 MB | Per-minute history and speed tests, as JSON |
| `~/Library/Logs/NetMenu/NetMenu.log` | **Diagnostics → Open diagnostic log** | Rotates at 10 MB; two older files retained | Detailed troubleshooting log, as plain text |

## Stats log

While the GUI is running and measurements are available, NetMenu appends a JSON line to `stats.jsonl` once a minute. Network changes and long sampling gaps can flush a shorter window; `secs` records its duration. When an append would exceed 100 MB, the oldest entries are dropped to keep roughly the newest 90 MB; oversized files are also trimmed at launch. A partial final line left by an interrupted write is repaired on the next append.

Each per-minute entry includes:

| Field | Description |
| --- | --- |
| `ts` | Timestamp (ISO 8601, UTC) |
| `event`, `secs` | `sample` and the measurement-window duration in seconds, which need not be exactly 60 |
| `if`, `router` | Default-route interface and gateway; these may belong to a VPN |
| `type`, `network` | Connection type (`wifi`, `ethernet`, `tether`, `vpn`, `offline`) and network name |
| `bssid` | Wi-Fi access-point identifier when macOS exposes it |
| `lat_ms`, `lat_min`, `lat_max` | Unweighted median, minimum and maximum of retained successful WAN measurements in the window, up to 120 readings. ICMP records each trusted target reply, rather than one fastest reply per round. A change between ICMP and HTTPS clears this latency window. |
| `lat_src` | How latency was measured: `icmp` or `http` (older entries may also contain `tcp` or `tls`) |
| `gw_ms` | Unweighted median of successful router probe timings in the window, including fallback protocols |
| `local_router`, `local_interface` | Physical router address (IPv4 or scoped IPv6) and interface, separate from the VPN default |
| `local_method` | Active local measurement protocol: `icmp`, `dns`, `tcp443`, `tcp80` or `dhcp`; `null` without a calibrated report |
| `local_health`, `local_loss`, `local_jitter_ms`, `local_latency_ms` | Smoothed local health and its loss fraction, jitter and median latency; `null` without enough fresh data or if the router has never answered a supported probe |
| `loss`, `rejected` | Unweighted fraction of measured WAN pings that timed out or were rejected, and the count rejected as local replies. Pings that couldn't run are excluded. `loss` is forced to 1 when the window has no usable WAN latency; with only HTTPS measurements and no measured pings it is 0. |
| `health` | Health score (0–100) at the end of the minute, or `null` without enough fresh data; 0 during a confirmed outage |
| `health_raw`, `health_loss`, `health_jitter_ms`, `health_latency_ms` | Current unsmoothed health score and recency-weighted inputs; distinct from the minute's unweighted `loss` and `lat_ms` |
| `health_internet_reachable`, `health_websites_failing` | Confirmed-outage reachability and unconfirmed website-failure flags from the current health report; `null` during calibration |
| `connections` | Latest socket snapshot, or `null` when unavailable or more than 15 seconds old; see [Connection snapshot](#connection-snapshot) |
| `transport_health`, `local_health_raw` | Unsmoothed WAN transport score (before the website outage override) and local-router score |
| `health_model`, `health_window_s`, `health_weighting`, `health_weight_half_life_s` | Scoring definition: `delay_budget_v1`, 60-second window, `exponential_age`, 15-second half-life. Older records used `inverse_sqrt_age` and `health_weight_min_age_s`. |
| `reconnects_5m` | Completed reconnects in the rolling window (five minutes by default), including counts of zero or one hidden by the menu. The legacy field name is retained for readers. |
| `reconnect_window_s` | Configured reconnect window in seconds, normally 300 |
| `recent_trouble` | Warning categories active in the last ten seconds: `network loss`, `network latency`, `network jitter`, corresponding `router` categories, and `web access`. An empty array means none. |
| `internet_checks_fresh` | Whether a measured website check exists within the last 30 seconds; distinguishes stale retained results from current evidence |
| `internet_reachable` | Whether at least one website passed in the latest website check |
| `internet_checks` | Latest per-site results for `example.com` and `www.google.com`; a site whose check couldn't run is omitted |
| `captive` | Whether Apple's captive check detected a login page in the latest cycle |
| `down_Bps`, `up_Bps` | Throughput averaged over valid sampled intervals, in bytes per second |
| `down_peak_Bps`, `up_peak_Bps` | Highest eligible interval rates in this log window, rather than the menu's peak since connecting |
| `rssi`, `noise`, `channel`, `tx_rate_mbps` | Wi‑Fi signal and noise in dBm, channel number and reported transmit link rate in Mbps; unavailable values are `null` |

`health_latency_ms` is the recency-weighted input to the score. It can differ from both `lat_ms` and the live five-round RTT in the menu. Local health fields use the smoothed report, while `local_health_raw` is the current unsmoothed score. Wi-Fi details may be unavailable or redacted; `network` may be a generic label such as `Wi-Fi` or `VPN`.

### Connection snapshot

The `connections` object covers established TCP connections and interface-bound UDP sockets observed by `nettop` on Wi-Fi/wired interfaces, excluding loopback. `open` counts sockets at the snapshot; `receiving` and `sending` count sockets with incoming or outgoing bytes during the collection window. One socket can count in both directions.

`packets_received` and `packets_sent` are packet deltas over `window_s` (10 seconds). Each object in `apps` contains `name`, `open`, `packets_received` and `packets_sent`, grouped by resolved caller identity. `ranking_basis` is `packets`; the menu's **Top apps** row instead ranks by bytes. These snapshots are not a complete connection history and do not store remote addresses or payloads.

### Speed-test events

Each speed test started from the GUI, including failed and cancelled ones, adds a separate entry with `"event": "speedtest"`. CLI modes print their results without appending these records.

| Field | Description |
| --- | --- |
| `ts`, `type`, `network` | Completion timestamp (UTC) and the connection identity captured when the test started |
| `status` | `ok`, `partial`, `failed` or `cancelled` |
| `down_mbps`, `up_mbps` | Result, or `null` when a direction has no result |
| `down_lower_bound`, `up_lower_bound` | `true` when the result is a lower bound (shown with `≥`) |
| `down_stable`, `up_stable` | Whether throughput settled before the test stopped |
| `idle_latency_ms`, `down_loaded_latency_ms`, `up_loaded_latency_ms` | Latency before the test and under load |
| `down_bytes`, `up_bytes`, `down_streams`, `up_streams` | Payload moved and connections used per direction |
| `bytes_reserved`, `budget_bytes`, `low_data` | Data reserved across all requests, the budget that applied, and whether Low Data Mode limits were used |
| `errors`, `duration_s`, `server` | Per-direction errors (`network` when the network changed), total time, and the test server |

A network change forces `status` to `failed` and adds `errors.network`. Any retained phase measurements in that entry must not be treated as a valid result for the original network. Cancelling after a direction produces a usable result can leave a `partial` record rather than `cancelled`.

## Diagnostic log

`NetMenu.log` is for troubleshooting: when NetMenu shows something unexpected, it has the detail to explain it. Console.app also lists it under Log Reports. It records:

- Independent probe completions: each WAN target's verdict, router protocol and outcome, website results, captive check and HTTPS fallback. Late results from an old network epoch or a speed test are discarded.
- Every visible health change, with loss, jitter and latency
- Network changes, Location permission changes, sleep and wake, and helper failures
- Every speed test with its full breakdown: connections, data used, timing and errors per direction
- A heartbeat every 5 minutes with uptime, open files, threads, memory, CPU use (NetMenu's own and its helpers') and failure counters

The log rotates at 10 MB and keeps two older files (`NetMenu.1.log`, `NetMenu.2.log`), for roughly 30 MB total. How much time that covers depends on probe activity and errors. Warnings and errors also go to the macOS unified log:

```bash
log show --last 1d --predicate 'subsystem == "me.sokolsky.netmenu"'
```
