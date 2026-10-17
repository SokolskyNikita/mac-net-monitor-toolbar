# Releasing NetMenu

Cut a GitHub Release from a version tag. CI builds a universal `NetMenu.app` zip, publishes it, and bumps `Casks/netmenu.rb` on `main`.

## Version bump

Run the commands below from the repository root.

1. Edit `Resources/Info.plist`:
   - `CFBundleShortVersionString` — the next marketing version in `X.Y.Z` form
   - `CFBundleVersion` — integer build, increment every release
2. Run `make test`, `make test-build` and `make dist`. The release workflow does not run tests, so validate the intended release locally before tagging.
3. Commit the version bump on `main`, then tag that commit (the commands read the version you just set):

```bash
git add Resources/Info.plist
release_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
git commit -m "release: ${release_version}"
git tag "v${release_version}"
git push origin main "v${release_version}"
```

The tag must be `v` + `CFBundleShortVersionString` or the workflow fails.

## What CI does

`.github/workflows/release.yml` runs on pushes of `v*.*.*` tags, using `macos-15`:

1. Checks that the tag matches `CFBundleShortVersionString`.
2. Imports the Developer ID certificate when `APPLE_CERTIFICATE_P12` is set.
3. Runs `make dist`, building the universal binary and signing the app with that identity, or ad hoc otherwise.
4. When both `APPLE_NOTARY_KEY` and the certificate are set, submits the zip for notarization, staples the app and rebuilds the zip. The remaining notary credentials must also be valid.
5. Creates the GitHub Release and uploads `dist/NetMenu-VERSION.zip`.
6. Computes the final zip's SHA-256, checks out the latest `origin/main`, runs `scripts/update-cask.sh`, and commits and pushes the cask update if it changed.

The workflow requests `contents: write`; repository rules must allow its token to create a release and push the cask commit to `main`. A failed cask push can leave a published release with the tap still pointing at the previous version.

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

Without a certificate, CI ships an ad-hoc–signed zip. With only the certificate, it ships a Developer ID–signed but unnotarized zip. First launch of an unnotarized build may need **Open Anyway** (see [First launch](SETUP.md#first-launch)).

Local notarization:

```bash
xcrun notarytool store-credentials netmenu-notary
make notarize SIGN_ID="Developer ID Application: Your Name (TEAMID)"
```

## Homebrew tap

This repo is the tap (`Casks/netmenu.rb`):

```bash
brew tap SokolskyNikita/netmenu https://github.com/SokolskyNikita/mac-net-monitor-toolbar
brew install --cask sokolskynikita/netmenu/netmenu
```

Installing by the full cask name [trusts that cask automatically](https://docs.brew.sh/Tap-Trust#installing-from-a-tap); a separate `brew trust` command is unnecessary. The explicit tap URL is required because this repository is not named `homebrew-netmenu`.

The supported installation route is this repository's tap. CI maintains its cask directly; no `brew bump-cask-pr` step is part of this release workflow.
