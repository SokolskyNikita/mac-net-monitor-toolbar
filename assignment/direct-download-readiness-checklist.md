# NetMenu — Direct-download readiness checklist

Audit date: 2026-07-28  
Channel: **your website** (and optionally **Homebrew Cask** / GitHub Releases) — **not** the Mac App Store  
Companion doc: [`app-store-checklist.md`](./app-store-checklist.md) (store path; stricter sandbox)

**Verdict:** Direct download is the natural fit for NetMenu’s current design (`ping`/`route`/etc.). You still need an **Apple Developer Program** membership, a **Developer ID Application** certificate, **Hardened Runtime**, **notarization + stapling**, and a proper download package. App Sandbox is **not** required.

Legend: `[ ]` missing · `[~]` partial · `[x]` done

---

## Why this path vs App Store

| | Mac App Store | Direct download (this doc) |
| --- | --- | --- |
| Sandbox | Required | Optional |
| Shelling out to `/sbin/ping`, `route`, … | Usually blocked | Allowed if signed + notarized |
| Certificate | Mac App Distribution | **Developer ID Application** |
| Gatekeeper | Store-trusted | Needs **notarization ticket** |
| Updates | App Store | You (manual / Sparkle / Homebrew) |
| Review | App Review | Notary scan only (malware / signing) |

---

## Current state (repo facts)

| Item | Status |
| --- | --- |
| Build | `Makefile` + `swiftc` → `NetMenu.app` |
| Signing | Self-signed `netmenu-selfsign` or ad-hoc (`SIGN_ID=-`) — **not** Developer ID |
| Hardened Runtime | **Not enabled** (`codesign` has no `--options runtime`) |
| Notarization | **None** |
| Versions / copyright / icon | **Missing** from `Info.plist` / bundle |
| Architecture | **arm64 only**, binary `minos 26.0` |
| Distribution artifact | Loose `.app` only — no ZIP/DMG release pipeline |
| Website / Homebrew | **None** |

Good news: Location / Local Network usage strings already exist; core app is a single binary bundle that’s easy to package once signing works.

---

## 1. Account and certificates (required)

| Done | Item | Notes |
| --- | --- | --- |
| [ ] | **Apple Developer Program** ($99/yr) | Same membership as App Store; Account Holder creates Developer ID certs |
| [ ] | Create **Developer ID Application** certificate | Used to sign `.app` (and nested binaries). Not “Apple Development” / not Mac App Distribution |
| [ ] | Optional: **Developer ID Installer** | Only if you ship a `.pkg` installer |
| [ ] | App-specific password or API key for **notarytool** | App Store Connect → Users and Access → Keys / app passwords |
| [ ] | Keep signing identity stable | TCC (Location, Local Network) is tied to the signing identity — self-sign resets grants every rebuild |

---

## 2. Bundle polish (users + notarization hygiene)

Not as strict as App Store Connect, but you should still ship a complete app:

| Done | Item | Gap today |
| --- | --- | --- |
| [ ] | `CFBundleShortVersionString` (e.g. `1.0.0`) | Missing |
| [ ] | `CFBundleVersion` (monotonic build, e.g. `1`) | Missing |
| [ ] | `NSHumanReadableCopyright` | Missing |
| [ ] | `LSMinimumSystemVersion` matching real support | Binary already targets **macOS 26** — document on the download page |
| [ ] | App icon (`.icns` in `Contents/Resources`) | Missing — Finder / Dock / Launchpad look broken without it |
| [ ] | Menu item: About / version / Quit already present | Add About with version for support |
| [ ] | Decide arch: **arm64-only** vs universal | arm64-only is fine if the site says “Apple silicon / macOS 26+” |

Sandbox: **skip** unless you want it. Hardened Runtime: **required** for notarization.

---

## 3. Hardened Runtime + code signing (required)

Per [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution):

| Done | Item | Notes for NetMenu |
| --- | --- | --- |
| [ ] | Sign with **Developer ID Application** | Replace `SIGN_ID=netmenu-selfsign` / `-` |
| [ ] | Enable **Hardened Runtime** | `codesign --options runtime …` |
| [ ] | Include **secure timestamp** | `codesign --timestamp …` |
| [ ] | Sign all executables / nested code | Currently one Mach-O — keep it that way |
| [ ] | No `com.apple.security.get-task-allow=true` on release builds | Debug-only entitlement; notary rejects it |
| [ ] | Entitlements plist only if needed | May need hardened-runtime exceptions later (e.g. if something breaks under HR). Start with empty/minimal |
| [ ] | Verify signature | `codesign --verify --deep --strict --verbose=2 NetMenu.app` |
| [ ] | Show identity | `codesign -dv --verbose=4 NetMenu.app` → Authority = Developer ID Application: … |

Suggested Makefile direction (illustrative):

```makefile
SIGN_ID?=Developer ID Application: Your Name (TEAMID)
ENTITLEMENTS?=NetMenu.entitlements

app: build
	mkdir -p NetMenu.app/Contents/MacOS
	cp build/NetMenu NetMenu.app/Contents/MacOS/NetMenu
	cp Info.plist NetMenu.app/Contents/
	codesign --force --options runtime --timestamp \
	  --entitlements "$(ENTITLEMENTS)" \
	  --sign "$(SIGN_ID)" NetMenu.app
```

Test the signed app thoroughly: ICMP ping, gateway ping, Location prompt, Local Network prompt, speed test, stats file — Hardened Runtime can change edge cases.

---

## 4. Notarization + stapling (required for Gatekeeper)

| Done | Item | Command / note |
| --- | --- | --- |
| [ ] | Package for upload | ZIP the `.app` **or** build a UDIF **DMG** / flat **PKG** |
| [ ] | Submit with **`notarytool`** | `xcrun notarytool submit NetMenu.zip --wait --key …` (or Apple ID / keychain profile) |
| [ ] | Fix notary failures from the log | Common: missing runtime, bad entitlements, unsigned nested code |
| [ ] | **Staple** the ticket | `xcrun stapler staple NetMenu.app` (and staple the `.dmg` if you distribute a DMG) |
| [ ] | Validate stapling | `xcrun stapler validate NetMenu.app` |
| [ ] | Gatekeeper assess | `spctl --assess --type execute -vv NetMenu.app` → accepted |
| [ ] | Fresh-Mac test | Download via browser on another account/machine; open without right-click bypass |

If you skip stapling, Gatekeeper can still find the ticket online when the Mac is online — stapling is still strongly recommended so offline first-launch works.

Apple also accepts notarizing the **outer** ZIP/DMG/PKG; staple what users download.

---

## 5. Release artifact for your website

| Done | Item | Recommendation |
| --- | --- | --- |
| [ ] | Choose format | **ZIP of `.app`** (simplest) or **DMG** (nicer UX, drag to Applications) |
| [ ] | If DMG: sign + notarize + staple the DMG too | Required for clean Gatekeeper on the disk image |
| [ ] | Stable download URL per version | e.g. `https://example.com/netmenu/NetMenu-1.0.0.dmg` |
| [ ] | Publish **SHA-256** checksums | Website + GitHub Release notes |
| [ ] | Publish **changelog** / release notes | |
| [ ] | Install instructions | “Download → open DMG → drag to Applications → open once (Gatekeeper)” |
| [ ] | State requirements | Apple silicon, macOS 26+, Location/Local Network optional prompts |
| [ ] | Uninstall blurb | Quit menu item; delete `NetMenu.app`; optional delete `~/Library/Application Support/NetMenu/` |
| [ ] | HTTPS hosting | Always; avoid redirects that break checksum automation |

**GitHub Releases** is a fine CDN for binaries even if the marketing page lives on your site — point the site “Download” button at the Release asset.

---

## 6. Website / legal (lightweight vs App Store)

Not App Review, but still worth shipping:

| Done | Item | Why |
| --- | --- | --- |
| [ ] | Product / download page | Discoverability + trust |
| [ ] | Privacy policy (recommended) | You request Location, Local Network, write stats, hit Cloudflare for speed tests |
| [ ] | Contact / support email or form | Broken downloads, Gatekeeper questions |
| [ ] | License (MIT / proprietary / etc.) | Especially if GitHub + Homebrew |
| [ ] | Export / encryption note (optional) | HTTPS/TLS-only apps are usually fine; no ASC questionnaire unless you later use App Store Connect for something else |

You do **not** need: App Store screenshots at fixed sizes, Privacy Nutrition Label in ASC, age rating, trader status for App Store EU (still comply with local law if you sell commercially).

---

## 7. Auto-updates (optional, website channel)

| Done | Item | Notes |
| --- | --- | --- |
| [ ] | Manual “check releases” is OK for v1 | Link to changelog from the menu |
| [ ] | **Sparkle** (common for indie Mac apps) | Needs ed25519 keys, `appcast.xml`, signed update archives, careful notarization of update packages |
| [ ] | Or rely on **Homebrew** for updates | `brew upgrade --cask netmenu` if you publish a cask |

Skip Sparkle until the notarized ZIP/DMG pipeline is boring and reliable.

---

## 8. Homebrew (optional second channel)

NetMenu is a native `.app` → ship as a **cask**, not a `homebrew/core` formula.

### 8a. Official `homebrew/cask` (harder bar)

Per [Acceptable Casks](https://docs.brew.sh/Acceptable-Casks) / [Adding Software](https://docs.brew.sh/Adding-Software-to-Homebrew):

| Done | Item | Notes |
| --- | --- | --- |
| [ ] | Public, **vendor-endorsed** download URL | Your site or GitHub Releases you control |
| [ ] | Versioned URL + **SHA-256** | Cask `version` + `sha256` must match |
| [ ] | **Signed + notarized**; Gatekeeper must work | Must **not** require SIP/Gatekeeper disabled |
| [ ] | Works on **latest major macOS** | Your minos 26 helps if that’s current |
| [ ] | Declared arch matches binary | arm64-only cask must not claim Intel |
| [ ] | Homepage, license, livecheck / upgrade story | |
| [ ] | Notability / acceptance | Brand-new tiny apps often struggle; may be rejected for lack of popularity — see Homebrew’s package acceptance / notability rules |
| [ ] | PR via `brew create --cask URL` + audit | `brew audit --new --cask`, `brew style --fix --cask` |

### 8b. Your own tap (easier, recommended first)

| Done | Item | Notes |
| --- | --- | --- |
| [ ] | Create `homebrew-netmenu` (or similar) GitHub repo | Users: `brew tap you/netmenu && brew install --cask netmenu` |
| [ ] | Cask points at your notarized Release asset | You control acceptance |
| [ ] | Document the tap on the website | “Install via Homebrew” section |
| [ ] | Later: submit to `homebrew/cask` if popular | Optional promotion path |

Example cask shape (illustrative — fill real URL/sha):

```ruby
cask "netmenu" do
  version "1.0.0"
  sha256 "…"

  url "https://github.com/SokolskyNikita/mac-net-monitor-toolbar/releases/download/v#{version}/NetMenu-#{version}.zip"
  name "NetMenu"
  desc "Menu bar network latency and throughput monitor"
  homepage "https://example.com/netmenu"

  depends_on macos: ">= :tahoe" # adjust to real floor

  app "NetMenu.app"

  zap trash: [
    "~/Library/Application Support/NetMenu",
  ]
end
```

---

## 9. Suggested Makefile / CI pipeline

| Done | Item |
| --- | --- |
| [ ] | `make app` → Developer ID sign with runtime + timestamp |
| [ ] | `make zip` / `make dmg` → distributable artifact |
| [ ] | `make notarize` → `notarytool submit` + `stapler staple` |
| [ ] | `make verify` → `codesign` + `spctl` + `stapler validate` |
| [ ] | CI (GitHub Actions on macOS) with cert in secrets | Or sign locally and attach to GitHub Release |
| [ ] | Tag releases `v1.0.0` matching `CFBundleShortVersionString` |

You can stay on Makefile/`swiftc` for this channel — **no Xcode project required** (unlike a smooth App Store upload). Xcode Organizer is optional convenience.

---

## 10. Pre-publish smoke test

| Done | Check |
| --- | --- |
| [ ] | Download artifact on a Mac that never saw the app |
| [ ] | Double-click opens without “can’t be opened because developer cannot be verified” |
| [ ] | Menu bar item appears; Quit works |
| [ ] | Deny Location → app still runs (SSID may be generic) |
| [ ] | Deny Local Network → no crash |
| [ ] | Speed test completes; stats file written |
| [ ] | Copy to `/Applications` and relaunch (no App Translocation weirdness) |
| [ ] | `spctl --assess` clean on the downloaded file |

---

## 11. Suggested work order

1. Enroll / confirm **Developer Program**; create **Developer ID Application** cert.  
2. Add version / copyright / icon to `Info.plist` + Resources.  
3. Update `Makefile` for **Hardened Runtime + timestamp + Developer ID**.  
4. Build → **notarytool** → **staple** → `spctl` verify.  
5. Publish ZIP/DMG + checksums on **GitHub Releases** and/or your site.  
6. Write a short download page + privacy blurb.  
7. Optional: personal **Homebrew tap**; later chase `homebrew/cask`.  
8. Optional later: Sparkle auto-update.

---

## 12. Quick gap scorecard

| Area | Ready? |
| --- | --- |
| Feature complete enough to ship | Mostly yes |
| Developer ID + Hardened Runtime | No |
| Notarization + staple | No |
| Versioned ZIP/DMG + checksums | No |
| Website / GitHub Release page | No |
| Privacy blurb | No |
| Homebrew tap / cask | No |
| App Sandbox rewrite | **Not needed** for this channel |

---

## Reference links

- [Distributing software on macOS](https://developer.apple.com/macos/distribution/)
- [Developer ID](https://developer.apple.com/developer-id/)
- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow) (`notarytool`)
- [Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution) (staple DMG/ZIP)
- [Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime)
- [Homebrew: Adding software](https://docs.brew.sh/Adding-Software-to-Homebrew)
- [Homebrew: Acceptable Casks](https://docs.brew.sh/Acceptable-Casks)
- [Homebrew: Cask Cookbook](https://docs.brew.sh/Cask-Cookbook)
- [Sparkle](https://sparkle-project.org/documentation/) (optional updates)
