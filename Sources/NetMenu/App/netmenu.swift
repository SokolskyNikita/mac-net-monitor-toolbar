// NetMenu — macOS menu bar network monitor
// Human setup (not agent tasks):
// 1. First GUI launch (`make run`) prompts Location (SSID/BSSID) and on macOS 15+ Local Network (gateway). Deny → null fields.
// 2. TCC ties grants to signing identity. Ad-hoc (SIGN_ID=-) resets each rebuild. Persist: Keychain Access → Certificate Assistant
//    → Create a Certificate → name `netmenu-selfsign`, type Code Signing; then `make app SIGN_ID=netmenu-selfsign`.

import AppKit
import CoreLocation
import Network

/// Menu-bar latency — one WAN probe cycle every `probeInterval` (wall clock).
let probeInterval: TimeInterval = 3
let staleAfter: TimeInterval = 60
let identityInterval: TimeInterval = 15
let logInterval: TimeInterval = 60
/// Resource and progress summary in the diagnostic log.
let heartbeatInterval: TimeInterval = 300
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
    return [
        "ts": isoTimestamp(), "event": "sample", "secs": secs,
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

private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
}()
private let isoLock = NSLock()

func isoTimestamp(_ date: Date = Date()) -> String {
    isoLock.lock(); defer { isoLock.unlock() }
    return isoFormatter.string(from: date)
}

/// Removes temporary files a crashed run left behind. Recent ones may belong to a running copy.
func removeStaleTempFiles(olderThan age: TimeInterval = 600) {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory
    guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
    var removed = 0
    for name in names where name.hasPrefix(Latency.tempPrefix) {
        let url = dir.appendingPathComponent(name)
        guard let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) > age else { continue }
        if (try? fm.removeItem(at: url)) != nil { removed += 1 }
    }
    if removed > 0 { DiagLog.shared.info("app", "removed \(removed) stale temporary files") }
}

func jsonLine(_ obj: [String: Any]) -> String? {
    guard let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) else { return nil }
    return s
}

class AppDelegate: NSObject, NSApplicationDelegate, CLLocationManagerDelegate {
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
    let statsLog = StatsLog()
    let statsQ = DispatchQueue(label: "netmenu.stats", qos: .utility, autoreleaseFrequency: .workItem)
    let identityLock = NSLock()
    var speedTestRunning = false
    var speedControl: SpeedTestControl?
    var speedActionItem: NSMenuItem?
    /// Low Data Mode or a metered (e.g. iPhone hotspot) path: smaller speed test budget.
    var pathIsLowData = false
    var speedTestCooldownUntil = Date.distantPast
    var bandwidth = BandwidthTracker()
    var lastLatMs: Double?; var lastLatSrc: String?; var lastLatAt: Date?
    var recentLats: [Double] = []
    var health = HealthTracker()
    var healthDisplay = HealthDisplay()
    var lastInternetChecks: [String: Bool]?
    /// Bumped on wake and network path changes; a probe cycle that started under an older epoch
    /// straddled the change and is discarded. Guarded by `identityLock`.
    var probeEpoch = 0
    var pathMonitor: NWPathMonitor?
    var lastPathSummary: String?
    /// Bumped on every network path change; a speed test compares it with its start value.
    /// Guarded by `identityLock`. Separate from `probeEpoch`, which the speed test bumps itself.
    var pathGeneration = 0
    let watchdog = Watchdog()
    let launchedAt = BandwidthClock.now()
    var lastCycleAt: TimeInterval?
    var lastWakeAt = BandwidthClock.now()
    var cycleCount = 0
    static let runningPIDKey = "runningPID"
    var termSource: DispatchSourceSignal?
    var lastCaptive: Bool?
    var identity = Identity(iface: nil, type: NetType.offline, network: nil, bssid: nil, router: nil, rssi: nil, noise: nil, txRate: nil, channel: nil)
    /// Snapshot for probe queue — avoids DispatchQueue.main.sync (deadlock risk).
    var identityForProbe = Identity(iface: nil, type: NetType.offline, network: nil, bssid: nil, router: nil, rssi: nil, noise: nil, txRate: nil, channel: nil)
    var winStart = BandwidthClock.now()
    var winLats: [Double] = []; var winLatSrc: String?
    var winGW: [Double] = []; var winRejected = 0; var winFailed = 0; var winTotal = 0
    var probeQ = DispatchQueue(label: "netmenu.probe", qos: .utility, autoreleaseFrequency: .workItem)
    var idQ = DispatchQueue(label: "netmenu.id", qos: .utility, autoreleaseFrequency: .workItem)
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
        // killall and package upgrades send SIGTERM; quit normally so logs are flushed.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { DiagLog.shared.info("app", "SIGTERM received"); NSApp.terminate(nil) }
        term.resume()
        termSource = term
        ResourceUsage.raiseFileLimit()
        DiagLog.shared.enable()
        logLaunch()
        statsQ.async { [self] in
            do { try statsLog.trimIfNeeded(at: statsURL) }
            catch { DiagLog.shared.error("stats", "unable to trim stats log: \(error.localizedDescription)") }
            removeStaleTempFiles()
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
        let st = NSMenuItem(title: speedActionTitle(), action: #selector(runSpeedTest), keyEquivalent: "")
        st.target = self; menu.addItem(st); speedActionItem = st
        let rev = NSMenuItem(title: "Reveal stats file", action: #selector(revealStats), keyEquivalent: "")
        rev.target = self; menu.addItem(rev)
        let diag = NSMenuItem(title: "Reveal diagnostic log", action: #selector(revealDiagnosticLog), keyEquivalent: "")
        diag.target = self; menu.addItem(diag)
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
        lm.delegate = self
        locationManager = lm
        DiagLog.shared.info("network", "location access: \(Self.describe(lm.authorizationStatus))")
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
        // Common modes: keep firing while the menu is open.
        addTimer(identityInterval) { [weak self] in self?.idQ.async { self?.refreshIdentity() } }
        addTimer(logInterval) { [weak self] in self?.flushLog() }
        addTimer(heartbeatInterval) { [weak self] in self?.heartbeat() }
        observeSleepAndWake()
        startPathMonitor()
        watchdog.start()
        heartbeat()
    }

    func addTimer(_ interval: TimeInterval, _ fire: @escaping () -> Void) {
        let t = Timer(timeInterval: interval, repeats: true) { _ in fire() }
        t.tolerance = min(1, interval / 10)
        RunLoop.main.add(t, forMode: .common)
    }

    func applicationWillTerminate(_ notification: Notification) {
        appBandwidthMonitor.stop()
        pathMonitor?.cancel()
        // Finish queued writes or an in-progress compaction before the process exits.
        statsQ.sync {}
        let defaults = UserDefaults.standard
        if defaults.integer(forKey: Self.runningPIDKey) == Int(getpid()) { defaults.removeObject(forKey: Self.runningPIDKey) }
        DiagLog.shared.info("app", "quit after \(String(format: "%.1f", (BandwidthClock.now() - launchedAt) / 3600))h")
        DiagLog.shared.flush()
    }

    // MARK: - Diagnostics

    func logLaunch() {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
        DiagLog.shared.info("app", "launch NetMenu \(version) pid=\(getpid()) macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
            + " path=\(Bundle.main.bundlePath) fd_limit=\(ResourceUsage.softFileLimit().map(String.init) ?? "?")")
        // A previous copy that is gone but never cleared its pid ended without quitting normally.
        let defaults = UserDefaults.standard
        let previous = Int32(truncatingIfNeeded: defaults.integer(forKey: Self.runningPIDKey))
        if previous > 0, previous != getpid(), kill(previous, 0) != 0, errno == ESRCH {
            DiagLog.shared.warn("app", "previous run (pid \(previous)) ended without quitting normally;"
                                + " crash reports, if any, are in ~/Library/Logs/DiagnosticReports")
        }
        defaults.set(Int(getpid()), forKey: Self.runningPIDKey)
    }

    func heartbeat() {
        let now = BandwidthClock.now()
        let mb = ResourceUsage.footprintBytes().map { String(format: "%.1f", Double($0) / 1e6) } ?? "?"
        let sinceCycle = lastCycleAt.map { String(format: "%.0fs", now - $0) } ?? "never"
        let cpu = ResourceUsage.cpuSeconds()
        let uptime = max(1, now - launchedAt)
        let cpuText = String(format: " cpu=%.1fs(%.2f%%) helpers_cpu=%.1fs(%.2f%%)",
                             cpu.own, cpu.own / uptime * 100, cpu.helpers, cpu.helpers / uptime * 100)
        DiagLog.shared.info("heartbeat", String(format: "uptime=%.2fh", (now - launchedAt) / 3600)
            + " fds=\(ResourceUsage.openFileDescriptors().map(String.init) ?? "?")"
            + " threads=\(ResourceUsage.threadCount().map(String.init) ?? "?") footprint=\(mb)MB"
            + " last_cycle=\(sinceCycle) ago\(cpuText) \(Diagnostics.shared.summary)"
            + " network=\(identity.network ?? "-") type=\(identity.type)")
        // The probe loop has no unbounded waits, so a long silence while awake means a bug.
        let quiet = now - max(lastCycleAt ?? launchedAt, lastWakeAt)
        if quiet > 120 {
            DiagLog.shared.error("probe", "no completed probe cycle for \(Int(quiet))s while awake", throttleKey: "probe-stall")
        }
    }

    func observeSleepAndWake() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            DiagLog.shared.info("power", "sleep")
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            DiagLog.shared.info("power", "wake")
            self.lastWakeAt = BandwidthClock.now()
            // Wi-Fi takes a few seconds to rejoin; that is not loss on the network we measure.
            self.restartHealth(reason: "wake")
            self.idQ.async { [weak self] in self?.refreshIdentity() }
        }
    }

    /// Network framework reports path changes at once; the 15s identity poll would lag.
    func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let lowData = path.isExpensive || path.isConstrained
            DispatchQueue.main.async { [weak self] in
                guard let self, lowData != self.pathIsLowData else { return }
                self.pathIsLowData = lowData
                if !self.speedTestRunning { self.speedActionItem?.title = self.speedActionTitle() }
            }
            let ifaces = path.availableInterfaces.map { "\($0.name):\($0.type)" }.joined(separator: ",")
            let summary = "\(path.status) [\(ifaces)]" + (path.isExpensive ? " expensive" : "")
                + (path.isConstrained ? " constrained" : "")
            DispatchQueue.main.async { [weak self] in
                guard let self, summary != self.lastPathSummary else { return }
                let first = self.lastPathSummary == nil
                self.lastPathSummary = summary
                DiagLog.shared.info("network", "path \(summary)")
                guard !first else { return }
                self.identityLock.lock(); self.pathGeneration &+= 1; self.identityLock.unlock()
                self.bumpEpoch()
                self.health.settle()
                self.idQ.async { [weak self] in self?.refreshIdentity() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "netmenu.path", qos: .utility))
        pathMonitor = monitor
    }

    /// Wi-Fi names need Location access; re-read them as soon as it changes, not on the next poll.
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DiagLog.shared.info("network", "location access: \(Self.describe(manager.authorizationStatus))")
        idQ.async { [weak self] in self?.refreshIdentity() }
    }

    static func describe(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not yet decided (prompt pending)"
        case .restricted: return "restricted"
        case .denied: return "denied (Wi-Fi names unavailable)"
        case .authorizedAlways, .authorized: return "granted"
        @unknown default: return "unknown (\(status.rawValue))"
        }
    }

    func bumpEpoch() {
        identityLock.lock(); probeEpoch &+= 1; identityLock.unlock()
    }

    /// Drop history and in-flight cycles, then wait for the network to answer again.
    func restartHealth(reason: String) {
        bumpEpoch()
        health.reset(); healthDisplay.reset()
        health.settle()
        lastInternetChecks = nil; lastCaptive = nil
        updateTitle()
    }

    /// Publishes the smoothed score and logs every visible change.
    @discardableResult
    func publishHealth() -> Bool {
        guard healthDisplay.publish() else { return false }
        if let h = healthDisplay.shown {
            DiagLog.shared.info("health", "\(h.score)% loss=\(String(format: "%.3f", h.loss))"
                + " jitter=\(h.jitterMs.map { String(format: "%.1f", $0) } ?? "-")"
                + " latency=\(h.latencyMs.map { String(format: "%.1f", $0) } ?? "-")"
                + " outage=\(!h.internetReachable) websites_failing=\(h.websitesFailing)")
        }
        return true
    }

    func setIdentity(_ new: Identity) {
        identity = new
        identityLock.lock(); identityForProbe = new; identityLock.unlock()
    }

    func snapshotIdentity() -> Identity {
        identityLock.lock(); defer { identityLock.unlock() }
        return identityForProbe
    }

    func snapshotProbeContext() -> (identity: Identity, epoch: Int) {
        identityLock.lock(); defer { identityLock.unlock() }
        return (identityForProbe, probeEpoch)
    }

    func appendStatsLine(_ line: String) {
        statsQ.async { [self] in
            do { try statsLog.append(line, to: statsURL) }
            catch {
                DiagLog.shared.error("stats", "unable to append stats log: \(error.localizedDescription)",
                                     throttleKey: "stats-append")
            }
        }
    }

    func refreshIdentity() {
        let new = resolveIdentity()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let changed = !new.sameNetwork(as: self.identity)
            if !changed, new.network != self.identity.network || new.bssid != self.identity.bssid {
                DiagLog.shared.info("network", "same link now identified as network=\(new.network ?? "-") bssid=\(new.bssid ?? "-")")
            }
            if changed {
                DiagLog.shared.info("network", "identity iface=\(new.iface ?? "-") type=\(new.type)"
                    + " network=\(new.network ?? "-") bssid=\(new.bssid ?? "-") router=\(new.router ?? "-")"
                    + " rssi=\(new.rssi.map(String.init) ?? "-") channel=\(new.channel.map(String.init) ?? "-")")
                let counters = readCounters(); let now = BandwidthClock.now()
                self.flushLog(at: now)
                self.peakItem?.title = "Peak this connection: —"
                self.bandwidth.resetConnection(counters: counters, at: now)
                self.resetAppBandwidth(at: now)
                self.recentLats = []
                self.lastLatMs = nil; self.lastLatSrc = nil; self.lastLatAt = nil
                self.restartHealth(reason: "network change")
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
        if publishHealth() { updateTitle() }
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
        if h.websitesFailing { parts.append("websites failed, rechecking") }
        return "Connection health: \(h.score)% (\(parts.joined(separator: ", ")))"
    }

    func probeLoop() {
        // Probe-thread state for the website-check cadence.
        var previous: WanProbe?
        var lastWebsites = InternetStatus.unknown
        var cyclesSinceWebCheck = 0
        var lastEpoch = -1
        while true {
            let started = Date()
            autoreleasepool {
                let context = snapshotProbeContext()
                let probeIdentity = context.identity
                let checkWebsites = Latency.websiteCheckDue(cyclesSinceCheck: cyclesSinceWebCheck,
                                                            lastWebsites: lastWebsites, previous: previous,
                                                            networkChanged: context.epoch != lastEpoch)
                let r = Latency.measure(gateway: probeIdentity.router, checkWebsites: checkWebsites)
                previous = r; lastEpoch = context.epoch
                if checkWebsites {
                    cyclesSinceWebCheck = 0
                    if r.internet != .unknown { lastWebsites = r.internet }
                } else {
                    cyclesSinceWebCheck += 1
                }
                let seconds = Date().timeIntervalSince(started)
                Diagnostics.shared.count(.probeCycles)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.cycleCount += 1
                    self.lastCycleAt = BandwidthClock.now()
                    let sameNetwork = self.snapshotProbeContext().epoch == context.epoch
                        && self.identity.sameNetwork(as: probeIdentity)
                    // Our own speed test saturates the link; that is not the network's normal state.
                    let current = sameNetwork && !self.speedTestRunning
                    let recorded = current ? self.health.record(r) : nil
                    let discarded = sameNetwork ? "discarded(speed test)" : "discarded(network changed)"
                    DiagLog.shared.info("probe", "cycle \(self.cycleCount) \(String(format: "%.2fs", seconds))"
                        + " \(recorded?.rawValue ?? discarded) \(r.logLine)")
                    guard current else { Diagnostics.shared.count(.discardedCycles); return }
                    // Unmeasured probes are excluded from the logged loss, like from health.
                    let measuredEchoes = r.verdicts.contains { $0 != .unmeasured }
                    if measuredEchoes || r.ms != nil {
                        self.winTotal += r.total; self.winRejected += r.rejected; self.winFailed += r.failed
                    }
                    if !r.internetChecks.isEmpty { self.lastInternetChecks = r.internetChecks }
                    self.lastCaptive = r.captive
                    self.healthDisplay.add(self.health.report())
                    self.publishHealth()
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
        let loss = winTotal > 0 ? min(1, Double(winFailed + winRejected) / Double(winTotal)) : (winLats.isEmpty ? 1.0 : 0.0)
        let rates = bandwidth.window.average
        let obj = buildSampleJSON(id: identity, secs: secs, latMs: latMs, latMin: latMin, latMax: latMax,
                                  latSrc: winLatSrc, gwMs: median(winGW), loss: winLats.isEmpty ? 1.0 : loss,
                                  rejected: winRejected, down: rates.down, up: rates.up,
                                  downPeak: bandwidth.window.peak.down, upPeak: bandwidth.window.peak.up,
                                  health: health.report() == nil ? nil : healthDisplay.shown?.score,
                                  internetChecks: lastInternetChecks, captive: lastCaptive)
        if let line = jsonLine(obj) { appendStatsLine(line) }
    }

    @objc func revealDiagnosticLog() {
        let log = DiagLog.shared
        log.info("app", "diagnostic log revealed")
        log.flush()
        let url = log.fileURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
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

    func speedActionTitle() -> String {
        if speedTestRunning { return "Cancel speed test" }
        if pathIsLowData { return "Run speed test (up to \(SpeedTestConfig.lowDataBudget / 1_000_000) MB, Low Data Mode)" }
        return "Run speed test (\(SpeedTestConfig.standardBudget / 1_000_000) MB, up to \(SpeedTestConfig.fastLinkBudget / 1_000_000) on fast links)"
    }

    @objc func runSpeedTest() {
        if speedTestRunning {
            speedControl?.cancel()
            speedItem?.title = "Cancelling…"
            return
        }
        let now = Date()
        if now < speedTestCooldownUntil {
            let left = Int(ceil(speedTestCooldownUntil.timeIntervalSince(now)))
            speedItem?.title = "Wait \(left)s before retesting"
            return
        }
        let lowData = pathIsLowData
        let config = lowData ? SpeedTestConfig.lowData : SpeedTestConfig.standard
        let control = SpeedTestControl()
        speedControl = control
        speedTestRunning = true
        bumpEpoch()
        speedActionItem?.title = speedActionTitle()
        speedItem?.title = "Measuring latency…"
        let testIdentity = identity
        identityLock.lock(); let testPath = pathGeneration; identityLock.unlock()
        // Path changes are seen at once; identity changes (a new SSID or router) a poll later.
        let isCurrentNetwork: () -> Bool = { [weak self] in
            guard let self else { return false }
            self.identityLock.lock(); let path = self.pathGeneration; self.identityLock.unlock()
            return path == testPath && self.snapshotIdentity().sameNetwork(as: testIdentity)
        }
        DiagLog.shared.info("speedtest", "start budget=\(config.budgetBytes)B lowData=\(lowData) network=\(testIdentity.network ?? "-")")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let measured = SpeedTest.run(config: config, lowData: lowData,
                                       makeTransport: { URLSessionSpeedTransport() }, control: control,
                                       isCurrentNetwork: isCurrentNetwork,
                                       progress: { p in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.speedControl === control, !control.isCancelled else { return }
                    switch p {
                    case .latency: self.speedItem?.title = "Measuring latency…"
                    case .transfer(let direction, let mbps):
                        let rate = mbps.map { $0 < 10 ? String(format: " %.1f Mbps", $0) : String(format: " %.0f Mbps", $0) } ?? ""
                        self.speedItem?.title = "Testing \(direction.rawValue)…\(rate)"
                    }
                }
            })
            var result = measured
            if !isCurrentNetwork() { result.networkChanged = true }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !self.identity.sameNetwork(as: testIdentity) { result.networkChanged = true }
                self.speedTestRunning = false
                self.speedControl = nil
                // Cycles that overlapped the test measured our own traffic.
                self.bumpEpoch()
                self.speedActionItem?.title = self.speedActionTitle()
                let status = result.status
                self.speedTestCooldownUntil = Date().addingTimeInterval(
                    status == "ok" ? Self.speedCooldown : status == "cancelled" ? 0 : Self.speedFailureCooldown)
                self.speedItem?.title = result.title
                DiagLog.shared.info("speedtest", "\(status) \(result.title) | \(result.detail)")
                func phase(_ p: SpeedPhaseResult?, _ key: String) -> [String: Any] {
                    [
                        "\(key)_mbps": p?.mbps.map { $0 as Any } ?? NSNull(),
                        "\(key)_bytes": p?.bytes ?? 0,
                        "\(key)_streams": p?.streams ?? 0,
                        "\(key)_stable": p?.stable ?? false,
                        "\(key)_lower_bound": p?.budgetLimited ?? false,
                        "\(key)_loaded_latency_ms": p?.loadedLatencyMs.map { $0 as Any } ?? NSNull()
                    ]
                }
                var obj: [String: Any] = [
                    "ts": isoTimestamp(), "event": "speedtest", "status": status,
                    "type": testIdentity.type, "network": testIdentity.network as Any? ?? NSNull(),
                    "idle_latency_ms": result.idleLatencyMs.map { $0 as Any } ?? NSNull(),
                    "errors": result.errors, "bytes_reserved": result.bytesReserved,
                    "budget_bytes": result.budgetBytes, "low_data": result.lowData,
                    "duration_s": result.elapsed, "server": Host.speedTest
                ]
                obj.merge(phase(result.download, "down")) { $1 }
                obj.merge(phase(result.upload, "up")) { $1 }
                if let line = jsonLine(obj) { self.appendStatsLine(line) }
            }
        }
    }
}
