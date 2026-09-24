# Releasing NetMenu

Cut a GitHub Release from a version tag. CI builds a universal `NetMenu.app` zip, publishes it, and bumps `Casks/netmenu.rb` on `main`.

## Version bump

1. Edit `Info.plist`:
   - `CFBundleShortVersionString` — marketing version, e.g. `1.0.1`
   - `CFBundleVersion` — integer build, increment every release
2. Commit on `main`:

```bash
git add Info.plist
git commit -m "release: 1.0.1"
git tag v1.0.1
git push origin main --tags
```

The tag must be `v` + `CFBundleShortVersionString` or the workflow fails.

## What CI does

`.github/workflows/release.yml` on `v*.*.*`:

1. Builds `dist/NetMenu-VERSION.zip` (`make dist`)
2. Signs with Developer ID when `APPLE_CERTIFICATE_P12` is set
3. Notarizes when the notary secrets are set
4. Creates the GitHub Release
5. Writes `version` + `sha256` into `Casks/netmenu.rb` and pushes `main`

Coworkers then `brew update && brew upgrade --cask netmenu`.

## Optional Apple secrets

Repository **Settings → Secrets and variables → Actions**:

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE_P12` | Base64 of a Developer ID Application `.p12` (`base64 -i cert.p12`) |
| `APPLE_CERTIFICATE_PASSWORD` | Password for that `.p12` |
| `APPLE_NOTARY_KEY` | App Store Connect API key `.p8` body |
| `APPLE_NOTARY_KEY_ID` | Key ID |
| `APPLE_NOTARY_ISSUER_ID` | Issuer UUID |

Without these, CI still ships an ad-hoc–signed zip. First launch needs **Open Anyway** (see the README).

Local notarization:

```bash
xcrun notarytool store-credentials netmenu-notary
make notarize SIGN_ID="Developer ID Application: Your Name (TEAMID)"
```

## Homebrew tap

This repo is the tap (`Casks/netmenu.rb`):

```bash
brew tap SokolskyNikita/netmenu https://github.com/SokolskyNikita/mac-net-monitor-toolbar
brew trust sokolskynikita/netmenu   # Homebrew 7+ refuses untrusted taps
brew install --cask netmenu
```

Do not restore `assignment/` — it is intentionally gone.

Official `homebrew/cask` is a later PR (notability + notarized Gatekeeper pass). After that, updates are `brew bump-cask-pr --version X.Y.Z netmenu`.
