# Architecture and SOLID

NetMenu is a single-target native macOS app. Its useful boundaries are measurement policy, operating-system I/O, presentation and persistence. SOLID guides those boundaries; it does not require a protocol for every struct or a separate package for every directory.

## Responsibilities

- `App/main.swift` selects a CLI command or starts AppKit. `App/CLI.swift` owns the flags, pure argument parsing, diagnostic output and exit-code selection. It reuses the monitoring services; subprocess commands such as nettop and curl remain in their respective adapters.
- `AppDelegate` composes the services, receives macOS lifecycle/path events and updates the menu. It owns the current connection and decides when to discard results or flush history.
- `LiveProbes` schedules independent probe lanes. Its `Transport` closures supply WAN, website, captive-portal, HTTPS fallback and local-router operations. `LocalProbeSession` owns router protocol selection; `LocalProtocols` performs the socket exchanges.
- `Health`, `LiveHealthTracker`, `LocalHealthTracker` and `BandwidthTracker` calculate scores, retain measurement history and aggregate rates without owning menu items or writing files.
- `ProbeStatsWindow` owns the unweighted observations for a stats interval. It keeps packet counts separate from its bounded latency readings, excludes unmeasured pings and clears latency readings on transport changes. These rules differ intentionally from rolling health and menu-bar smoothing.
- `Support/statsevents.swift` defines JSON event schemas. `StatsLog` only appends, repairs and compacts JSONL files. A schema change does not require changing the file writer or a speed-test menu action.
- `SpeedTest` owns transfer measurement and budgeting. `SpeedTransport` supplies one connection's transfer, latency, cancellation and cleanup operations; `URLSessionSpeedTransport` implements them using macOS networking.
- `UI/` owns AppKit readout views, status-bar rendering and app-list presentation. Shared numeric helpers live in `Support/measurements.swift`.
- `MenuReadout` carries a semantic row kind, heading, value, details, numeric score and full accessible text. Renderers use the kind and score for layout, fonts and color; changing wording does not change those decisions. Title-producing conveniences on measurement results share this presentation value with CLI callers.
- Shared external vocabulary lives in `Support/constants.swift`: `NettopFormat` keeps requested columns and both parsers aligned, and HTTP headers and the System Settings bundle ID have single definitions. Domain contracts remain with their owner: `SpeedTestStatus` is a raw-string enum, and process identity builders own their prefixes. Log serialization converts statuses to their existing wire strings.
- `Support/Configuration.swift` owns compiled product defaults in five value types: monitoring, health, speed tests, logging and reliability. Policy components accept their relevant section, and resets preserve it. OS adapters read immutable defaults; tests substitute their I/O. See [Configuration](DEVELOPMENT.md#configuration) for the settings boundary and override example.

## SOLID assessment

| Principle | Application here |
| --- | --- |
| Single responsibility | Keep scoring, stats aggregation, event encoding and file storage independently changeable. AppDelegate remains a relatively broad integration point; new calculations and serialization rules should go in the relevant component. |
| Open/closed | Network mechanisms can be substituted through `SpeedTransport`, `LiveProbes.Transport` and the injected local-protocol probe function. The finite protocol and outcome enums deliberately use exhaustive switches: adding a new protocol should force review of its labeling and interpretation. |
| Liskov substitution | There is little custom production inheritance. Concrete services are generally `final` or value types; AppKit subclasses serve framework roles. Transport replacements must preserve timeout, byte-accounting, cancellation and cleanup behavior. Existing transport tests exercise those contracts; this audit found no reason to introduce a service class hierarchy. |
| Interface segregation | `SpeedTransport` is a small, cohesive connection interface. Probe closures describe individual operations instead of a large monitoring-service interface. Splitting these further would add adapters without an existing consumer that benefits. |
| Dependency inversion | Measurement algorithms accept data, and the schedulers/engines accept network operations. The live router lane now uses the same replacement boundary as WAN probes, allowing scheduler tests without real router access. macOS-specific adapters still call AppKit, sockets, process APIs and diagnostic logging directly. |

## Deliberate limits

The folders are organizational boundaries, not separately compiled modules. Some presentation conveniences remain on result types, such as health labels, speed-test descriptions and connection summaries. `AppDelegate` still builds the menu and coordinates speed-test UI state. Those are reasonable tradeoffs for this app's size; a second frontend or substantially larger menu would justify separate presenters and a speed-test UI controller.

`WiFiScanMonitor` and `AppBandwidthMonitor` remain concrete macOS adapters. Their parsers and decision logic are independently testable, but their full lifecycle tests would benefit from injected log/process runners if those integrations become more complex. The diagnostic logger and shared ICMP socket are intentional process-wide resources, not dependencies that every pure calculation should receive.

## Regression checks

`ProbeStatsTests` covers source transitions, unmeasured/rejected probes, bounded history and HTTPS-only samples. `BandwidthIntegrationTests` checks that completed intervals survive sampling gaps and that the next window starts cleanly. `HealthStatsTests` checks event serialization, including partial and network-invalidated speed tests. `LiveMonitoringTests` uses injected transports to check independent probe progress and stale-result rejection, including a slow router lane alongside successful WAN probes.

Run the complete suite with the commands in [Development](DEVELOPMENT.md#testing). Build the universal executable with `make build` to check the production compilation path as well.
