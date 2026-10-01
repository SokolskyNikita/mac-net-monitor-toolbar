# Development

## Building from source

Requires the Xcode Command Line Tools (`xcode-select --install`), not the full Xcode app.

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
| `make test` | Run the unit tests |
| `make check` | Print one measurement as JSON via `./build/NetMenu --sample`, without the menu bar UI or permission prompts |
| `make dist` | Package a release zip into `dist/` |
| `make clean` | Remove build output |

## Command-line modes

The app binary has two modes that run without the menu bar UI:

```bash
NetMenu.app/Contents/MacOS/NetMenu --sample
```

Runs one probe cycle and prints a summary line, the per-probe detail line from the [diagnostic log](LOGS.md#diagnostic-log), and a stats JSON entry. It skips the router ping and Wi‑Fi details, so it needs no permissions.

```bash
NetMenu.app/Contents/MacOS/NetMenu --speedtest
```

Runs the same speed test as the menu and prints progress and the full result. Add `--low-data` to use the 8 MB budget.

## Project layout

```text
Sources/NetMenu/
  App/          App lifecycle and entry point
  Monitoring/   Bandwidth, latency (in-process ICMP), health, network identity and speed tests
  Support/      Shared constants, process helpers, stats and diagnostic logs, watchdog
  UI/           Menu bar rendering
Resources/      App metadata and icon
Tests/          Swift Testing suites
docs/           User and developer documentation, screenshots
scripts/        Icon generation and Homebrew release helpers
Casks/          Homebrew cask
```

The Makefile and Swift package pick up any Swift file under `Sources/NetMenu/` automatically. The monitoring and support files open with comments explaining their design; [How NetMenu works](HOW-IT-WORKS.md) covers the same ground for readers.

## Testing

`make test` runs every suite in about 30 seconds. A few tests use the real system:

- ICMP tests ping `127.0.0.1` and an unroutable test address
- Process tests launch small helpers and inspect this process's own heap with `heap(1)` to catch leaks
- Speed test engine tests run against a simulated link in real time

No test needs internet access or uses mobile data.

## Code signing

Builds are signed ad hoc by default (`SIGN_ID=-`). macOS ties permission grants to the signature, so every rebuild asks for Location and Local Network again. A stable local signing identity fixes that:

1. Open **Keychain Access → Certificate Assistant → Create a Certificate**.
2. Name it `netmenu-selfsign` and set the type to **Code Signing**.
3. Build with `make run SIGN_ID=netmenu-selfsign`.

For Developer ID signing, notarization and releases, see the [release guide](RELEASING.md).
