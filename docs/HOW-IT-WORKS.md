# How NetMenu works

This is the detail behind each number in the menu. For what the numbers mean day to day, see the [user guide](USER-GUIDE.md).

## Probes

At launch, the health rows show “identifying network…” until the first network identity is resolved. Probes and throughput reporting begin from that baseline; initial discovery does not reset the display. Later changes of network still discard old measurements.

NetMenu schedules these checks independently. Router and WAN probes target a three-second interval; because starts are aligned to a one-second tick, a round follows the previous one by three or four seconds:

- ICMP pings to `1.1.1.1` (Cloudflare), `208.67.222.222` (OpenDNS), `8.8.8.8` (Google), `9.9.9.9` (Quad9) and `google.com`. The four addresses belong to four operators, so trouble at one of them costs one address; `google.com` is the one target that also needs DNS.
- A probe to your physical router, subject to Local Network access, using ICMP or the [local protocol fallbacks](#local-connection-health)
- A fetch of Apple's captive portal check (`captive.apple.com`), the page macOS uses to detect Wi‑Fi login screens
- The website fetches used for [connection health](#connection-health)

While everything answers, the captive check and website fetches run every 15 seconds to save energy. Trouble shortens their target interval to three seconds. Trouble here means IPv4 websites not loading, a detected login page, or any ping in the last 15 seconds that was lost, rejected as a local reply, or could not be run. A network that always answers one target locally therefore stays on the three-second interval.

- **Separate schedules.** Each WAN target, the router, the website checks, the captive check and the HTTPS latency fallback has its own lane. A slow request blocks only its own lane, and each lane runs one request at a time.
- **WAN rounds.** The WAN targets start together as a round. A target still waiting out a timeout misses rounds, then joins the next one that starts after it finishes, so its replies are not counted as rounds of their own.
- **Overlap.** A website fetch that is still hanging after another site has answered is left to time out on its own, so it can overlap the next round. If a request exceeds its interval, its next attempt starts after completion.
- **Updates.** Replies and timeouts update the UI as they arrive, including while the menu is open.
- **Discarded results.** Results from an older network epoch, or overlapping a speed test, are discarded.

When a website round finds IPv4 unavailable and IPv6 working, live WAN measurements switch to ICMPv6 targets `2606:4700:4700::1111`, `2620:119:35::35`, `2001:4860:4860::8888` and `2620:fe::fe`. IPv6 probes start independently of outstanding IPv4 requests. Their received hop limits support the same local-response rejection as IPv4 TTLs. Latency, loss, jitter and display history restart for the selected family, so broken IPv4 probes cannot distort the quality of the working IPv6 path. Website checks continue checking both families; successful IPv4 access switches WAN measurements back. Replies and HTTPS fallbacks started before a family switch are discarded, even if the family switches back before they finish. The IPv4 warning and one-third score penalty remain based on website evidence.

The HTTPS latency fallback starts when no usable WAN ping has arrived (after the initial eight-second ping deadline, or ten seconds without a subsequent reply). Its potentially long timeout never delays ping results. While WAN measurements use IPv6, HTTPS fallback also uses IPv6 directly, with verified Cloudflare trace responses; it never waits for an IPv4 attempt first. While WAN measurements use IPv6, a detected login page does not suppress the fallback. Partial WAN rounds are updated in place, so five replies from one round are not five calibration samples and pending requests are not counted as lost.

Pings are sent from inside NetMenu over an unprivileged ICMP socket rather than by launching `/sbin/ping`. A reply only counts if its identifier, sequence number, source address and random payload match a request NetMenu sent, since the socket also sees other apps' ping replies. Round-trip time comes from the kernel's receive timestamp, as with `ping`, checked against a monotonic clock so a clock change can't distort it. If IPv4 ICMP sockets aren't available, NetMenu falls back to `/sbin/ping`. IPv6 has no such fallback; its pings are recorded as unmeasured.

A probe NetMenu couldn't run, such as a ping target whose name didn't resolve or a helper that failed to start, is recorded as *unmeasured*. It's never counted as lost, so a problem on the Mac can't masquerade as a bad network.

## Latency

| Display | Meaning |
| --- | --- |
| `24ms` | Median of the latest five successful ICMP rounds, using the fastest trusted target in each. Replies from within three network hops are rejected as suspected local responses. So are replies within 15ms of your router's own ping time from at most six hops away, when the router has answered a ping in the last ten seconds. |
| `~180ms` | Ping is blocked, so this is the time to fetch a Cloudflare trace page over HTTPS. The page contents are verified, which stops a proxy from faking the answer. No new fetch starts while a login page is detected on IPv4; a reading already shown stays until it is 60 seconds old. |
| `✕` | No trustworthy latency measurement has arrived yet, or the last one is over 60 seconds old. Bare TCP or TLS connection times are never shown, because hotel and in-flight proxies can answer those locally in a few milliseconds. |

Hop counts come from each reply's TTL. Hotel and in-flight networks often answer popular addresses such as `1.1.1.1` from equipment one to three hops away, in 1–80ms, while the real round trip is 700ms or more.

The menu-bar ping and the **Internet health** dropdown RTT share the median of up to five recent successful rounds, so a single spike has less influence. Partial rounds can change as faster replies arrive; rounds without a trusted reply are omitted. HTTPS fallback uses up to five successful fallback readings. ICMP and HTTPS readings are kept separate. Both displays update together without health-report smoothing. The health score still uses the recency-weighted 60-second latency history described below.

## Local connection health

The **Local router** row shows health, packet loss, jitter and median round-trip latency to the physical router, using the same one-minute window, scoring model and ten-second display smoothing as internet health. Displayed latency and jitter are rounded to the nearest millisecond; scoring and history retain the full measurement precision.

Router discovery considers physical-interface default routes behind a VPN, supports IPv4 and scoped IPv6 link-local addresses, and skips the synthetic IPv4 gateway on CLAT networks. IPv6 probes run in-process with kernel receive timestamps, like IPv4 probes. Local health does not depend on internet website checks. No router probes are sent during the app's speed test. History is cleared when the network identity changes and on waking; for up to 30 seconds after launch, waking or a path change, missed replies are ignored until the router answers.

If ICMP does not answer, NetMenu tries direct DNS, TCP 443, TCP 80, then IPv4 DHCP INFORM. It keeps the first working protocol while periodically retrying higher-priority methods. Waking, a network change and each speed test start the selection again from ICMP:

- **Retries.** Each candidate has its own 30-second, 60-second, two-minute, then five-minute retry backoff (with ±20% timing variation). A candidate that is promoted and then rolled back starts again at 30 seconds.
- **Promotion.** A successful trial triggers two confirmations one second apart; three successes promote the candidate. During the next 15 seconds, two consecutive failures roll back to the previous method.
- **Trials.** Trials do not enter health statistics, and normal router measurements retain their three-second cadence.
- **Failures.** Once a protocol is established, missing replies count as loss; after three failures NetMenu tries alternatives, at most once every 30 seconds, and those failures are retained even when recovery or rollback succeeds. Before any protocol is established, alternatives are tried on the first ICMP failure, and that failure is not counted if one of them answers.
- **Protocol changes.** These preserve the loss window, keep latency and jitter histories separate by method, and reset display smoothing so different response times cannot create fake jitter.

A router that has never answered any of them is unavailable; one that answered and then goes silent shows as loss. Probes the Mac cannot set up, such as a socket it cannot open or bind, are excluded. A send that fails because the network or host is unreachable counts as loss.

DNS uses a [nonrecursive root SOA query](https://www.rfc-editor.org/rfc/rfc1035.html) sent to the router itself. Any matching DNS reply, whatever its response code, demonstrates reachability. TCP measures the handshake or explicit connection refusal, without sending application data. [DHCP INFORM](https://www.rfc-editor.org/rfc/rfc2131.html#section-4.4.3) asks the IPv4 router for configuration information without allocating, renewing or releasing a lease; the reply is never applied. DHCP is skipped if the router address is IPv6, the client has no real IPv4 address or Ethernet hardware address, macOS owns UDP port 68, or socket access is denied. It does not use DHCPv6 or query a separate DHCP server.

Fallback sockets are bound to the physical interface and limited to one hop, with a one-second deadline each. DNS/DHCP responses include router service processing time, and TCP timing includes local socket scheduling, so these are protocol-specific estimates rather than interchangeable ICMP RTTs. The menu and stats log name the protocol. Fallback timings are never used to classify internet ping replies as captive-portal responses.

## Connection health

The percentage next to the latency first checks that ordinary websites load. NetMenu fetches `https://www.fastly.com/robots.txt` and `https://www.google.com/humans.txt`, bypassing caches, with an 8-second timeout each, in the order described below. At least one must return a successful HTTPS response with the expected content. Redirects, login pages, DNS resolution and TCP/TLS handshakes don't count. Nor can a working Apple captive check or Cloudflare trace stand in, since a network can allowlist those while blocking everything else.

Live monitoring checks IPv4 and IPv6 separately. These checks force the address family and bypass proxy environment settings, so a proxy cannot mask a broken local family.

- **Site order.** Each round starts one site per address family, with the two families leading with different sites and the lead alternating by round. The other site is fetched as soon as the first fails, or alongside it if the first has not answered within 2 seconds.
- **Fetch count.** A healthy round therefore makes two fetches and a failing one four. A family is only judged unreachable once both sites have failed; when both sites hang, that verdict takes up to 10 seconds, the head start plus the 8-second timeout.
- **No IPv6 route.** When the Mac has no route to the public IPv6 internet, the IPv6 fetches are recorded as failed without being started, since they could only fail to connect. The verdicts are unchanged, and an IPv4-only network makes one fetch per healthy round.

IPv4 failure is treated as critical, and IPv6 failure alone is not:

- **Confirmation.** After two consecutive rounds in which both IPv4 sites fail, working IPv6 divides the transport health score by **3**, rounded to the nearest percent with a minimum of 1%. Before transport calibration, verified IPv6 access starts at 33%. Without working IPv6, the score is **0%**.
- **No masking.** These changes bypass calibration and smoothing, and an automatic HTTPS fallback cannot hide the IPv4 failure.
- **Warning.** The menu-bar warning stays visible while the failure is confirmed; the menu explains **IPv4 unavailable; IPv6 is working** when applicable.
- **Clearing.** A successful IPv4 site clears the failure immediately. A round in which an IPv4 check could not run neither confirms the failure nor clears it. Evidence expires after 30 seconds, and network changes clear it.
- **IPv6 alone.** IPv6 failure does not lower health or trigger a warning. Only IPv4 website success enables the slower healthy website cadence.

If a measured website round has no successful site, NetMenu checks for an outage. Checks that could not run are omitted; an entirely unmeasured round does not count as failure. Health drops to **0%**, whatever the latency shows, once that failed round is corroborated by a recent failed HTTPS fallback and no recent usable ping, or by a detected login page. Otherwise NetMenu waits for a second failing website round. The menu then reports **internet sites unreachable**, or **IPv4 internet unavailable** once both IPv4 sites have failed in two consecutive rounds without working IPv6. Ping completions cannot count the same website failure twice. Website outage evidence expires after 30 seconds without a measured refresh. While rechecking, a calibrated health report notes **websites failed, rechecking**.

When every IPv4 website check failed because the site's name did not resolve, no IPv6 check got as far as connecting, and a ping sent within the last ten seconds, after the lookups began to fail, has been answered, NetMenu names DNS as the fault: **DNS not resolving names; pings still answer**, or **DNS lookups failed, rechecking** before the failure is confirmed. The score is the same as for any other website failure, since sites still do not load. Without an answering ping, unresolved names are treated as part of an ordinary outage.

When websites load, health scores the last 60 seconds of probes, weighting each by `2^(-max(0, age in seconds) / 15)`: a new sample has weight 1, a 15-second-old sample 0.5, a 30-second-old sample 0.25, and a 60-second-old sample 0.0625. Older samples are excluded. Loss uses weighted lost/total counts; jitter uses a weighted average of all valid same-target RTT deltas, dated by the newer reply; latency uses a weighted median. Target outlier detection still uses actual packet counts. Local health uses the same weighting. Partial rounds update as individual results arrive. The score is averaged over 10 seconds and changes at most once every 10 seconds. Once a latency reading exists, a spinner stands in for the score until three probe cycles have been measured. With no latency reading yet, the menu bar shows `✕` and no score, unless an outage is already confirmed. A confirmed outage skips calibration and smoothing. After a verified recovery, normal scoring resumes without averaging in the forced 0%.

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

A warning beside the menu-bar quality percentage appears immediately for a missed reply from a previously responding target, a latency or incremental jitter penalty above 5%, or a website round in which no site loaded on either address family. Router probes and HTTPS fallback readings raise the same warning by the same rules. Latency warnings use the delay cost with zero jitter; jitter warnings use only the additional cost of the latest RTT change, evaluated at the higher of the two RTTs. These warnings bypass score calibration and display smoothing and expire ten seconds after the last event. A target that has not answered since the network identity last changed, the Mac last woke, or the address family last switched does not generate loss warnings, and unmeasured probes never generate them. A target that answered once and is then filtered warns on each miss.

**N reconnects in past 5 mins** appears only after at least three completed disconnect/reconnect cycles in the rolling five-minute window. It counts path transitions from connected to disconnected and back, excluding startup, wake reconnection, duplicate notifications, and metadata-only changes. Counts age out even with no new traffic.

## Network-name discovery

Network-name discovery reads current connection metadata through CoreWLAN and `ipconfig getsummary` (only `ipconfig` for `--sample`). It does not run `system_profiler SPAirPortDataType`, which can trigger Wi-Fi scans. When the name is unavailable, NetMenu shows “Wi-Fi” or “VPN” instead.

## Throughput and peaks

Download and upload rates come from the byte counters of the Mac's physical `en*` interfaces, read once a second through a routing `sysctl`. Only `en*` interfaces are counted. That includes local network traffic and leaves out loopback and VPN tunnel interfaces; a tunnel's bytes already cross a physical interface, so counting both would double them. **Traffic** shows a 5-second average. **Peak** is the highest eligible sampling-interval rate since joining the network, normally a one-second measurement. Intervals under 0.75 seconds count toward averages but not peaks. Gaps over five seconds are excluded and reset the sampling baseline. Peaks reset when NetMenu detects a network change, including a switch to another Wi‑Fi network or access point. A switch between access points of the same network is only visible with Location access, which is what exposes the access-point identifier.

## Top apps

The **Top apps** row updates at most once every 10 seconds, ranking apps by all their downloaded and uploaded bytes over the preceding 10-second sampling window. It lists the largest contributors until their combined share reaches 80%, capped at three apps. A current row shows the listed apps' approximate share, such as `Top apps (~64%): Firefox, Dropbox, Spotify` when three fall short of 80%. Long names are shortened to fit.

Attribution follows each PID's parent chain to the nearest application, so `ChatGPT → shell → curl` contributes to ChatGPT. Helpers inside a bundle use the outermost app bundle. Process ancestry is sampled once per second and retained only within the current traffic window, including exited parents; detected PID reuse prevents attribution through that PID. A process with no application ancestor is identified by its executable path. One whose path is unknown, or whose PID was reused, is identified by name and PID, so each such process is its own entry. Short-lived processes missed between observations and shared services remain best-effort.

Ranking consolidates by resolved app-bundle path (or executable identity), never by display name. Known bundle IDs receive readable menu aliases such as Chrome, VS Code, Edge, Teams, Zoom, and Docker. Connection snapshots in the stats log resolve callers the same way, then add together entries that share a name.

NetMenu reads macOS's built-in `nettop` counters for TCP, UDP and QUIC traffic on Wi-Fi and wired interfaces, including local network traffic but excluding loopback. Helpers inside the same app bundle are grouped together. Separate callers stay distinct even when they share a display name. Traffic from the helper processes NetMenu runs, such as `curl` for its website checks, counts as NetMenu. This needs no administrator access or new permission in a normal app launch. App names stay on your Mac; connection snapshots include app names in the local stats log.

Shares are approximate because socket and interface counters differ. Unattributed interface traffic stays in the total; if app counters exceed that total, their sum is used instead. If interface counters are temporarily missing, the app counters supply the total. VPNs, proxies and shared services may appear as the traffic owner.

Temporary sampling failures, network changes and sampling gaps such as sleep keep the previous list visible for about a minute while collection retries. During that time the row's heading reads **Top apps (stale)** in place of the share. **Unavailable** appears only after three failed initial readings or a minute without a valid sample, on the next display update. A reading with no bytes at all on the interface shows **no traffic**. A reading with interface bytes but none attributed to any app counts as a failed sample.

The same collection produces a socket snapshot for the stats log: established TCP connections and interface-bound UDP and QUIC sockets, plus received/sent packet counts over the 10-second window. These connection details are logged rather than displayed as separate menu rows. See [Logs](LOGS.md#connection-snapshot) for field meanings.

## Speed test

The speed test measures download and upload against Cloudflare (`speed.cloudflare.com`). It's built to be accurate on anything from a satellite link to gigabit fiber while using as little data as it can:

- **Parallel connections.** Four connections run at once, because a single connection often can't fill a fast or lossy link.
- **Adaptive requests.** Requests start at 64 KB and are resized, between 16 KB and 8 MB, so each takes about 0.75 seconds for download and 0.4 seconds for upload at the measured rate (longer on high-latency links).
- **Measured after ramp-up.** Throughput is the total bytes all connections moved per second, excluding the ramp-up (one second, or four idle round trips if longer, up to three seconds) but always covering at least the last half of the bytes. Once the data allowance runs out, the tail where connections finish one by one is excluded too. Upload bytes count only once the server has confirmed receiving them; counting bytes as they enter the send buffer reads about twice the real rate on a fast link.
- **Stops early.** Each direction stops as soon as throughput holds steady (within 10% for two seconds after ramp-up), after 12 seconds, when its data allowance is spent, or after 8 seconds without data.
- **Latency.** Idle latency is measured before the test and latency under load during each direction, on a separate connection, as the HTTP round trip minus Cloudflare's reported server time.

| Data use | Budget |
| --- | --- |
| Normal | 32 MB: up to 20 MB download, the rest (at least 12 MB) upload |
| Very fast links (at least 150 Mbps when a direction hits its limit) | Grows once per direction, to 40 MB download and 64 MB in total |
| Low Data Mode or a metered network such as an iPhone hotspot | 8 MB, never grows |

Every request reserves its full size from the budget before it starts and nothing is given back, so payload never exceeds the budget however requests end. HTTP and TLS overhead adds about 1–3%. A direction that runs out of data while throughput is still climbing (the second half of the measurement more than 10% faster than the first) is a lower bound and shows with `≥`.

If one direction fails, the other's result is kept as a **Partial test** and the menu names the failure, such as **upload: timed out**. A network change stops the test and marks it failed: at once for a change of network path, and within 15 seconds for a new network name or router on the same path. The event is still logged, with any rates measured before the change, which must not be read as results for the original network. Internet and local health ignore probes taken during the test, since it saturates the link on purpose. Failed or partial tests can be retried after 15 seconds, successful ones after 60. A cancellation with no usable speed result is reported as cancelled and can be retried immediately; if a usable direction is retained as a partial result, the 15-second cooldown applies. The result row remains visible for five minutes after completion, failure or cancellation.

## Reliability

NetMenu is meant to run for weeks without a restart:

- Every helper process is reaped and its pipes closed as soon as it finishes; nothing accumulates per probe.
- Both files are size-capped: the diagnostic log rotates, and the stats file drops its oldest entries.
- Waking and changes of network path are detected immediately, and probes in flight across them are discarded. A new network name or router on an unchanged path is picked up by the 15-second identity check.
- A heartbeat in the [diagnostic log](LOGS.md#diagnostic-log) records open files, threads, memory and CPU every 5 minutes, so slow problems show up as trends.
- As a last resort, a watchdog checks resource limits once a minute. From 30 minutes after launch, it can relaunch the app if open file descriptors exceed 1,000 (or half the process limit, if lower), threads exceed 300, memory footprint exceeds 1.5 GB, or the main thread is unresponsive for over 2 minutes. These are threshold checks, not leak detection. The log records why; relaunch requires running an `.app` bundle.
