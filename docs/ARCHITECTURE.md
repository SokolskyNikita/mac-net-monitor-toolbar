# Architecture

NetMenu is a single-target native macOS app. Its boundaries are measurement policy, operating-system I/O, presentation and persistence. The folders under `Sources/NetMenu/` are organizational, not separately compiled modules.

## Responsibilities

**App**

- `App/main.swift` selects a CLI command or starts AppKit. `App/CLI.swift` owns the flags, argument parsing, diagnostic output and exit codes, and reuses the monitoring services.
- `AppDelegate` composes the services, receives macOS lifecycle and path events, and updates the menu. It owns the current connection and decides when to discard results or flush history.

**Monitoring**

- `LiveProbes` schedules independent probe lanes. Its `Transport` closures supply the WAN, website, captive-portal, HTTPS fallback and local-router operations, so tests can replace any of them.
- `Latency` holds the probes themselves: ICMP targets, website and captive checks, and the HTTPS trace fallback. `ICMPPinger` and `IPv6Pinger` send echoes in-process.
- `LocalProbeSession` owns router protocol selection; `LocalProtocols` performs the socket exchanges.
- `Health`, `LiveHealthTracker` and `LocalHealthTracker` calculate scores and retain measurement history. `BandwidthTracker` aggregates rates. None of them owns menu items or writes files.
- `ProbeStatsWindow` owns the unweighted observations for one stats interval. Its rules differ on purpose from rolling health and menu-bar smoothing.
- `RouteCache` keeps the answers of `route`, `netstat` and `ipconfig` while the default routes are unchanged, so those helpers do not run on every identity poll.
- `AppBandwidthMonitor` runs `nettop` and pairs its per-process counters with interface totals. `ProcessAncestry` follows each process to its owning app within one sampling window.
- `SpeedTest` owns transfer measurement and budgeting. `SpeedTransport` supplies one connection's transfer, latency, cancellation and cleanup; `URLSessionSpeedTransport` implements it.

**Support**

- `Support/Configuration.swift` owns compiled product defaults in five value types. Policy components accept their section, so tests can override it. See [Configuration](DEVELOPMENT.md#configuration).
- `Support/constants.swift` holds vocabulary shared across components: `NettopFormat` keeps the requested columns and both parsers aligned, and HTTP headers have single definitions.
- `Support/statsevents.swift` defines the JSON event schemas. `StatsLog` only appends, repairs and compacts the JSONL file, so a schema change does not touch the file writer.
- `ProbeLog` condenses probe results for the diagnostic log: one summary line a minute, with full detail around any change of state. `DiagLog` writes and rotates the file.
- `Watchdog` checks resource limits and main-thread responsiveness, and relaunches the app as a last resort.

**UI**

- `UI/` owns the AppKit readout views, status-bar rendering and app-list presentation.
- `MenuReadout` carries a row's kind, heading, value, details, score and accessible text. Renderers decide layout, fonts and color from the kind and score, so changing wording does not change those decisions. The `--local-sample` and `--speedtest` commands print the same value.

## Substitution points

Network mechanisms are replaced through `SpeedTransport`, `LiveProbes.Transport` and the injected local-protocol probe function. Measurement algorithms take data, and schedulers take network operations, which is what lets `LiveMonitoringTests` run without a network. Replacements must preserve timeout, byte-accounting, cancellation and cleanup behavior.

The protocol and outcome enums use exhaustive switches on purpose: adding a protocol should force a review of how it is labelled and interpreted.

## Deliberate limits

- `AppDelegate` is a broad integration point. It still builds the menu and coordinates speed-test UI state. A second frontend or a much larger menu would justify separate presenters.
- Some presentation conveniences remain on result types, such as health labels, speed-test descriptions and connection summaries.
- `AppBandwidthMonitor` is a concrete macOS adapter. Its parsers and decision logic are tested independently; testing its full lifecycle would need an injected process runner.
- The diagnostic logger, the probe log, the route cache and the shared ICMP socket are process-wide resources by design, not dependencies passed to every calculation.
