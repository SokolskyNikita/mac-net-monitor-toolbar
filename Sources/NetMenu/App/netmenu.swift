// NetMenu — macOS menu bar network monitor
// Human setup (not agent tasks):
// 1. First GUI launch (`make run`) prompts Location (SSID/BSSID) and on macOS 15+ Local Network (gateway). Deny → null fields.
// 2. TCC ties grants to signing identity. Ad-hoc (SIGN_ID=-) resets each rebuild. Persist: Keychain Access → Certificate Assistant
//    → Create a Certificate → name `netmenu-selfsign`, type Code Signing; then `make app SIGN_ID=netmenu-selfsign`.

import AppKit
import CoreLocation
import Network

/// Removes temporary files a crashed run left behind. Recent ones may belong to a running copy.
func removeStaleTempFiles(olderThan age: TimeInterval = Configuration.reliability.staleTempFileAge) {
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

class AppDelegate: NSObject, NSApplicationDelegate, CLLocationManagerDelegate {
    var statusRenderer: StatusBarRenderer?
    var peakItem: MenuReadoutItem?
    var rateItem: MenuReadoutItem?
    var topAppsItem: MenuReadoutItem?
    let appBandwidthMonitor = AppBandwidthMonitor()
    var appBandwidthDisplay = AppBandwidthDisplay()
    var connectionDisplay = ConnectionDisplay()
    static let showThroughputKey = "showThroughputInMenuBar"
    /// Off by default: throughput lives in the menu to keep the menu bar item narrow.
    var showThroughput = UserDefaults.standard.bool(forKey: AppDelegate.showThroughputKey)
    let wifiScanMonitor = WiFiScanMonitor()
    var wifiScanWarningItem: MenuReadoutItem?
    var wifiScanActionItem: NSMenuItem?
    var localHealthItem: MenuReadoutItem?
    var localHealth = LocalHealthTracker()
    var localHealthDisplay = HealthDisplay()
    var healthItem: MenuReadoutItem?
    var speedItem: MenuReadoutItem?
    var speedResultExpiresAt: TimeInterval?
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
    var health = LiveHealthTracker()
    let liveProbes = LiveProbes()
    var recentTrouble = RecentTrouble()
    var reconnects = ReconnectHistory()
    var reconnectsItem: MenuReadoutItem?
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
    static let runningPIDKey = "runningPID"
    var termSource: DispatchSourceSignal?
    var lastCaptive: Bool?
    var hasResolvedIdentity = false
    var identity = Identity(iface: nil, type: NetType.offline, network: nil, bssid: nil, router: nil, rssi: nil, noise: nil, txRate: nil, channel: nil)
    /// Snapshot for probe queue — avoids DispatchQueue.main.sync (deadlock risk).
    var identityForProbe = Identity(iface: nil, type: NetType.offline, network: nil, bssid: nil, router: nil, rssi: nil, noise: nil, txRate: nil, channel: nil)
    var probeStats = ProbeStatsWindow()
    var idQ = DispatchQueue(label: "netmenu.id", qos: .utility, autoreleaseFrequency: .workItem)

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
        statusRenderer?.render(lat: "…", health: StatusBarRenderer.calibratingText, down: "0B", up: "0B",
                               showThroughput: false, calibrating: true)
        let menu = NSMenu()
        let hi = MenuReadoutItem(readout: .health(.health))
        hi.isEnabled = false; menu.addItem(hi); healthItem = hi
        func diagnosticRow(_ title: String) -> MenuReadoutItem {
            let row = MenuReadoutItem(readout: .message(title))
            row.isEnabled = false; row.isHidden = true; menu.addItem(row)
            return row
        }
        reconnectsItem = diagnosticRow("0 reconnects in past 5 mins")
        let local = MenuReadoutItem(readout: .health(.local))
        local.isEnabled = false; menu.addItem(local); localHealthItem = local
        let scanWarning = MenuReadoutItem(readout: .detail(.warning, "Wi-Fi settings scans coincide with router delays."))
        scanWarning.isHidden = true; menu.addItem(scanWarning); wifiScanWarningItem = scanWarning
        let closeSettings = NSMenuItem(title: "Quit System Settings to stop scans", action: #selector(closeWiFiSettings), keyEquivalent: "")
        closeSettings.target = self; closeSettings.isHidden = true
        closeSettings.toolTip = "Quits System Settings, including its other open settings pages. Your Wi-Fi connection stays on."
        menu.addItem(closeSettings); wifiScanActionItem = closeSettings
        wifiScanMonitor.didChange = { [weak self] in self?.updateTitle() }
        menu.addItem(.separator())
        let rate = MenuReadoutItem(readout: .row(.traffic, value: "—"))
        rate.isEnabled = false; menu.addItem(rate); rateItem = rate
        let topApps = MenuReadoutItem(readout: .row(.topApps, value: "measuring…"))
        topApps.isEnabled = false; menu.addItem(topApps); topAppsItem = topApps
        let peak = MenuReadoutItem(readout: .row(.peak, value: "—"))
        peak.isEnabled = false; menu.addItem(peak); peakItem = peak
        menu.addItem(.separator())
        let speed = MenuReadoutItem(readout: .detail(.result, ""))
        speed.isEnabled = false; speed.isHidden = true; menu.addItem(speed); speedItem = speed
        let st = KeepOpenMenuItem(title: speedActionTitle(), action: #selector(runSpeedTest), keyEquivalent: "")
        st.target = self; st.isEnabled = false; menu.addItem(st); speedActionItem = st
        st.toolTip = speedBudgetDescription()
        menu.addItem(.separator())
        let diagnostics = NSMenuItem(title: "Diagnostics", action: nil, keyEquivalent: "")
        let diagnosticsMenu = NSMenu()
        let rev = NSMenuItem(title: "Open stats file", action: #selector(revealStats), keyEquivalent: "")
        rev.target = self; diagnosticsMenu.addItem(rev)
        let diag = NSMenuItem(title: "Open diagnostic log", action: #selector(revealDiagnosticLog), keyEquivalent: "")
        diag.target = self; diagnosticsMenu.addItem(diag)
        diagnostics.submenu = diagnosticsMenu; menu.addItem(diagnostics)
        let options = NSMenuItem(title: "Options", action: nil, keyEquivalent: "")
        let optionsMenu = NSMenu()
        let showRates = NSMenuItem(title: "Show throughput in menu bar", action: #selector(toggleThroughput(_:)),
                                   keyEquivalent: "")
        showRates.target = self; showRates.state = showThroughput ? .on : .off; optionsMenu.addItem(showRates)
        let about = NSMenuItem(title: "About NetMenu", action: #selector(showAbout), keyEquivalent: "")
        about.target = self; optionsMenu.addItem(about)
        options.submenu = optionsMenu; menu.addItem(options)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit NetMenu", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu

        let lm = CLLocationManager()
        lm.delegate = self
        locationManager = lm
        DiagLog.shared.info("network", "location access: \(Self.describe(lm.authorizationStatus))")
        if lm.authorizationStatus == .notDetermined {
            lm.requestWhenInUseAuthorization()
        }

        let counters = readCounters(); let now = BandwidthClock.now()
        bandwidth = BandwidthTracker(counters: counters, at: now); probeStats = ProbeStatsWindow(at: now)
        idQ.async { [weak self] in self?.refreshIdentity() }
        let t = Timer(timeInterval: BandwidthTracker.sampleInterval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        liveProbes.receive = { [weak self] epoch, event in self?.receiveProbe(epoch: epoch, event: event) }
        // Common modes: keep firing while the menu is open.
        addTimer(Configuration.monitoring.identityInterval) { [weak self] in self?.idQ.async { self?.refreshIdentity() } }
        addTimer(Configuration.logging.statsInterval) { [weak self] in self?.flushLog() }
        addTimer(Configuration.logging.heartbeatInterval) { [weak self] in self?.heartbeat() }
        observeSleepAndWake()
        startPathMonitor()
        watchdog.start()
        updateTitle()
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
            + " last_probe=\(sinceCycle) ago\(cpuText) \(Diagnostics.shared.summary)"
            + " network=\(identity.network ?? "-") type=\(identity.type)")
        // The probe loop has no unbounded waits, so a long silence while awake means a bug.
        let quiet = now - max(lastCycleAt ?? launchedAt, lastWakeAt)
        if quiet > Configuration.logging.probeQuietWarning {
            DiagLog.shared.error("probe", "no probe results for \(Int(quiet))s while awake", throttleKey: "probe-stall")
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
            self.reconnects.wake()
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
                guard let self else { return }
                self.reconnects.observe(connected: path.status == .satisfied)
                self.updateTitle()
                guard summary != self.lastPathSummary else { return }
                let first = self.lastPathSummary == nil
                self.lastPathSummary = summary
                DiagLog.shared.info("network", "path \(summary)")
                guard !first else { return }
                self.identityLock.lock(); self.pathGeneration &+= 1; self.identityLock.unlock()
                self.bumpEpoch()
                self.health.settle()
                self.localHealth.settle()
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
        recentTrouble = RecentTrouble()
        wifiScanMonitor.reset()
        localHealth.reset(); localHealthDisplay.reset(); localHealth.settle()
        health.settle()
        lastInternetChecks = nil; lastCaptive = nil
        updateTitle()
    }

    /// Publishes the smoothed score and logs every visible change.
    @discardableResult
    func publishHealth() -> Bool {
        let localChanged = localHealthDisplay.publish()
        if localChanged, let h = localHealthDisplay.shown {
            DiagLog.shared.info("local-health", localHealth.menuTitle(router: identity.localRouter?.address, report: h))
        }
        guard healthDisplay.publish() else { return localChanged }
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
        let epoch = snapshotProbeContext().epoch
        let new = resolveIdentity()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Discovery may take seconds (SSID permission and helper fallbacks). A path
            // change during that work invalidates its result just like an old probe reply.
            guard epoch == self.snapshotProbeContext().epoch else {
                self.idQ.async { [weak self] in self?.refreshIdentity() }
                return
            }
            self.applyIdentity(new)
        }
    }

    /// Initial discovery establishes a baseline; only subsequent changes clear measurements.
    func applyIdentity(_ new: Identity) {
        if !hasResolvedIdentity {
            setIdentity(new)
            hasResolvedIdentity = true
            let now = BandwidthClock.now()
            bandwidth = BandwidthTracker(counters: readCounters(), at: now)
            probeStats = ProbeStatsWindow(at: now)
            health.settle(at: now); localHealth.settle(at: now)
            startAppBandwidth()
            speedActionItem?.isEnabled = true
            DiagLog.shared.info("network", "initial identity iface=\(new.iface ?? "-") type=\(new.type) router=\(new.router ?? "-")")
            updateTitle()
            return
        }
        let changed = !new.sameNetwork(as: identity)
        if !changed, new.network != identity.network || new.bssid != identity.bssid {
            DiagLog.shared.info("network", "same link now identified as network=\(new.network ?? "-") bssid=\(new.bssid ?? "-")")
        }
        if changed {
            DiagLog.shared.info("network", "identity iface=\(new.iface ?? "-") type=\(new.type)"
                + " network=\(new.network ?? "-") bssid=\(new.bssid ?? "-") router=\(new.router ?? "-")"
                + " rssi=\(new.rssi.map(String.init) ?? "-") channel=\(new.channel.map(String.init) ?? "-")")
            let counters = readCounters(); let now = BandwidthClock.now()
            flushLog(at: now)
            peakItem?.content = .row(.peak, value: "—")
            bandwidth.resetConnection(counters: counters, at: now)
            resetAppBandwidth(at: now)
            recentLats = []
            lastLatMs = nil; lastLatSrc = nil; lastLatAt = nil
            restartHealth(reason: "network change")
        }
        setIdentity(new)
        if changed { updateTitle() }
    }

    func startAppBandwidth() {
        appBandwidthMonitor.start { [weak self] snapshot in self?.showAppBandwidth(snapshot) }
    }

    func resetWindow(at: TimeInterval = BandwidthClock.now()) {
        probeStats = ProbeStatsWindow(at: at)
        bandwidth.resetWindow()
    }

    func noteLatency(_ ms: Double, src: String?) {
        guard let ms = finiteNonNeg(ms) else { return }
        lastLatMs = ms; lastLatAt = Date()
        pushLatency(ms, src: src, into: &recentLats, source: &lastLatSrc, limit: Configuration.monitoring.displayLatencyReadings)
        probeStats.recordLatency(ms, source: src)
    }

    func tick(counters: Counters? = readCounters(), at: TimeInterval = BandwidthClock.now()) {
        updateSpeedTestRow(at: at)
        guard hasResolvedIdentity else { return }
        wifiScanMonitor.poll(isWiFi: identity.type == NetType.wifi)
        speedActionItem?.title = speedActionTitle()
        speedActionItem?.toolTip = speedBudgetDescription()
        liveProbes.poll(identity: identity, epoch: snapshotProbeContext().epoch, paused: speedTestRunning, now: at)
        topAppsItem?.content = appBandwidthDisplay.readout(at: at)
        updateTitle() // Expire recent trouble and the five-minute reconnect count even while idle.
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
        // Age-based weights change even between probe completions.
        healthDisplay.add(health.report(now: at))
        localHealthDisplay.add(localHealth.report(now: at))
        if publishHealth() { updateTitle() }
        peakItem?.content = .row(.peak, value: "\(fmtRate(bandwidth.peak.down))↓ / \(fmtRate(bandwidth.peak.up))↑")
    }

    func showAppBandwidth(_ snapshot: AppBandwidthSnapshot?, at: TimeInterval = BandwidthClock.now()) {
        appBandwidthDisplay.record(snapshot, at: at)
        connectionDisplay.record(snapshot?.connections, at: at)
        topAppsItem?.content = appBandwidthDisplay.readout(at: at)
    }

    func resetAppBandwidth(at: TimeInterval = BandwidthClock.now()) {
        appBandwidthMonitor.reset()
        appBandwidthDisplay.restart(at: at)
        connectionDisplay = ConnectionDisplay()
        topAppsItem?.content = appBandwidthDisplay.readout(at: at)
    }

    func updateTitle() {
        guard hasResolvedIdentity else {
            statusRenderer?.render(lat: "…", health: StatusBarRenderer.calibratingText,
                                   down: "0B", up: "0B", showThroughput: false, calibrating: true)
            healthItem?.content = .health(.health, status: "identifying network…")
            localHealthItem?.content = .health(.local, status: "identifying network…")
            rateItem?.content = .row(.traffic, value: "waiting for network…")
            topAppsItem?.content = .row(.topApps, value: "waiting for network…")
            return
        }
        let lat: String
        let displayedLatency: Double?
        let report = health.report() == nil ? nil : healthDisplay.shown
        var calibrating = false
        if let at = lastLatAt, Date().timeIntervalSince(at) <= Configuration.monitoring.latencyStaleAfter,
           let m = finiteNonNeg(median(recentLats) ?? lastLatMs ?? .nan) {
            displayedLatency = m
            let n = Int(m.rounded())
            // ~ marks a non-ICMP approximation (HTTP trace)
            lat = lastLatSrc == LatencySource.icmp.rawValue ? "\(n)ms" : "~\(n)ms"
            calibrating = report == nil
        } else { lat = "✕"; displayedLatency = nil }
        let recent = recentTrouble.labels()
        let baseHealth = report.map { "\($0.score)%" } ?? (calibrating ? StatusBarRenderer.calibratingText : "")
        let hasWarning = !recent.isEmpty || wifiScanMonitor.warning
        let healthText = hasWarning ? "\(baseHealth) ⚠" : baseHealth
        wifiScanWarningItem?.isHidden = !wifiScanMonitor.warning
        wifiScanActionItem?.isHidden = !wifiScanMonitor.warning
        let reconnectCount = reconnects.count()
        reconnectsItem?.isHidden = reconnectCount < Configuration.monitoring.reconnectWarningCount
        let reconnectMinutes = String(format: "%g", Configuration.monitoring.reconnectWindow / 60)
        reconnectsItem?.content = .message("\(reconnectCount) reconnects in past \(reconnectMinutes) mins")
        statusRenderer?.render(lat: lat, health: healthText,
                               down: fmtRate(bandwidth.display.down), up: fmtRate(bandwidth.display.up),
                               showThroughput: showThroughput, calibrating: calibrating, hasWarning: hasWarning)
        // Share the live five-round median with the menu bar, without health-report smoothing.
        var displayedReport = report
        displayedReport?.latencyMs = displayedLatency
        displayedReport?.latencySources = displayedLatency == nil ? []
            : (lastLatSrc == LatencySource.icmp.rawValue ? [.icmp] : [.http])
        healthItem?.content = healthMenuReadout(displayedReport)
        localHealthItem?.content = localHealth.menuReadout(router: identity.localRouter?.address,
            report: localHealth.report() == nil ? nil : localHealthDisplay.shown)
        localHealthItem?.toolTip = identity.localRouter.map { "Router: \($0.address) on \($0.interface). Same scoring thresholds as internet health." }
        rateItem?.content = .row(.traffic, value: "\(fmtRate(bandwidth.display.down))↓ / \(fmtRate(bandwidth.display.up))↑")
    }

    @objc func closeWiFiSettings() {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: SystemApp.systemSettingsBundleID)
        guard !apps.isEmpty else { wifiScanMonitor.reset(); return }
        let accepted = apps.map { $0.terminate() }.allSatisfy { $0 }
        if accepted {
            wifiScanMonitor.reset()
        } else {
            let alert = NSAlert()
            alert.messageText = "Close Wi-Fi settings to stop scans"
            alert.informativeText = "System Settings couldn’t be quit. Close its Wi-Fi page or quit System Settings manually. Your Wi-Fi connection can stay on."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc func toggleThroughput(_ sender: NSMenuItem) {
        showThroughput.toggle()
        UserDefaults.standard.set(showThroughput, forKey: Self.showThroughputKey)
        sender.state = showThroughput ? .on : .off
        updateTitle()
    }

    func healthMenuReadout(_ report: HealthReport?) -> MenuReadout {
        guard let h = report else { return .health(.health) }
        if !h.internetReachable {
            return .health(.health, score: 0, parts: ["internet sites unreachable"])
        }
        var parts: [String] = []
        let sources = [LatencySource.icmp, .http].filter { h.latencySources.contains($0) }
            .map { $0 == .icmp ? "ICMP" : "HTTPS" }
        if !sources.isEmpty { parts.append(sources.joined(separator: "/")) }
        parts.append(String(format: "loss %.0f%%", h.loss * 100))
        if let j = h.jitterMs { parts.append(String(format: "jitter %.0fms", j)) }
        if let l = h.latencyMs { parts.append(String(format: "latency %.0fms", l)) }
        if h.websitesFailing { parts.append("websites failed, rechecking") }
        return .health(.health, score: h.score, parts: parts)
    }

    /// All callbacks arrive on the main thread; old-network and speed-test results are discarded.
    func receiveProbe(epoch: Int, event: LiveProbes.Event) {
        guard epoch == snapshotProbeContext().epoch, !speedTestRunning else {
            Diagnostics.shared.count(.discardedCycles); return
        }
        let now = HealthTracker.now()
        lastCycleAt = now
        switch event {
        case .wan(let slot, let started, let outcome, let gatewayMs):
            let verdict = LiveProbes.verdict(outcome, gatewayMs: gatewayMs)
            let recorded = health.recordTarget(slot: slot, verdict: verdict, started: started, at: now)
            recentTrouble.record(verdict, target: "wan-\(slot)", label: "network", at: now)
            if case .wan(let ms) = verdict {
                lastLatMs = ms; lastLatAt = Date(); lastLatSrc = LatencySource.icmp.rawValue
                recentLats = health.latencyReadings(now: now)
            }
            probeStats.recordWAN(verdict)
            Diagnostics.shared.count(.probeCycles)
            DiagLog.shared.info("probe", "target \(Latency.icmpTargets[slot]) \(outcome) verdict=\(verdict) recorded=\(recorded)")
        case .router(let result):
            if localHealth.method != result.method { localHealthDisplay.reset() }
            localHealth.record(result.outcome, method: result.method)
            localHealthDisplay.add(localHealth.report())
            let verdict: Latency.EchoVerdict
            switch result.outcome {
            case .reply(let r):
                verdict = .wan(r.ms); probeStats.recordRouter(r.ms)
                if result.method == .icmp { wifiScanMonitor.record(ms: r.ms) }
            case .lost: verdict = .noReply
            case .unmeasured: verdict = .unmeasured
            }
            recentTrouble.record(verdict, target: "router-\(result.method.rawValue)", label: "router", at: now)
            DiagLog.shared.info("probe", "router \(result.method.rawValue) \(verdict)")
        case .websites(let checks):
            health.recordWeb(checks)
            if !checks.isEmpty {
                lastInternetChecks = checks
                if !checks.values.contains(true) { recentTrouble.websitesFailed(at: now) }
            }
            DiagLog.shared.info("probe", "websites \(checks)")
        case .portal(let portal):
            health.recordPortal(portal == .portal)
            lastCaptive = portal == .portal
            DiagLog.shared.info("probe", "portal \(portal)")
        case .fallback(let ms):
            health.recordFallback(ms)
            // A fallback that overlapped an ICMP recovery must not replace newer ping latency.
            let freshPing = lastLatSrc == LatencySource.icmp.rawValue
                && lastLatAt.map { Date().timeIntervalSince($0) < Configuration.monitoring.wanFreshFor } == true
            if !freshPing {
                if let ms { noteLatency(ms, src: LatencySource.http.rawValue) }
                recentTrouble.record(ms.map { .wan($0) } ?? .noReply, target: "http", label: "network", at: now)
            }
            DiagLog.shared.info("probe", "fallback \(ms.map(String.init(describing:)) ?? "failed")")
        }
        healthDisplay.add(health.report())
        publishHealth()
        updateTitle()
    }

    func flushLog(at: TimeInterval = BandwidthClock.now(), resetAt: TimeInterval? = nil) {
        let secs = at - probeStats.startedAt
        defer { resetWindow(at: resetAt ?? at) }
        guard secs > 0, bandwidth.window.sampleCount > 0 || probeStats.hasMeasurements else { return }
        let rates = bandwidth.window.average
        let snapshotAt = HealthTracker.now()
        let report = health.report(now: snapshotAt)
        let transport = health.transportReport(now: snapshotAt)
        let local = localHealth.report(now: snapshotAt)
        let webFresh = health.hasFreshWebCheck(now: snapshotAt)
        let diagnostics = HealthStatsSnapshot(report: report, transport: transport, local: local,
            reconnects5m: reconnects.count(now: snapshotAt),
            recentTrouble: recentTrouble.labels(now: snapshotAt), webChecksFresh: webFresh)
        var obj = buildSampleJSON(id: identity, secs: secs, latMs: median(probeStats.latencies),
                                  latMin: probeStats.latencies.min(), latMax: probeStats.latencies.max(),
                                  latSrc: probeStats.latencySource, gwMs: median(probeStats.routerLatencies),
                                  loss: probeStats.loss, rejected: probeStats.rejected, down: rates.down, up: rates.up,
                                  downPeak: bandwidth.window.peak.down, upPeak: bandwidth.window.peak.up,
                                  health: report == nil ? nil : healthDisplay.shown?.score,
                                  internetChecks: lastInternetChecks, captive: lastCaptive,
                                  localHealth: local == nil ? nil : localHealthDisplay.shown,
                                  localMethod: local == nil ? nil : localHealth.method)
        obj.merge(diagnostics.json) { _, new in new }
        obj["connections"] = connectionDisplay.fresh(at: snapshotAt)?.json as Any? ?? NSNull()
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
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let credits = NSAttributedString(string: "GitHub project", attributes: [
            .link: URL(string: "https://github.com/SokolskyNikita/mac-net-monitor-toolbar")!,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .paragraphStyle: paragraphStyle
        ])
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "NetMenu",
            .applicationVersion: short,
            .version: build,
            .credits: credits
        ])
    }

    func updateSpeedTestRow(at now: TimeInterval = BandwidthClock.now()) {
        speedItem?.isHidden = !speedTestRunning && !(speedResultExpiresAt.map { now < $0 } ?? false)
    }

    func speedActionTitle() -> String {
        if speedTestRunning { return "Cancel speed test" }
        if Date() < speedTestCooldownUntil {
            return "Wait \(Int(ceil(speedTestCooldownUntil.timeIntervalSinceNow)))s before retesting"
        }
        return pathIsLowData ? "Run speed test (Low Data Mode)" : "Run speed test"
    }

    func speedBudgetDescription() -> String {
        if pathIsLowData { return "Uses up to \(SpeedTestConfig.lowDataBudget / 1_000_000) MB in Low Data Mode." }
        return "Uses \(SpeedTestConfig.standardBudget / 1_000_000) MB, up to \(SpeedTestConfig.fastLinkBudget / 1_000_000) MB on fast links."
    }

    @objc func runSpeedTest() {
        guard hasResolvedIdentity else { return }
        if speedTestRunning {
            speedControl?.cancel()
            speedItem?.content = .detail(.result, "Cancelling…")
            return
        }
        let now = Date()
        if now < speedTestCooldownUntil {
            speedActionItem?.title = speedActionTitle()
            return
        }
        let lowData = pathIsLowData
        let config = lowData ? SpeedTestConfig.lowData : SpeedTestConfig.standard
        let control = SpeedTestControl()
        speedControl = control
        speedTestRunning = true
        speedResultExpiresAt = nil
        updateSpeedTestRow()
        bumpEpoch()
        speedActionItem?.title = speedActionTitle()
        speedItem?.content = .detail(.result, "Measuring latency…")
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
                    case .latency: self.speedItem?.content = .detail(.result, "Measuring latency…")
                    case .transfer(let direction, let mbps):
                        let rate = mbps.map { $0 < 10 ? String(format: " %.1f Mbps", $0) : String(format: " %.0f Mbps", $0) } ?? ""
                        self.speedItem?.content = .detail(.result, "Testing \(direction.rawValue)…\(rate)")
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
                    status == .ok ? config.cooldown : status == .cancelled ? 0 : config.failureCooldown)
                self.speedItem?.content = result.menuReadout
                self.speedResultExpiresAt = BandwidthClock.now() + config.resultLifetime
                self.updateSpeedTestRow()
                self.speedActionItem?.title = self.speedActionTitle()
                DiagLog.shared.info("speedtest", "\(status.rawValue) \(result.title) | \(result.detail)")
                let obj = SpeedTestStatsSnapshot(result: result, identity: testIdentity).json
                if let line = jsonLine(obj) { self.appendStatsLine(line) }
            }
        }
    }
}
