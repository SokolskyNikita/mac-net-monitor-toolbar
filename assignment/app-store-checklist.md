# NetMenu — Mac App Store readiness checklist

Audit date: 2026-07-28  
App: **NetMenu** (`me.sokolsky.netmenu`) — macOS menu bar network monitor  
Sources: current repo audit, [Apple submitting guide](https://developer.apple.com/app-store/submitting/), [Preparing for distribution](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution/), [macOS distribution](https://developer.apple.com/macos/distribution/), [Upcoming requirements](https://developer.apple.com/news/upcoming-requirements/), [App privacy details](https://developer.apple.com/app-store/app-privacy-details/), [Screenshot specs](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/), App Review Guidelines, BrightData research.

**Verdict:** Not App Store–ready. The biggest blockers are (1) no App Sandbox (mandatory for Mac App Store) while the app shells out to system binaries, (2) no Apple Developer Program signing / Xcode distribution pipeline, and (3) missing store metadata (icon, versions, privacy policy, screenshots, App Store Connect record).

Legend: `[ ]` missing · `[~]` partial · `[x]` done

---

## Current state (repo facts)

| Item | Status |
| --- | --- |
| Build | `swiftc` + `Makefile` → `.app` bundle (no `.xcodeproj` / `.xcworkspace`) |
| Signing | Self-signed `netmenu-selfsign`; **TeamIdentifier=not set** |
| Architecture | **arm64 thin only** (`Mach-O 64-bit executable arm64`) |
| Min OS / SDK (binary) | `minos 26.0`, `sdk 26.2` |
| UI | `LSUIElement` menu bar accessory (no main window / About panel) |
| Privacy strings | Has `NSLocationUsageDescription`, `NSLocalNetworkUsageDescription` |
| Versions / copyright / icon | **Absent** from `Info.plist` / bundle |
| Sandbox / entitlements | **None** |
| App Store Connect / TestFlight | **None** |

Risky behaviors for sandbox review:

- Spawns `/sbin/ping`, `/sbin/route`, `/usr/sbin/networksetup`, `/usr/sbin/ipconfig`, `/usr/sbin/system_profiler`
- Outbound network: ICMP to `1.1.1.1` / `8.8.8.8`, TLS to `one.one.one.one:443`, HTTPS speed test to `speed.cloudflare.com`
- Location / CoreWLAN for SSID/BSSID
- Writes `~/Library/Application Support/NetMenu/stats.jsonl` (SSID, BSSID, router, latency, rates)

---

## 1. Account, legal, and distribution path

| Done | Item | Notes for NetMenu |
| --- | --- | --- |
| [ ] | **Apple Developer Program** membership ($99/yr) | Required for Mac App Store certs, App Store Connect, TestFlight |
| [ ] | Accept **Paid Applications** / program agreements in App Store Connect | Blocks paid or free listing setup |
| [ ] | Decide: **Mac App Store** vs **Developer ID + notarization** (outside store) | Store requires App Sandbox; outside does not. Current design fits notarized outside-store better unless probing is rewritten |
| [ ] | **EU DSA trader status** (if distributing in EU) | Required for EU storefront availability |
| [ ] | Host a public **Privacy Policy** URL | Required in App Store Connect metadata (guideline 5.1.1) |
| [ ] | Terms / EULA (Apple standard or custom URL) | Needed if you charge or want custom terms |
| [ ] | Support URL + marketing URL | Support URL effectively required for product page |

---

## 2. Project / packaging (hard requirements)

Per [Preparing your app for distribution](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution/):

| Done | Item | Gap vs NetMenu today |
| --- | --- | --- |
| [ ] | **Xcode project** (or equivalent archive workflow) | Makefile/`swiftc` cannot produce a normal App Store archive + upload path |
| [ ] | Assign target to Developer **Team** | Self-sign only today |
| [~] | Stable **bundle ID** | `me.sokolsky.netmenu` exists — freeze before first upload (immutable after) |
| [ ] | **`CFBundleShortVersionString`** (marketing version) | Missing — required by App Store |
| [ ] | **`CFBundleVersion`** (build number) | Missing — must increment every upload |
| [ ] | **`NSHumanReadableCopyright`** | Missing — required for macOS before upload |
| [ ] | **`LSMinimumSystemVersion`** (and intentional floor) | Binary already targets **macOS 26**; document/confirm — excludes older Macs |
| [ ] | **`LSApplicationCategoryType`** | Missing (e.g. `public.app-category.utilities`) — must align with App Store Connect category |
| [ ] | **App icon** (Asset Catalog and/or Icon Composer / Liquid Glass) | No `AppIcon`, no `Resources/` icons |
| [ ] | **1024×1024 App Store icon** | Missing |
| [ ] | Remove **`com.apple.quarantine`** xattrs from packaged files | Upload rejection since 2025-02-18 if present |
| [ ] | Prefer **Archive → Organizer → Distribute App** (or `xcodebuild` + Transporter) | No archive pipeline today |

Optional but recommended:

| Done | Item |
| --- | --- |
| [ ] | About panel / version visible somewhere (menu item) for macOS polish |
| [ ] | Universal binary **or** explicit Apple silicon–only policy (see §6) |

---

## 3. App Sandbox, entitlements, hardened runtime (critical)

From Apple: **Mac App Store → App Sandbox required**. Outside store → Hardened Runtime + notarization required; sandbox optional.

| Done | Item | Notes for NetMenu |
| --- | --- | --- |
| [ ] | Enable **App Sandbox** | **Blocker** for Mac App Store |
| [ ] | Entitlement: outgoing network client | Speed test + TLS probe |
| [ ] | Entitlement / TCC: **location** (SSID/BSSID via CoreWLAN) | Already prompts; must match sandbox + privacy strings |
| [ ] | Local Network usage (macOS 15+) | Already has usage string; confirm sandbox behavior for gateway ping |
| [ ] | Application Support write path stays inside container | Sandbox remaps container — verify `stats.jsonl` path still OK |
| [ ] | **Hardened Runtime** | Needed for notarization; good practice for store builds too |
| [ ] | **Rewrite process spawning** | Sandbox will block or neuter `Process` → `/sbin/ping`, `route`, `networksetup`, `ipconfig`, `system_profiler`. Replace with Network framework / sysctl / CoreWLAN / NWPathMonitor (or ship as notarized non–App Store app) |
| [ ] | Entitlements must match declared functionality | Guideline **2.4.5** — unused entitlements → rejection |

**Decision fork (do this first):**

1. **Mac App Store** → redesign probes without shelling out; sandbox + Mac App Distribution cert.  
2. **Direct download** → Developer ID Application cert + notarization; sandbox optional; keep `ping`/`route` if Gatekeeper-friendly.

---

## 4. Privacy, data, and manifests

| Done | Item | NetMenu relevance |
| --- | --- | --- |
| [ ] | **App Privacy** questionnaire (Privacy Nutrition Label) in App Store Connect | Required to submit. Local logging of network name, BSSID, router, latency, throughput — disclose even if “not linked / not used for tracking” |
| [ ] | Privacy Policy covers Location, Local Network, on-device stats file, Cloudflare speed-test traffic | Speed test sends data to a third party |
| [ ] | Confirm purpose strings are accurate and user-facing | Present for Location + Local Network; keep them specific |
| [ ] | Consider `NSLocationWhenInUseUsageDescription` if required by target SDK | Currently only `NSLocationUsageDescription` |
| [ ] | **Privacy Manifest** (`PrivacyInfo.xcprivacy`) if using Required Reason APIs | Audit for file-timestamp / disk-space / etc. APIs (rule since 2024-05-01) |
| [ ] | No tracking / ATT unless you add analytics SDKs | Currently none — keep label honest |
| [ ] | Data retention / “Reveal stats file” UX disclosure | Optional product polish; helps review |

Likely nutrition-label categories to evaluate (not legal advice — fill after inventory):

- **Location** (precise/coarse — Wi‑Fi SSID/BSSID via location permission)
- **Product Interaction** / diagnostics-like usage (local stats)
- **Other Diagnostic Data** or similar for latency/loss samples
- Declare Cloudflare contact only if data leaves device during speed test in a way that counts under Apple’s definitions

---

## 5. Signing, certificates, upload

| Done | Item |
| --- | --- |
| [ ] | Register **App ID** for `me.sokolsky.netmenu` (explicit) |
| [ ] | **Mac App Distribution** certificate (store) *or* **Developer ID Application** (outside) |
| [ ] | **Mac App Store / Mac App Store Connect** provisioning profile |
| [ ] | Sign with Apple team identity (not `netmenu-selfsign`) |
| [ ] | Create **app record** in App Store Connect (macOS platform) |
| [ ] | Upload build (Xcode Organizer / Transporter / `altool` successor tooling) |
| [ ] | Export compliance / encryption answers (`ITSAppUsesNonExemptEncryption` often `false` for HTTPS-only) |

---

## 6. Architecture and availability

| Done | Item | Notes |
| --- | --- | --- |
| [~] | arm64-only build | Allowed for Apple silicon–only listing if **min OS ≥ macOS 12** and app **never** shipped Intel — you already require macOS 26, so silicon-only is OK if intentional |
| [ ] | Set availability / required device capabilities in App Store Connect | Confirm “Apple silicon Macs only” if not shipping `x86_64` |
| [ ] | Test on clean macOS user account (TCC prompts: Location, Local Network) | Ad-hoc signing currently resets TCC each rebuild — production signing must be stable |

---

## 7. App Store Connect product page (metadata)

From App Store pathway / product page guidance:

| Done | Item | Spec / note |
| --- | --- | --- |
| [ ] | App name, subtitle, description, keywords | Accurate for a menu bar network utility |
| [ ] | Primary/secondary **category** (e.g. Utilities / Developer Tools) | Match `LSApplicationCategoryType` |
| [ ] | **Age rating** questionnaire (updated system; macOS 26+ shows new ratings) | Answer in App Information |
| [ ] | **Mac screenshots** (1–10, no alpha) | **Required.** Accepted sizes (16:10): **1280×800**, 1440×900, 2560×1600, 2880×1800 |
| [ ] | Optional app preview video | |
| [ ] | App Privacy details completed | Blocks submit if incomplete |
| [ ] | Optional **Accessibility Nutrition Label** | VoiceOver / larger text / etc. if you support them |
| [ ] | Pricing / availability (175 storefronts) | Free vs paid |
| [ ] | Review notes for App Review | Explain menu-bar-only UI, Location why, Local Network why, how to run speed test |
| [ ] | Contact info + demo account if any gated features | N/A unless you add accounts |

Screenshot tip for `LSUIElement` apps: capture menu bar status item + open menu (and optionally stats file / speed-test result) on a clean desktop; App Review must understand the UI.

---

## 8. Quality, review guidelines, testing

| Done | Item | Risk for NetMenu |
| --- | --- | --- |
| [ ] | Read **App Review Guidelines** (Safety, Performance, Business, Design, Legal) | |
| [ ] | Guideline **2.1** — app complete, no placeholder content | Mostly fine if polished |
| [ ] | Guideline **2.3** — metadata accurate; screenshots match real UI | |
| [ ] | Guideline **2.4.5** — sandbox entitlements justified | High risk until sandbox redesign |
| [ ] | Guideline **4.2** — minimum functionality | Menu bar utilities can pass if useful and reliable; ensure not a thin script wrapper narrative |
| [ ] | Guideline **5.1** — privacy / data use | Stats file + Cloudflare + location |
| [ ] | **TestFlight** (Mac) internal then external | Recommended before first review |
| [ ] | XCTest / UI smoke tests where practical | Optional |
| [ ] | Crash-free runs: deny Location, deny Local Network, offline, VPN, Ethernet | Code already nulls some fields — verify UX |
| [ ] | Build with current **Xcode 26** toolchain for upload | Binary already linked against SDK 26.2; keep using Xcode 26+ for store uploads. Note: Apr 28, 2026 SDK floor is explicit for iOS/iPadOS/tvOS/visionOS/watchOS; still use latest Xcode for macOS submissions |

---

## 9. Suggested work order

1. **Choose channel:** Mac App Store (sandbox rewrite) vs Developer ID notarized (faster path for current `ping`/`route` design).  
2. Create **Xcode macOS App** target; move `netmenu.swift` / split sources; add icon, versions, copyright, category.  
3. If store: implement **sandbox-safe networking** (drop shelling out); add entitlements; verify Location / Local Network.  
4. Enroll / configure **Developer Program** signing + App Store Connect app record.  
5. Write **Privacy Policy**; fill **App Privacy** label; add Mac **screenshots**.  
6. Archive → TestFlight → fix review feedback → Submit for Review.

---

## 10. Quick gap scorecard

| Area | Ready? |
| --- | --- |
| Core feature code (menu bar monitor) | Mostly |
| Store-compliant packaging (versions, icon, copyright) | No |
| Sandbox / entitlements | No — **main technical blocker for Mac App Store** |
| Apple signing & App Store Connect | No |
| Privacy policy + nutrition label | No |
| Screenshots / listing copy | No |
| TestFlight / App Review prep | No |

---

## Reference links

- [Submit your apps](https://developer.apple.com/app-store/submitting/)
- [App Store pathway / get started](https://developer.apple.com/app-store/get-started/)
- [Preparing your app for distribution](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution/)
- [Distributing software on macOS](https://developer.apple.com/macos/distribution/)
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [App privacy details](https://developer.apple.com/app-store/app-privacy-details/)
- [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
- [Upcoming requirements](https://developer.apple.com/news/upcoming-requirements/)
- [App Store Connect Help](https://developer.apple.com/help/app-store-connect/)
