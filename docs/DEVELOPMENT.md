# Development

## Building from source

Requires macOS 14 or later and the Xcode Command Line Tools (`xcode-select --install`). The full Xcode app is optional. Tests use Swift Testing, so install a toolchain that includes it (Swift 6 or later); `Package.swift` declares Swift tools version 5.9 but does not supply the Testing library.

```bash
git clone https://github.com/SokolskyNikita/mac-net-monitor-toolbar.git
cd mac-net-monitor-toolbar
make run
```

| Command | What it does |
| --- | --- |
| `make build` | Build the universal binary to `build/NetMenu` |
| `make app` | Build, bundle and sign `NetMenu.app` (ad hoc unless `SIGN_ID` is set) |
| `make run` | `make app`, then open it |
| `make test` | Run the Swift Testing suites, including local socket and process integration tests |
| `make check` | Build, run `./build/NetMenu --sample`, print its output and validate its final JSON line with Python 3 |
| `make dist` | Build and sign the app, then package `dist/NetMenu-<version>.zip` and print its SHA-256 |
| `make notarize` | Package, submit for notarization, staple the app and rebuild the zip; requires a signing identity and stored notary credentials |
| `make icon` | Generate `Resources/AppIcon.icns` from the icon script when needed |
| `make clean` | Remove `build/`, `.build/`, `NetMenu.app/` and `dist/` |

The default build targets both `arm64` and `x86_64`, with macOS 14.0 as the deployment target. `ARCHS`, `MIN_OS`, `SWIFT_FLAGS`, `SWIFT_TEST_FLAGS` and `SIGN_ID` can be overridden on the make command line. `make check` performs real internet probes; it is separate from the test suite.

## Command-line modes

The app binary has four modes that run without the menu bar UI:

```bash
NetMenu.app/Contents/MacOS/NetMenu --sample
```

Runs one probe cycle and prints a summary line, a `probe:` detail line and a sample JSON object. It skips router probes and CoreWLAN reads, and does not request Location or Local Network permission. It may still obtain an already-readable Wi-Fi name through system helpers; BSSID and radio details are omitted. This one-shot mode does not build a rolling health history or include the GUI's full diagnostic snapshot.

```bash
NetMenu.app/Contents/MacOS/NetMenu --speedtest
```

Runs the same transfer engine as the menu and prints progress and the full result. Add `--low-data` to use the 8 MB budget. Unlike the GUI, this mode does not automatically detect a metered network or enforce menu cooldowns.

```bash
NetMenu.app/Contents/MacOS/NetMenu --local-sample
```

Discovers the physical IPv4 or IPv6 router, including behind a VPN, and prints twenty local probes at three-second intervals plus their health score, loss, jitter and median latency. Uses the same protocol fallback selection as the menu and names the active protocol. Requires Local Network access. Discards the result if the router changed during the run.

```bash
NetMenu.app/Contents/MacOS/NetMenu --local-probe
```

Tries ICMP, nonrecursive DNS, TCP 443/80 and IPv4 DHCP INFORM once each against the physical router. Prints response times, timeouts, and unavailable reasons. No lease is renewed or configuration applied. This diagnostic intentionally checks all protocols even if ICMP works; normal monitoring stops at the selected protocol.

CLI results are printed to standard output; these modes do not append sample or speed-test records to `stats.jsonl`.

`App/CLI.swift` owns argument parsing and command execution; `main.swift` only dispatches the selected command or starts the GUI. Existing flag handling is preserved: if multiple commands are supplied, priority is `--sample`, `--local-probe`, `--local-sample`, then `--speedtest`, regardless of argument order. `--low-data` modifies speed tests only. Unrecognized arguments are ignored; without a recognized command, the GUI starts.

## Project layout

```text
Sources/NetMenu/
  App/          App lifecycle and entry point
  Monitoring/   Probe scheduling, ICMP/HTTPS, router protocols, health, network identity,
                bandwidth/app attribution, connection snapshots and speed tests
  Support/      Configuration, shared constants, process helpers, logs and watchdog
  UI/           Menu bar rendering
Resources/      App metadata and icon
Tests/          Swift Testing suites
docs/           User and developer documentation, screenshots
scripts/        Icon generation and Homebrew release helpers
Casks/          Homebrew cask
```

The Makefile and Swift package pick up any Swift file under `Sources/NetMenu/` automatically. The monitoring and support files open with comments explaining their design; [How NetMenu works](HOW-IT-WORKS.md) covers the same ground for readers.

See [Architecture and SOLID](ARCHITECTURE.md) for component responsibilities, dependency boundaries and deliberate tradeoffs for a small native app.

## Configuration

Product tuning lives in one file, [`Support/Configuration.swift`](../Sources/NetMenu/Support/Configuration.swift), with five typed sections:

| Type | Contents |
| --- | --- |
| `MonitoringConfig` | Probe cadence/timeouts, website and fallback freshness, router retry policy, bandwidth sampling, identity cache lifetimes and recent trouble/reconnect thresholds. |
| `HealthConfig` | Model identifier, delay/loss calibration, recency weighting, outlier rules, scoring window, startup settling and display smoothing. |
| `SpeedTestConfig` | Standard/Low Data Mode budgets, stream counts, request sizes, warmup/stability rules, timeouts, cooldowns and result lifetime. |
| `LoggingConfig` | Stats cadence, byte limit and compaction retention, probe history cap, diagnostic rotation/throttling and heartbeat cadence. |
| `ReliabilityConfig` | Watchdog resource/hang limits and timing, restart grace periods, helper deadlines and stale-file cleanup. |

These are compiled defaults: edit the file and rebuild. `Configuration` exposes immutable defaults; speed tests retain their `.standard` and `.lowData` presets. Related values are computed, including healthy website cadence, the initial fallback delay, sampler timeout/freshness and retained stats bytes. Component constants such as `Health.window` are aliases to these defaults, not independent settings.

Policy components accept value-type overrides for tests. For example:

```swift
var config = Configuration.health
config.window = 30
var tracker = LocalHealthTracker(config: config)
```

Resetting a tracker preserves its configuration. Low-level OS adapters use the compiled defaults; scheduler tests replace their I/O through transport closures. Keep custom health metadata consistent by passing the same configuration to `HealthStatsSnapshot`. Scoring calibration changes should also update the model identifier and the explanation in [How NetMenu works](HOW-IT-WORKS.md).

UI layout/font values, wire-format constants, unit conversions and defensive buffer bounds stay beside their implementations. User choices remain in `UserDefaults`; `Makefile`, `Package.swift` and `Resources/Info.plist` retain their build, test and bundle responsibilities. There is no runtime JSON/plist settings loader.

Extract strings when they express a shared contract, not merely because the spelling repeats. Shared parser/header vocabulary belongs in `Support/constants.swift`; single-component protocol strings belong in private constants near their owner. Use typed enums for state and `MenuReadout` for structured menu content. One-off messages and JSON keys already owned by `statsevents.swift` can stay inline.

## Testing

`make test` runs every suite. Runtime depends on the machine and toolchain; several tests deliberately wait for timers or timeouts. A few tests use the real system:

- ICMP tests ping `127.0.0.1` and an unroutable test address
- Local protocol tests use temporary loopback sockets for DNS, TCP and DHCP responses
- Process tests launch small helpers and inspect this process's own heap with `heap(1)` to catch leaks
- Speed test engine tests run against a simulated link in real time

No test needs a working internet connection or runs a real Cloudflare speed test. The ICMP timeout test sends a probe to the documentation address `192.0.2.1`, which may leave the Mac through its default route.

If a newer Command Line Tools release reports missing `TestingMacros` with the default Swift Build engine, run `make test SWIFT_TEST_FLAGS="--build-system native"`. The tests need local socket and process access; run them outside a restrictive sandbox.

## Code signing

Builds are signed ad hoc by default (`SIGN_ID=-`). Changes to an ad-hoc signature can invalidate macOS permission grants and cause Location or Local Network prompts to return. Use a stable signing identity to keep the app's identity consistent across rebuilds:

1. Open **Keychain Access → Certificate Assistant → Create a Certificate**.
2. Name it `netmenu-selfsign` and set the type to **Code Signing**.
3. Build with `make run SIGN_ID=netmenu-selfsign`.

For Developer ID signing, notarization and releases, see the [release guide](RELEASING.md).
