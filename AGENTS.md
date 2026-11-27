# Working on NetMenu

Notes for coding agents. NetMenu is a macOS menu-bar network monitor: one Swift target, no dependencies, built with a Makefile. People install it through the Homebrew cask in this repository.

Almost everything here is guidance with its reason attached, not law. If a reason no longer holds, or you see a better approach, propose the change and say which reason you are setting aside. The only firm items are in [Ask the owner first](#ask-the-owner-first).

## Commands

| Command | Use |
| --- | --- |
| `make test` | Swift Testing suites. Needs no internet. About 30 seconds. |
| `make test-build` | Tests for the build scripts. |
| `make app` | Build and sign `NetMenu.app` (universal, ad hoc). |
| `make check` | One real probe cycle through the CLI. Uses the network. |
| `make dist` | Release zip. |

Running `make test` after a change under `Sources/` or `Tests/` is the cheapest way to catch a regression. See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for the rest.

## Where things are

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): which component owns what.
- [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md): what every probe and number means. Worth reading the relevant section before changing a probe.
- `Sources/NetMenu/Support/Configuration.swift`: the tunables.
- The header comment of `Sources/NetMenu/Monitoring/latency.swift` lists the real hotel and in-flight networks that shaped the probe rules.

## Ask the owner first

These affect other people or cannot be undone, so they are the owner's call each time:

- **Publishing.** Pushing a `v*.*.*` tag publishes a release, and pushing to `main` changes what the Homebrew tap serves.
- **Anything that changes what users must trust.** Examples: a cask step that removes the quarantine flag, a change to how releases are signed, or a new permission prompt.

## Current design decisions and why

Each of these was chosen because of a specific failure. They can change, but a change should answer the reason given.

- **Website checks fetch ordinary pages on ordinary hosts**, not dedicated connectivity-check pages such as `generate_204`, `captive.apple.com` or `detectportal.firefox.com`. Reason: a network can allowlist those pages while blocking everything else, and the app would then report working internet. The test `portalAndAllowlistedConnectivityPagesAreRejected` records this. A past session proposed switching to those pages for their small size and only caught the conflict while wiring it in.
- **Checks verify the response body, not the connection.** Reason: portals and in-flight proxies answer TCP and TLS handshakes, redirects and bare 200s locally. For the same reason a bare connect time is not shown as latency.
- **A probe the Mac could not run is `unmeasured`, not lost.** Reason: a helper that failed to launch or a check cut off by its own deadline says nothing about the network, and counting it would blame the connection for a local fault.
- **Each website check opens a fresh connection with proxies bypassed.** Reason: reused connections, cached sessions and system proxies can succeed when new connections cannot. This is the main thing to weigh before moving checks off `curl`.
- **Probes are spread across operators.** One ping address each for Cloudflare, OpenDNS, Google and Quad9, plus `google.com` by name, and website checks on Fastly and Google. Reason: one operator's trouble should cost one target, not look like a bad connection.
- **Tunables live in `Configuration.swift`.** Reason: tests override a section instead of patching call sites.

## Known pitfalls

Facts about the platform that have cost time before:

- `system_profiler SPAirPortDataType` can trigger Wi-Fi scans. The app reads Wi-Fi details through CoreWLAN and `ipconfig` instead.
- `nettop` busy-spins when its stdin reaches EOF, so its stdin pipe is kept open for the whole run.
- A lost ping is not recorded as lost until its 8-second timeout. Logic that asks whether pings still answer goes wrong if it looks at the newest recorded result; anchoring on when the ping was sent avoids that.
- The app runs for weeks. `runProcess` gives a helper a deadline, reaps it and closes its pipes, and long-running loops are wrapped in `autoreleasepool`, because Foundation objects otherwise pile up on queues that never return.
- `/bin/sh` re-executes itself as another shell just after launch, which breaks tests that depend on process identity. `/bin/bash` does not.
- Swift Testing's `#expect` cannot wrap a call to a mutating method; assign the result first.

## Design

SOLID is a useful guide here, applied in proportion to an app this size:

- Scoring, scheduling, event encoding and file storage are kept independently changeable. New calculations usually belong in the owning component, not in `AppDelegate`.
- Measurement algorithms take data, and schedulers take network operations through `LiveProbes.Transport` and `SpeedTransport`. A new mechanism added behind those can be replaced in tests.
- Exhaustive `switch` over protocol and outcome enums makes a new case force a review.
- A protocol or package is worth adding when a second consumer needs it, not before.

## Tests

- The suite runs without the internet, with I/O replaced through the transport closures. A test that needs a real network is better as a manual check.
- Waiting for the event a test depends on is more reliable than a fixed sleep, which tends to pass alone and fail when the whole suite runs in parallel.
- It is worth checking that a new test fails when its fix is reverted. A test that passes either way has happened here.

## Keeping the docs true

The docs were checked line by line against the code in November 2026. To keep them that way, a behaviour change usually needs a doc change:

- Probe or scoring behaviour: [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md), and [docs/USER-GUIDE.md](docs/USER-GUIDE.md) if the menu wording changes.
- A stats field or log line: [docs/LOGS.md](docs/LOGS.md). Old entries stay in users' files, so it helps to say what older ones contained.
- Scoring calibration: `HealthConfig.model` identifies the model in the stats file, so a recalibration should change it.

## Releasing

The steps are in [docs/RELEASING.md](docs/RELEASING.md). Things to know:

- CI does not run tests, so `make test`, `make test-build` and `make dist` are the only validation a release gets, and they are run locally before tagging.
- CI rewrites the version and checksum in `Casks/netmenu.rb` after each release. Editing them by hand is only needed if that CI step failed.
- Releases are currently ad-hoc signed and not notarized, so macOS blocks each new version until the user allows it. The workflow signs and notarizes by itself once the Apple secrets in the release guide are set.

## Checking a change in the real app

Tests don't cover the running app. After a change to probes or logging, it helps to run the build and read:

- `~/Library/Logs/NetMenu/NetMenu.log`: probe results, one summary line a minute, warnings and errors.
- `~/Library/Application Support/NetMenu/stats.jsonl`: one JSON line a minute.

Most failure paths need a network you won't have, such as a captive portal, an IPv4-only link or a broken resolver. Say plainly what you could not exercise.
