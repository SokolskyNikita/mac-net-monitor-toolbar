# Logs

NetMenu keeps two files on your Mac. Neither is sent anywhere.

| File | Open with | Size limit | Purpose |
| --- | --- | --- | --- |
| `~/Library/Application Support/NetMenu/stats.jsonl` | **Diagnostics → Open stats file** | 100 MB | Per-minute history and speed tests, as JSON |
| `~/Library/Logs/NetMenu/NetMenu.log` | **Diagnostics → Open diagnostic log** | 30 MB | Detailed troubleshooting log, as plain text |

## Stats log

Once a minute, NetMenu appends a JSON line to `stats.jsonl`. When an append would exceed 100 MB, the oldest entries are dropped to keep roughly the newest 90 MB; oversized files are also trimmed at launch.

Each per-minute entry includes:

| Field | Description |
| --- | --- |
| `ts` | Timestamp (ISO 8601, UTC) |
| `type`, `network` | Connection type (`wifi`, `ethernet`, `tether`, `vpn`, `offline`) and network name |
| `lat_ms`, `lat_min`, `lat_max` | Median, minimum and maximum latency for the minute |
| `lat_src` | How latency was measured: `icmp` or `http` (older entries may also contain `tcp` or `tls`) |
| `gw_ms` | Median router latency |
| `local_router`, `local_interface` | Physical router address (IPv4 or scoped IPv6) and interface, separate from the VPN default |
| `local_method` | Active local measurement protocol: `icmp`, `dns`, `tcp443`, `tcp80` or `dhcp`; `null` without a calibrated report |
| `local_health`, `local_loss`, `local_jitter_ms`, `local_latency_ms` | Smoothed local health and its loss fraction, jitter and median latency; `null` without enough fresh data or if the router has never answered a supported probe |
| `loss` | Fraction of pings that failed or were rejected, between 0 and 1. Pings that couldn't run are left out. |
| `health` | Health score (0–100) at the end of the minute, or `null` without enough fresh data; 0 during a confirmed outage |
| `health_raw`, `health_loss`, `health_jitter_ms`, `health_latency_ms` | Current unsmoothed health score and recency-weighted inputs; distinct from the minute's unweighted `loss` and `lat_ms` |
| `health_internet_reachable`, `health_websites_failing` | Confirmed-outage reachability and unconfirmed website-failure flags from the current health report; `null` during calibration |
| `connections` | Latest socket snapshot, or `null` after 15 seconds: open, receiving and sending counts; received/sent packets over `window_s`; and per-app names, open counts and packets. `ranking_basis` is `packets`. TCP includes established connections; UDP includes interface-bound sockets. Loopback is excluded. |
| `transport_health`, `local_health_raw` | Unsmoothed WAN transport score (before the website outage override) and local-router score |
| `health_window_s`, `health_weighting`, `health_weight_min_age_s` | Scoring definition: 60-second window, `inverse_sqrt_age`, ages clamped to at least one second |
| `reconnects_5m` | Completed reconnects in the rolling five-minute window, including counts of zero or one hidden by the menu |
| `recent_trouble` | Warning categories active in the last ten seconds at snapshot time; an empty array means none. This is a snapshot, not a full incident history. |
| `internet_checks_fresh` | Whether a measured website check exists within the last 30 seconds; distinguishes stale retained results from current evidence |
| `internet_reachable` | Whether at least one website passed in the latest website check |
| `internet_checks` | Latest per-site results for `example.com` and `www.google.com`; a site whose check couldn't run is omitted |
| `captive` | Whether Apple's captive check detected a login page in the latest cycle |
| `down_Bps`, `up_Bps` | Average throughput in bytes per second |
| `down_peak_Bps`, `up_peak_Bps` | Highest one-second rates in the minute |
| `rssi`, `noise`, `channel`, `tx_rate_mbps` | Wi‑Fi signal details |

Each speed test, including failed and cancelled ones, adds a separate entry with `"event": "speedtest"`:

| Field | Description |
| --- | --- |
| `status` | `ok`, `partial`, `failed` or `cancelled` |
| `down_mbps`, `up_mbps` | Result, or `null` when a direction has no result |
| `down_lower_bound`, `up_lower_bound` | `true` when the result is a lower bound (shown with `≥`) |
| `down_stable`, `up_stable` | Whether throughput settled before the test stopped |
| `idle_latency_ms`, `down_loaded_latency_ms`, `up_loaded_latency_ms` | Latency before the test and under load |
| `down_bytes`, `up_bytes`, `down_streams`, `up_streams` | Payload moved and connections used per direction |
| `bytes_reserved`, `budget_bytes`, `low_data` | Data reserved across all requests, the budget that applied, and whether Low Data Mode limits were used |
| `errors`, `duration_s`, `server` | Per-direction errors (`network` when the network changed), total time, and the test server |

## Diagnostic log

`NetMenu.log` is for troubleshooting: when NetMenu shows something unexpected, it has the detail to explain it. Console.app also lists it under Log Reports. It records:

- Independent probe completions: each WAN target's verdict, router protocol and outcome, website results, captive check and HTTPS fallback. Late results from an old network epoch or a speed test are discarded.
- Every visible health change, with loss, jitter and latency
- Network changes, Location permission changes, sleep and wake, and helper failures
- Every speed test with its full breakdown: connections, data used, timing and errors per direction
- A heartbeat every 5 minutes with uptime, open files, threads, memory, CPU use (NetMenu's own and its helpers') and failure counters

The log rotates at 10 MB and keeps two older files (`NetMenu.1.log`, `NetMenu.2.log`), so it never exceeds 30 MB. That's about three days of history. Warnings and errors also go to the macOS unified log:

```bash
log show --last 1d --predicate 'subsystem == "me.sokolsky.netmenu"'
```
