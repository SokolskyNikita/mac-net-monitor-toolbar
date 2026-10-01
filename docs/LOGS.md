# Logs

NetMenu keeps two files on your Mac. Neither is sent anywhere.

| File | Open with | Size limit | Purpose |
| --- | --- | --- | --- |
| `~/Library/Application Support/NetMenu/stats.jsonl` | **Reveal stats file** | 100 MB | Per-minute history and speed tests, as JSON |
| `~/Library/Logs/NetMenu/NetMenu.log` | **Reveal diagnostic log** | 30 MB | Detailed troubleshooting log, as plain text |

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
| `loss` | Fraction of pings that failed or were rejected, between 0 and 1. Pings that couldn't run are left out. |
| `health` | Health score (0–100) at the end of the minute, or `null` without enough fresh data; 0 during a confirmed outage |
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

- Every probe cycle: each ping target's reply time and hop count, or `lost` / `unmeasured(reason)`; each website check's result, curl error and duration; the captive check; router latency; and what was published
- Every visible health change, with loss, jitter and latency
- Network changes, Location permission changes, sleep and wake, and helper failures
- Every speed test with its full breakdown: connections, data used, timing and errors per direction
- A heartbeat every 5 minutes with uptime, open files, threads, memory, CPU use (NetMenu's own and its helpers') and failure counters

The log rotates at 10 MB and keeps two older files (`NetMenu.1.log`, `NetMenu.2.log`), so it never exceeds 30 MB. That's about three days of history. Warnings and errors also go to the macOS unified log:

```bash
log show --last 1d --predicate 'subsystem == "me.sokolsky.netmenu"'
```
