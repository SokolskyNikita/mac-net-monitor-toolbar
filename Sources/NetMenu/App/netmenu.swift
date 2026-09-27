// NetMenu — macOS menu bar network monitor
// Human setup (not agent tasks):
// 1. First GUI launch (`make run`) prompts Location (SSID/BSSID) and on macOS 15+ Local Network (gateway). Deny → null fields.
// 2. TCC ties grants to signing identity. Ad-hoc (SIGN_ID=-) resets each rebuild. Persist: Keychain Access → Certificate Assistant
//    → Create a Certificate → name `netmenu-selfsign`, type Code Signing; then `make app SIGN_ID=netmenu-selfsign`.

import AppKit
import CoreLocation

/// Menu-bar latency — one WAN probe cycle every `probeInterval` (wall clock).
let probeInterval: TimeInterval = 3
let staleAfter: TimeInterval = 60
let identityInterval: TimeInterval = 15
let logInterval: TimeInterval = 60
let displayLatWindow = 5

func finiteNonNeg(_ x: Double, max: Double = 600_000) -> Double? {
    guard x.isFinite, x >= 0, x <= max else { return nil }
    return x
}

func median(_ xs: [Double]) -> Double? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted(); let n = s.count
    return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
}

/// Append one sample. A source change drops the previous window so an ICMP reply and a
/// connect-timer fallback cannot be averaged into an RTT no probe returned.
func pushLatency(_ ms: Double, src: String?, into samples: inout [Double], source: inout String?, limit: Int) {
    if src != source {
        samples.removeAll(keepingCapacity: true)
        source = src
    }
    samples.append(ms)
    if samples.count > limit { samples.removeFirst(samples.count - limit) }
}

func buildSampleJSON(id: Identity, secs: Double, latMs: Double?, latMin: Double?, latMax: Double?, latSrc: String?,
                     gwMs: Double?, loss: Double, rejected: Int, down: Double, up: Double, downPeak: Double, upPeak: Double,
                     health: Int? = nil, internetChecks: [String: Bool]? = nil, captive: Bool? = nil) -> [String: Any] {
    func n(_ v: Double?) -> Any { v.map { $0 as Any } ?? NSNull() }
    func i(_ v: Int?) -> Any { v.map { $0 as Any } ?? NSNull() }
    func s(_ v: String?) -> Any { v.map { $0 as Any } ?? NSNull() }
    let fmt = ISO8601DateFormatter(); fmt.formatOptions = [.withInternetDateTime]
    return [
        "ts": fmt.string(from: Date()), "event": "sample", "secs": secs,
        "if": s(id.iface), "type": id.type, "network": s(id.network), "bssid": s(id.bssid), "router": s(id.router),
        "lat_ms": n(latMs), "lat_min": n(latMin), "lat_max": n(latMax), "lat_src": s(latSrc),
        "gw_ms": n(gwMs), "loss": loss, "rejected": rejected, "health": i(health),
        "internet_checks": internetChecks.map { $0 as Any } ?? NSNull(),
        "internet_reachable": internetChecks.map { $0.values.contains(true) as Any } ?? NSNull(),
        "captive": captive.map { $0 as Any } ?? NSNull(),
        "rssi": i(id.rssi), "noise": i(id.noise), "tx_rate_mbps": n(id.txRate), "channel": i(id.channel),
        "down_Bps": down, "up_Bps": up, "down_peak_Bps": downPeak, "up_peak_Bps": upPeak
    ]
}

func jsonLine(_ obj: [String: Any]) -> String? {
    guard let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) else { return nil }
    return s
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusRenderer: StatusBarRenderer?
    var peakItem: NSMenuItem?
    var rateItem: NSMenuItem?
    var topAppsItem: NSMenuItem?
    let appBandwidthMonitor = AppBandwidthMonitor()
    var appBandwidthDisplay = AppBandwidthDisplay()
    static let showThroughputKey = "showThroughputInMenuBar"
    /// Off by default: throughput lives in the menu to keep the menu bar item narrow.
    var showThroughput = UserDefaults.standard.bool(forKey: AppDelegate.showThroughputKey)
    var healthItem: NSMenuItem?
    var speedItem: NSMenuItem?
    var locationManager: CLLocationManager?
    /// Reuse connections across bounded chunks; each task supplies a streaming response delegate.
    let speedSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = SpeedTest.requestTimeout
        c.timeoutIntervalForResource = SpeedTest.requestTimeout
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.httpShouldSetCookies = false
        c.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: c)
    }()
    let statsLog = StatsLog()
    let statsQ = DispatchQueue(label: "netmenu.stats", qos: .utility, autoreleaseFrequency: .workItem)
    let identityLock = NSLock()
    var speedTestRunning = false
    var speedTestCooldownUntil = Date.distantPast
    var bandwidth = BandwidthTracker()
    var lastLatMs: Double?; var lastLatSrc: String?; var lastLatAt: Date?
    var recentLats: [Double] = []
    var health = HealthTracker()
    var healthDisplay = HealthDisplay()
    var lastInternetChecks: [String: Bool]?
    var lastCaptive: Bool?
    var identity = Identity(iface: nil, type: NetType.offline, network: nil, bssid: nil, router: nil, rssi: nil, noise: nil, txRate: nil, channel: nil)
    /// Snapshot for probe queue — avoids DispatchQueue.main.sync (deadlock risk).
    var identityForProbe = Identity(iface: nil, type: NetType.offline, network: nil, bssid: nil, router: nil, rssi: nil, noise: nil, txRate: nil, channel: nil)
    var winStart = BandwidthClock.now()
    var winLats: [Double] = []; var winLatSrc: String?
    var winGW: [Double] = []; var winRejected = 0; var winFailed = 0; var winTotal = 0
    var probeQ = DispatchQueue(label: "netmenu.probe", qos: .utility)
    var idQ = DispatchQueue(label: "netmenu.id", qos: .utility)
    static let maxWinSamples = 120
    static let speedCooldown: TimeInterval = 60
    static let speedFailureCooldown: TimeInterval = 15

    var statsURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let d = base.appendingPathComponent("NetMenu", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("stats.jsonl")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        statsQ.async { [self] in
            do { try statsLog.trimIfNeeded(at: statsURL) }
            catch { NSLog("Unable to trim stats log: %@", error.localizedDescription) }
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusRenderer = StatusBarRenderer(statusItem: item)
        statusRenderer?.render(lat: "✕", health: "", down: "0B", up: "0B",
                               showThroughput: showThroughput, calibrating: false)
        let menu = NSMenu()
        let hi = NSMenuItem(title: "Connection health: measuring…", action: nil, keyEquivalent: "")
        hi.isEnabled = false; menu.addItem(hi); healthItem = hi
        let rate = NSMenuItem(title: "Throughput: —", action: nil, keyEquivalent: "")
        rate.isEnabled = false; menu.addItem(rate); rateItem = rate
        let topApps = NSMenuItem(title: "Top apps: measuring…", action: nil, keyEquivalent: "")
        topApps.isEnabled = false; menu.addItem(topApps); topAppsItem = topApps
        let peak = NSMenuItem(title: "Peak this connection: —", action: nil, keyEquivalent: "")
        peak.isEnabled = false; menu.addItem(peak); peakItem = peak
        let speed = NSMenuItem(title: "No speed test run yet", action: nil, keyEquivalent: "")
        speed.isEnabled = false; menu.addItem(speed); speedItem = speed
        let st = NSMenuItem(title: "Run speed test (up to 8 MB)", action: #selector(runSpeedTest), keyEquivalent: "")
        st.target = self; menu.addItem(st)
        let rev = NSMenuItem(title: "Reveal stats file", action: #selector(revealStats), keyEquivalent: "")
        rev.target = self; menu.addItem(rev)
        menu.addItem(.separator())
        let showRates = NSMenuItem(title: "Show throughput in menu bar", action: #selector(toggleThroughput(_:)),
                                   keyEquivalent: "")
        showRates.target = self; showRates.state = showThroughput ? .on : .off; menu.addItem(showRates)
        menu.addItem(.separator())
        let about = NSMenuItem(title: "About NetMenu", action: #selector(showAbout), keyEquivalent: "")
        about.target = self; menu.addItem(about)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu

        let lm = CLLocationManager()
        locationManager = lm
        if lm.authorizationStatus == .notDetermined {
            lm.requestWhenInUseAuthorization()
        }

        let counters = readCounters(); let now = BandwidthClock.now()
        bandwidth = BandwidthTracker(counters: counters, at: now); winStart = now
        appBandwidthMonitor.start { [weak self] snapshot in
            self?.showAppBandwidth(snapshot)
        }
        idQ.async { [weak self] in self?.refreshIdentity() }
        let t = Timer(timeInterval: BandwidthTracker.sampleInterval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        probeQ.async { [weak self] in self?.probeLoop() }
        Timer.scheduledTimer(withTimeInterval: identityInterval, repeats: true) { [weak self] _ in
            self?.idQ.async { self?.refreshIdentity() }
        }
        Timer.scheduledTimer(withTimeInterval: logInterval, repeats: true) { [weak self] _ in
            self?.flushLog()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        appBandwidthMonitor.stop()
        // Finish queued writes or an in-progress compaction before the process exits.
        statsQ.sync {}
    }

    func setIdentity(_ new: Identity) {
        identity = new
        identityLock.lock(); identityForProbe = new; identityLock.unlock()
    }

    func snapshotIdentity() -> Identity {
        identityLock.lock(); defer { identityLock.unlock() }
        return identityForProbe
    }

    func appendStatsLine(_ line: String) {
        statsQ.async { [self] in
            do { try statsLog.append(line, to: statsURL) }
            catch { NSLog("Unable to append stats log: %@", error.localizedDescription) }
        }
    }

    func refreshIdentity() {
        let new = resolveIdentity()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let changed = !new.sameNetwork(as: self.identity)
            if changed {
                let counters = readCounters(); let now = BandwidthClock.now()
                self.flushLog(at: now)
                self.peakItem?.title = "Peak this connection: —"
                self.bandwidth.resetConnection(counters: counters, at: now)
                self.resetAppBandwidth(at: now)
                self.recentLats = []
                self.lastLatMs = nil; self.lastLatSrc = nil; self.lastLatAt = nil
                self.health.reset(); self.healthDisplay.reset()
                self.lastInternetChecks = nil; self.lastCaptive = nil
            }
            self.setIdentity(new)
            if changed { self.updateTitle() }
        }
    }

    func resetWindow(at: TimeInterval = BandwidthClock.now()) {
        winStart = at; winLats = []; winLatSrc = nil; winGW = []
        winRejected = 0; winFailed = 0; winTotal = 0
        bandwidth.resetWindow()
    }

    func noteLatency(_ ms: Double, src: String?) {
        guard let ms = finiteNonNeg(ms) else { return }
        lastLatMs = ms; lastLatAt = Date()
        pushLatency(ms, src: src, into: &recentLats, source: &lastLatSrc, limit: displayLatWindow)
        pushLatency(ms, src: src, into: &winLats, source: &winLatSrc, limit: Self.maxWinSamples)
    }

    func tick(counters: Counters? = readCounters(), at: TimeInterval = BandwidthClock.now()) {
        topAppsItem?.title = appBandwidthDisplay.title(at: at)
        switch bandwidth.record(counters, at: at) {
        case .gap(let endedAt):
            resetAppBandwidth(at: at)
            flushLog(at: endedAt, resetAt: at)
            updateTitle()
            return
        case .ignored:
            return
        case .displayUpdated, .unavailable:
            updateTitle()
        case .sampled:
            break
        }
        if healthDisplay.publish() { updateTitle() }
        peakItem?.title = "Peak this connection: \(fmtRate(bandwidth.peak.down))↓ / \(fmtRate(bandwidth.peak.up))↑"
    }

    func showAppBandwidth(_ snapshot: AppBandwidthSnapshot?, at: TimeInterval = BandwidthClock.now()) {
        appBandwidthDisplay.record(snapshot, at: at)
        topAppsItem?.title = appBandwidthDisplay.title(at: at)
    }

    func resetAppBandwidth(at: TimeInterval = BandwidthClock.now()) {
        appBandwidthMonitor.reset()
        appBandwidthDisplay.restart(at: at)
        topAppsItem?.title = appBandwidthDisplay.title(at: at)
    }

    func updateTitle() {
        let lat: String
        let report = health.report() == nil ? nil : healthDisplay.shown
        var calibrating = false
        if let at = lastLatAt, Date().timeIntervalSince(at) <= staleAfter,
           let m = finiteNonNeg(median(recentLats) ?? lastLatMs ?? .nan) {
            let n = Int(m.rounded())
            // ~ marks a non-ICMP approximation (HTTP trace)
            lat = lastLatSrc == LatencySource.icmp.rawValue ? "\(n)ms" : "~\(n)ms"
            calibrating = report == nil
        } else { lat = "✕" }
        let healthText = report.map { "\($0.score)%" } ?? (calibrating ? StatusBarRenderer.calibratingText : "")
        statusRenderer?.render(lat: lat, health: healthText,
                               down: fmtRate(bandwidth.display.down), up: fmtRate(bandwidth.display.up),
                               showThroughput: showThroughput, calibrating: calibrating)
        healthItem?.title = healthMenuTitle(report)
        rateItem?.title = "Throughput: \(fmtRate(bandwidth.display.down))↓ / \(fmtRate(bandwidth.display.up))↑"
    }

    @objc func toggleThroughput(_ sender: NSMenuItem) {
        showThroughput.toggle()
        UserDefaults.standard.set(showThroughput, forKey: Self.showThroughputKey)
        sender.state = showThroughput ? .on : .off
        updateTitle()
    }

    func healthMenuTitle(_ report: HealthReport?) -> String {
        guard let h = report else { return "Connection health: measuring…" }
        if !h.internetReachable {
            return "Connection health: 0% (internet sites unreachable)"
        }
        var parts = [String(format: "loss %.0f%%", h.loss * 100)]
        if let j = h.jitterMs { parts.append(String(format: "jitter %.0fms", j)) }
        if let l = h.latencyMs { parts.append(String(format: "latency %.0fms", l)) }
        return "Connection health: \(h.score)% (\(parts.joined(separator: ", ")))"
    }

    func probeLoop() {
        while true {
            let started = Date()
            autoreleasepool {
                let probeIdentity = snapshotIdentity()
                let r = Latency.measure(gateway: probeIdentity.router)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.identity.sameNetwork(as: probeIdentity) else { return }
                    self.winTotal += r.total; self.winRejected += r.rejected; self.winFailed += r.failed
                    self.lastInternetChecks = r.internetChecks
                    self.lastCaptive = r.captive
                    self.health.record(r)
                    self.healthDisplay.add(self.health.report())
                    _ = self.healthDisplay.publish()
                    if let m = r.ms { self.noteLatency(m, src: r.source?.rawValue) }
                    if let g = r.gatewayMs, let g = finiteNonNeg(g) {
                        self.winGW.append(g)
                        if self.winGW.count > Self.maxWinSamples {
                            self.winGW.removeFirst(self.winGW.count - Self.maxWinSamples)
                        }
                    }
                    self.updateTitle()
                }
            }
            let wait = probeInterval - Date().timeIntervalSince(started)
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        }
    }

    func flushLog(at: TimeInterval = BandwidthClock.now(), resetAt: TimeInterval? = nil) {
        let secs = at - winStart
        defer { resetWindow(at: resetAt ?? at) }
        guard secs > 0, bandwidth.window.sampleCount > 0 || !winLats.isEmpty || winTotal > 0 else { return }
        let latMs = median(winLats); let latMin = winLats.min(); let latMax = winLats.max()
        let loss = winTotal > 0 ? Double(winFailed + winRejected) / Double(winTotal) : (winLats.isEmpty ? 1.0 : 0.0)
        let rates = bandwidth.window.average
        let obj = buildSampleJSON(id: identity, secs: secs, latMs: latMs, latMin: latMin, latMax: latMax,
                                  latSrc: winLatSrc, gwMs: median(winGW), loss: winLats.isEmpty ? 1.0 : loss,
                                  rejected: winRejected, down: rates.down, up: rates.up,
                                  downPeak: bandwidth.window.peak.down, upPeak: bandwidth.window.peak.up,
                                  health: health.report() == nil ? nil : healthDisplay.shown?.score,
                                  internetChecks: lastInternetChecks, captive: lastCaptive)
        if let line = jsonLine(obj) { appendStatsLine(line) }
    }

    @objc func revealStats() {
        let url = statsURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Data().write(to: url)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func showAbout(_ sender: Any?) {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "NetMenu",
            .applicationVersion: short,
            .version: build
        ])
    }

    @objc func runSpeedTest() {
        if speedTestRunning { return }
        let now = Date()
        if now < speedTestCooldownUntil {
            let left = Int(ceil(speedTestCooldownUntil.timeIntervalSince(now)))
            speedItem?.title = "Wait \(left)s before retesting"
            return
        }
        speedTestRunning = true
        speedItem?.title = "Testing…"
        let sess = speedSession
        let testIdentity = identity
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = SpeedTest.run(transfer: { direction, size, timeout in
                try SpeedTransfer(direction: direction, size: size).run(session: sess, timeout: timeout)
            }, isCurrentNetwork: {
                self.snapshotIdentity().sameNetwork(as: testIdentity)
            }, progress: { direction in
                DispatchQueue.main.async { [weak self] in
                    self?.speedItem?.title = "Testing \(direction.rawValue)…"
                }
            })
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.speedTestRunning = false
                let changed = !self.identity.sameNetwork(as: testIdentity)
                let status = changed ? "failed" : result.status
                self.speedTestCooldownUntil = Date().addingTimeInterval(
                    status == "ok" ? Self.speedCooldown : Self.speedFailureCooldown)
                self.speedItem?.title = changed ? "Test stopped — network changed" : result.title
                self.speedItem?.toolTip = self.speedItem?.title
                let fmt = ISO8601DateFormatter(); fmt.formatOptions = [.withInternetDateTime]
                let obj: [String: Any] = [
                    "ts": fmt.string(from: Date()), "event": "speedtest", "status": status,
                    "type": testIdentity.type, "network": testIdentity.network as Any? ?? NSNull(),
                    "down_mbps": changed ? NSNull() : result.download.map { $0.mbps as Any } ?? NSNull(),
                    "up_mbps": changed ? NSNull() : result.upload.map { $0.mbps as Any } ?? NSNull(),
                    "errors": changed ? ["network": "network changed"] : result.errors,
                    "bytes_reserved": result.bytesReserved,
                    "down_bytes": result.download?.bytes ?? 0, "up_bytes": result.upload?.bytes ?? 0
                ]
                if let line = jsonLine(obj) { self.appendStatsLine(line) }
            }
        }
    }
}
