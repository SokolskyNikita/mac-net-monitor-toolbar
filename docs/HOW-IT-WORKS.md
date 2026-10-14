# How NetMenu works

This is the detail behind each number in the menu. For what the numbers mean day to day, see the [README](../README.md).

## Probes

At launch, NetMenu shows “identifying network…” until the first network identity is resolved. Probes and throughput reporting begin from that baseline; initial discovery does not reset the display. Later changes of network still discard old measurements.

NetMenu schedules these checks independently, with router and WAN probes targeting a three-second interval:

- ICMP pings to `1.1.1.1`, `1.0.0.1`, `8.8.8.8`, `9.9.9.9` and `google.com`
- A probe to your physical router, subject to Local Network access, using ICMP or the [local protocol fallbacks](#local-connection-health)
- A fetch of Apple's captive portal check (`captive.apple.com`), the page macOS uses to detect Wi‑Fi login screens
- The two website fetches used for [connection health](#connection-health)

While everything answers, the captive check and website fetches run every 15 seconds to save energy. Trouble shortens their target interval to three seconds. Each WAN target, the router, website checks, captive check, and HTTPS latency fallback have separate schedules. A slow request blocks only its own lane; each lane permits at most one outstanding request. Replies and timeouts update the UI as they arrive, including while the menu is open. If a request exceeds its interval, its next attempt starts after completion. Results from an older network epoch or overlapping a speed test are discarded.

The HTTPS latency fallback starts when no usable WAN ping has arrived (after the initial eight-second ping deadline, or ten seconds without a subsequent reply). Its potentially long timeout never delays ping results. Partial WAN rounds are updated in place, so five replies from one round are not five calibration samples and pending requests are not counted as lost.

Pings are sent from inside NetMenu over an unprivileged ICMP socket rather than by launching `/sbin/ping`. A reply only counts if its identifier, sequence number, source address and random payload match a request NetMenu sent, since the socket also sees other apps' ping replies. Round-trip time comes from the kernel's receive timestamp, as with `ping`, checked against a monotonic clock so a clock change can't distort it. If ICMP sockets aren't available, NetMenu falls back to `/sbin/ping`.

A probe NetMenu couldn't run, such as a ping target whose name didn't resolve or a helper that failed to start, is recorded as *unmeasured*. It's never counted as lost, so a problem on the Mac can't masquerade as a bad network.

## Latency

| Display | Meaning |
| --- | --- |
| `24ms` | Median of the latest five successful ICMP rounds, using the fastest trusted target in each. Replies from within a few network hops, or about as fast as your router, are rejected as suspected local responses. |
| `~180ms` | Ping is blocked, so this is the time to fetch a Cloudflare trace page over HTTPS. The page contents are verified, which stops a proxy from faking the answer. Not used while a login page is detected. |
| `✕` | No trustworthy latency measurement has arrived yet, or the last one is over 60 seconds old. Bare TCP or TLS connection times are never shown, because hotel and in-flight proxies can answer those locally in a few milliseconds. |

Hop counts come from each reply's TTL. Hotel and in-flight networks often answer popular addresses such as `1.1.1.1` from equipment one to three hops away, in 1–80ms, while the real round trip is 700ms or more.

The menu-bar ping and the **Internet health** dropdown RTT share the median of up to five recent successful rounds, so a single spike has less influence. Partial rounds can change as faster replies arrive; rounds without a trusted reply are omitted. HTTPS fallback uses up to five successful fallback readings. ICMP and HTTPS readings are kept separate. Both displays update together without health-report smoothing. The health score still uses the recency-weighted 60-second latency history described below.

## Local connection health

The **Local router** row shows health, packet loss, jitter and median round-trip latency to the physical router, using the same one-minute window, scoring model and ten-second display smoothing as internet health. Displayed latency and jitter are rounded to the nearest millisecond; scoring and history retain the full measurement precision.

Router discovery considers physical-interface default routes behind a VPN, supports IPv4 and scoped IPv6 link-local addresses, and skips the synthetic IPv4 gateway on CLAT networks. IPv6 probes run in-process with kernel receive timestamps, like IPv4 probes. Local health does not depend on internet website checks. It ignores probes during the app's speed test, clears history on network changes, and settles after waking. If ICMP does not answer, NetMenu tries direct DNS, TCP 443, TCP 80, then IPv4 DHCP INFORM. It keeps the first working protocol. Missing replies to that protocol count as loss; after three failures it tries alternatives, at most once every 30 seconds. Changing protocol resets the local score window and display smoothing so different response times cannot create fake jitter. A router that answers none is unavailable; probes the Mac cannot run are excluded.

DNS uses a [nonrecursive root SOA query](https://www.rfc-editor.org/rfc/rfc1035.html) sent to the router itself. Any matching DNS response, including refusal, demonstrates reachability. TCP measures the handshake or explicit connection refusal, without sending application data. [DHCP INFORM](https://www.rfc-editor.org/rfc/rfc2131.html#section-4.4.3) asks the IPv4 router for configuration information without allocating, renewing or releasing a lease; the reply is never applied. DHCP is skipped if the client has no real IPv4 address, macOS owns UDP port 68, or socket access is denied. It does not use DHCPv6 or query a separate DHCP server.

Fallback sockets are bound to the physical interface and limited to one hop, with a one-second deadline each. DNS/DHCP responses include router service processing time, and TCP timing includes local socket scheduling, so these are protocol-specific estimates rather than interchangeable ICMP RTTs. The menu and stats log name the protocol. Fallback timings are never used to classify internet ping replies as captive-portal responses.

## Connection health

The percentage next to the latency first checks that ordinary websites load. NetMenu fetches `https://example.com/` and `https://www.google.com/robots.txt` in parallel, bypassing caches, with an 8-second timeout. At least one must return a successful HTTPS response with the expected content. Redirects, login pages, DNS resolution and TCP/TLS handshakes don't count. Nor can a working Apple captive check or Cloudflare trace stand in, since a network can allowlist those while blocking everything else.

If a measured website round has no successful site, NetMenu checks for an outage. Checks that could not run are omitted; an entirely unmeasured round does not count as failure. Health drops to **0%**, whatever the latency shows, once that failed round is corroborated by a recent failed HTTPS fallback and no recent usable ping, or by a detected login page. Otherwise NetMenu waits for a second failing website round. The menu then reports **internet sites unreachable**. Ping completions cannot count the same website failure twice. Website outage evidence expires after 30 seconds without a measured refresh. While rechecking, a calibrated health report notes **websites failed, rechecking**.

When websites load, health scores the last 60 seconds of probes, weighting each by `2^(-max(0, age in seconds) / 15)`: a new sample has weight 1, a 15-second-old sample 0.5, a 30-second-old sample 0.25, and a 60-second-old sample 0.0625. Older samples are excluded. Loss uses weighted lost/total counts; jitter uses a weighted average of all valid same-target RTT deltas, dated by the newer reply; latency uses a weighted median. Target outlier detection still uses actual packet counts. Local health uses the same weighting. Partial rounds update as individual results arrive. The score is averaged over 10 seconds and changes at most once every 10 seconds. A spinner stands in for it during the first three probe cycles while it calibrates. A confirmed outage skips calibration and smoothing. After a verified recovery, normal scoring resumes without averaging in the forced 0%.

After waking from sleep or switching networks, failures are ignored until something answers, for at most 30 seconds, so the moments Wi‑Fi takes to reconnect don't depress the score for the next minute. Probes that overlap a network change, or a speed test, are discarded.

Health combines latency and jitter into a shared delay budget, then applies a separate loss penalty:

```text
T = recency-weighted median RTT in milliseconds
J = recency-weighted mean absolute consecutive RTT change to the same target, in milliseconds
P = recency-weighted packet loss in percentage points (3 means 3%)

D = 40 + T/2 + J
lossCost = max(0, P - 1) / 4
delayCost = (max(0, D - 150) / 200)^2
health = round(100 * 2^(-lossCost - delayCost))
```

`T/2` assumes roughly symmetric paths. `40 + J` is a provisional allowance for processing and buffering; it is not a measured application buffer. Jitter is included once through the delay budget, without trimming spikes or dividing by baseline RTT. This lets a low-latency connection absorb more variation before its score falls. A delay budget up to 150ms and loss up to 1% are free; each additional four percentage points of loss halves the score. The delay penalty has no cap.

The structure is informed by [ITU-T P.940, §7.1](https://www.itu.int/epublications/publication/itu-t-p-940-2025-03-computational-model-used-for-the-monitoring-and-quality-assessment-of-videotelephony-services), which describes audio jitter as contributing to receiver delay or loss. The constants are product calibration, not coefficients from that standard. Sparse probes cannot measure the media path, codec, recovery, buffer behavior or media-packet burstiness, so this score is a network-health heuristic rather than a validated call-quality prediction.

| RTT | Jitter | Loss | Health |
| --- | --- | --- | --- |
| 20ms | 50ms | 0% | 100% |
| 100ms | 50ms | 0% | 100% |
| 300ms | 50ms | 0% | 87% |
| 600ms | 50ms | 0% | 37% |
| 20ms | 50ms | 3% | 71% |
| 300ms | 50ms | 5% | 43% |

ICMP loss counts targets that answered at least once in the window; suspected local replies and unmeasured probes are excluded. A target is left out, keeping a majority of the responding targets, only when its loss is both more than 10 percentage points above the others' and statistically implausible at their loss rate (under 1% likely). This avoids mistaking one server rate-limiting pings for a bad connection. If no target has a trusted reply, loss falls back to the share of rounds without a usable result. When HTTPS fallback supplies the transport history, a failed fallback attempt counts as lost. Jitter compares the same target across replies; if no such deltas exist, it uses consecutive published RTTs from the same transport. Latency uses the latest transport source's measurements. Local health uses the same model.

## Recent trouble and reconnects

A warning beside the menu-bar quality percentage appears immediately for a missed reply from a previously responding target, a latency or incremental jitter penalty above 5%, or failed website checks. Latency warnings use the delay cost with zero jitter; jitter warnings use only the additional cost of the latest RTT change, evaluated at the higher of the two RTTs. These warnings bypass score calibration and display smoothing and expire ten seconds after the last event. A permanently filtered target does not generate recurring loss warnings, and unmeasured probes never generate them.

**N reconnects in past 5 mins** appears only after at least three completed disconnect/reconnect cycles in the rolling five-minute window. It counts path transitions from connected to disconnected and back, excluding startup, wake reconnection, duplicate notifications, and metadata-only changes. Counts age out even with no new traffic.

## Wi-Fi scan warnings

The **Wi-Fi scans** warning correlates slow router pings with scans requested by the Wi-Fi page in System Settings. It requires at least two ICMP router replies over 40ms that overlap completed scans from at least two distinct Settings requests within the last 45 seconds. Only valid router RTTs up to one second are retained. Merely having System Settings open is not evidence, and DNS/TCP/DHCP fallback timings do not trigger detection.

After repeated slow pings, NetMenu queries the last minute of `airportd` unified-log events off the main thread, at most once every 20 seconds, with a five-second timeout. It only queries while System Settings is running and the current connection is classified as `wifi`; a connection classified as `vpn` does not enable this detector even if Wi-Fi carries the VPN. Restricted logs or an unsupported log format can prevent detection.

The warning adds a menu-bar warning symbol and offers **Quit System Settings to stop scans**. Clicking it requests that the entire System Settings app quit, including other settings pages. If the request is refused, NetMenu asks you to close the Wi-Fi page or quit Settings manually. The warning clears when evidence ages out, Settings closes, or monitoring resets after wake or a network change. It identifies correlation, not proof that scans caused every delay.

## Throughput and peaks

Download and upload rates come from the byte counters of the Mac's physical `en*` interfaces, read once a second through a routing `sysctl`. They include local network traffic and exclude loopback and VPN tunnel interfaces, which would count the same bytes twice. **Traffic** shows a 5-second average. **Peak** is the highest eligible sampling-interval rate since joining the network, normally a one-second measurement. Intervals under 0.75 seconds count toward averages but not peaks. Gaps over five seconds are excluded and reset the sampling baseline. Peaks reset when NetMenu detects a network change, including a switch to another Wi‑Fi network or access point.

## Top apps

The **Top apps** row updates at most once every 10 seconds, ranking apps by all their downloaded and uploaded bytes over the preceding 10-second sampling window. It lists the largest contributors until their combined share reaches 80%, capped at three apps. If three fall short, it shows their actual approximate share, such as `Top apps (~64%): Firefox, Dropbox, Spotify`. Long names are shortened to fit.

Attribution follows each PID's parent chain to the nearest application, so `ChatGPT → shell → curl` contributes to ChatGPT. Helpers inside a bundle use the outermost app bundle. Process ancestry is sampled once per second and retained only within the current traffic window, including exited parents; detected PID reuse prevents attribution through that PID. Missing ancestry falls back to the executable identity. Short-lived processes missed between observations and shared services remain best-effort.

Ranking consolidates by resolved app-bundle path (or executable identity), never by display name. Known bundle IDs receive readable menu aliases such as Chrome, VS Code, Edge, Teams, Zoom, and Docker. Claude and Claude Code stay distinct. Connection snapshots in the stats log use the same resolved caller identities.

NetMenu reads macOS's built-in `nettop` counters for TCP and UDP traffic on Wi-Fi and wired interfaces, including local network traffic but excluding loopback. Helpers inside the same app bundle are grouped together. Separate callers stay distinct even when they share a display name. Traffic from the `curl` helpers NetMenu runs for its own website checks counts as NetMenu. This needs no administrator access or new permission in a normal app launch. App names stay on your Mac; connection snapshots include app names in the local stats log.

Shares are approximate because socket and interface counters differ. Unattributed interface traffic stays in the total; if app counters exceed that total, their sum is used instead. If interface counters are temporarily missing, the app counters supply the total. VPNs, proxies and shared services may appear as the traffic owner.

Temporary sampling failures and network changes keep the previous list visible for about a minute, labelled **last sample**, while collection retries. **Unavailable** appears only after three failed initial readings or a minute without a valid sample, on the next display update. A valid idle reading shows **no traffic**.

The same collection produces a socket snapshot for the stats log: established TCP connections and interface-bound UDP sockets, plus received/sent packet counts over the 10-second window. These connection details are logged rather than displayed as separate menu rows. See [Logs](LOGS.md#connection-snapshot) for field meanings.

## Speed test

The speed test measures download and upload against Cloudflare (`speed.cloudflare.com`). It's built to be accurate on anything from a satellite link to gigabit fiber while using as little data as it can:

- **Parallel connections.** Four connections run at once, because a single connection often can't fill a fast or lossy link.
- **Adaptive requests.** Requests start at 64 KB and double until each takes about 0.75 seconds at the measured rate (longer on high-latency links).
- **Measured after ramp-up.** Throughput is the total bytes all connections moved per second, excluding the first second of ramp-up but always covering at least the last half of the bytes. Once the data allowance runs out, the tail where connections finish one by one is excluded too. Upload bytes count only once the server has confirmed receiving them; counting bytes as they enter the send buffer reads about twice the real rate on a fast link.
- **Stops early.** Each direction stops as soon as throughput holds steady (within 10% for two seconds), or after 12 seconds.
- **Latency.** Idle latency is measured before the test and latency under load during each direction, on a separate connection, as the HTTP round trip minus Cloudflare's reported server time.

| Data use | Budget |
| --- | --- |
| Normal | 32 MB: up to 20 MB download, the rest (at least 12 MB) upload |
| Very fast links (at least 150 Mbps when a direction hits its limit) | Grows once per direction, to 40 MB download and 64 MB in total |
| Low Data Mode or a metered network such as an iPhone hotspot | 8 MB, never grows |

Every request reserves its full size from the budget before it starts and nothing is given back, so payload never exceeds the budget however requests end. HTTP and TLS overhead adds about 1–3%. A direction that runs out of data while throughput is still climbing (the second half of the measurement more than 10% faster than the first) is a lower bound and shows with `≥`.

If one direction fails, the other's result is kept as a **Partial test** and the menu names the failure, such as **upload: timed out**. A network change stops the test and invalidates its speed results; the event is still logged. Internet and local health ignore probes taken during the test, since it saturates the link on purpose. Failed or partial tests can be retried after 15 seconds, successful ones after 60. A cancellation with no usable speed result is reported as cancelled and can be retried immediately; if a usable direction is retained as a partial result, the 15-second cooldown applies. The result row remains visible for five minutes after completion, failure or cancellation.

## Reliability

NetMenu is meant to run for weeks without a restart:

- Every helper process is reaped and its pipes closed as soon as it finishes; nothing accumulates per probe.
- The stats file and diagnostic log are size-capped and rotate on their own.
- Sleep, wake and network changes are detected immediately, and measurements that span them are discarded.
- A heartbeat in the [diagnostic log](LOGS.md#diagnostic-log) records open files, threads, memory and CPU every 5 minutes, so slow problems show up as trends.
- As a last resort, a watchdog checks resource limits once a minute. After at least 30 minutes running, it can relaunch the app if open file descriptors exceed 1,000 (or half the process limit, if lower), threads exceed 300, memory footprint exceeds 1.5 GB, or the main thread is unresponsive for over 2 minutes. These are threshold checks, not leak detection. The log records why; relaunch requires running an `.app` bundle.
