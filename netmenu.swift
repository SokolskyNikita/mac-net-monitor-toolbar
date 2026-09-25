// NetMenu — macOS menu bar network monitor
// Human setup (not agent tasks):
// 1. First GUI launch (`make run`) prompts Location (SSID/BSSID) and on macOS 15+ Local Network (gateway). Deny → null fields.
// 2. TCC ties grants to signing identity. Ad-hoc (SIGN_ID=-) resets each rebuild. Persist: Keychain Access → Certificate Assistant
//    → Create a Certificate → name `netmenu-selfsign`, type Code Signing; then `make app SIGN_ID=netmenu-selfsign`.
// FUTURE: file rotation

import AppKit
import CoreWLAN
import CoreLocation

/// Menu-bar latency — one WAN probe cycle every `probeInterval` (wall clock).
let probeInterval: TimeInterval = 3
let staleAfter: TimeInterval = 60
let sampleInterval: TimeInterval = 1
let rateDisplayInterval: TimeInterval = 5
let identityInterval: TimeInterval = 15
let logInterval: TimeInterval = 60
let displayLatWindow = 5

/// Run a helper with a wall-clock timeout; drain pipes on side queues so large stdout can't deadlock.
func runProc(_ path: String, _ args: [String], timeout: TimeInterval = 10, requireSuccess: Bool = false) -> String? {
    guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
    return autoreleasepool { () -> String? in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe
        do { try p.run() } catch { return nil }

        final class Box: @unchecked Sendable { var data = Data(); let lock = NSLock() }
        let box = Box()
        let group = DispatchGroup()
        group.enter()
        // userInitiated — don't starve behind identity/system_profiler work on utility.
        DispatchQueue.global(qos: .userInitiated).async {
            let d = outPipe.fileHandleForReading.readDataToEndOfFile()
            box.lock.lock(); box.data.append(d); box.lock.unlock()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            _ = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let t0 = Date()
        while p.isRunning, Date().timeIntervalSince(t0) < timeout {
            Thread.sleep(forTimeInterval: 0.03)
        }
        if p.isRunning {
            p.terminate()
            let killAt = Date().addingTimeInterval(1.5)
            while p.isRunning, Date() < killAt { Thread.sleep(forTimeInterval: 0.03) }
        }
        _ = group.wait(timeout: .now() + 2)
        if requireSuccess && (p.isRunning || p.terminationStatus != 0) { return nil }
        box.lock.lock(); let data = box.data; box.lock.unlock()
        return String(data: data, encoding: .utf8)
    }
}

func finiteNonNeg(_ x: Double, max: Double = 600_000) -> Double? {
    guard x.isFinite, x >= 0, x <= max else { return nil }
    return x
}

/// At most 4 characters: 999B, 999K, 9.9M, 999M, 9.9G. Thresholds sit below the next unit's
/// rounding point so 999.6K prints 1.0M, not 1000K.
func fmtRate(_ bps: Double) -> String {
    if bps < 999.5 { return String(format: "%.0fB", bps) }
    if bps < 999.5e3 { return String(format: "%.0fK", bps / 1e3) }
    if bps < 9.95e6 { return String(format: "%.1fM", bps / 1e6) }
    if bps < 999.5e6 { return String(format: "%.0fM", bps / 1e6) }
    if bps < 9.95e9 { return String(format: "%.1fG", bps / 1e9) }
    return String(format: "%.0fG", bps / 1e9)
}

/// Status item width that grows at once but shrinks only after the content has stayed narrower
/// for `shrinkAfter`, so neighbouring menu bar icons don't shift every time a digit drops.
struct StableWidth {
    static let shrinkAfter: TimeInterval = 30
    private(set) var width: Double = 0
    private var narrowerSince: TimeInterval?
    /// Widest content seen since `narrowerSince`; the width shrinks to this, not the latest value.
    private var narrowMax: Double = 0

    mutating func fit(_ content: Double, now: TimeInterval) -> Double {
        if content >= width {
            width = content; narrowerSince = nil
        } else if let since = narrowerSince {
            narrowMax = max(narrowMax, content)
            if now - since >= Self.shrinkAfter { width = narrowMax; narrowerSince = nil }
        } else {
            narrowerSince = now; narrowMax = content
        }
        return width
    }
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

struct Counters { var rx: [String: UInt32] = [:]; var tx: [String: UInt32] = [:] }

func readCounters() -> Counters {
    var c = Counters(); var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return c }
    defer { freeifaddrs(ifaddr) }
    var ptr: UnsafeMutablePointer<ifaddrs>? = first
    while let p = ptr {
        let name = String(cString: p.pointee.ifa_name)
        if let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), name.hasPrefix("en"),
           let data = p.pointee.ifa_data {
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            c.rx[name] = d.ifi_ibytes; c.tx[name] = d.ifi_obytes
        }
        ptr = p.pointee.ifa_next
    }
    return c
}

func deltaRates(old: Counters, new: Counters, dt: TimeInterval) -> (down: Double, up: Double) {
    guard dt > 0 else { return (0, 0) }
    var dr: UInt64 = 0, du: UInt64 = 0
    for (name, nr) in new.rx {
        guard let or = old.rx[name], let ot = old.tx[name], let nt = new.tx[name] else { continue }
        let rdx = nr &- or, tdx = nt &- ot
        if rdx > 2_147_483_648 || tdx > 2_147_483_648 { continue }
        dr += UInt64(rdx); du += UInt64(tdx)
    }
    return (Double(dr) / dt, Double(du) / dt)
}

private let ssidRe = try? NSRegularExpression(pattern: #"^\s*SSID : (.+)$"#, options: .anchorsMatchLines)

struct Identity: Equatable {
    var iface: String?; var type: String; var network: String?; var bssid: String?
    var router: String?; var rssi: Int?; var noise: Int?; var txRate: Double?; var channel: Int?
    func sameNetwork(as x: Identity) -> Bool {
        iface == x.iface && type == x.type && network == x.network && bssid == x.bssid && router == x.router
    }
}

func parseRoute() -> (iface: String?, gateway: String?) {
    func parse(_ out: String) -> (String?, String?) {
        var iface: String?, gw: String?
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("interface:") { iface = t.replacingOccurrences(of: "interface:", with: "").trimmingCharacters(in: .whitespaces) }
            if t.hasPrefix("gateway:") { gw = t.replacingOccurrences(of: "gateway:", with: "").trimmingCharacters(in: .whitespaces) }
        }
        return (iface, gw)
    }
    if let o = runProc("/sbin/route", ["-n", "get", "default"]), let r = Optional(parse(o)), r.0 != nil { return r }
    if let o = runProc("/sbin/route", ["-n", "get", "-inet6", "default"]) { return parse(o) }
    return (nil, nil)
}

func hardwarePorts() -> [String: String] {
    guard let out = runProc("/usr/sbin/networksetup", ["-listallhardwareports"]) else { return [:] }
    var map: [String: String] = [:], port: String?
    for line in out.split(separator: "\n") {
        let t = String(line)
        if t.hasPrefix("Hardware Port:") { port = t.replacingOccurrences(of: "Hardware Port:", with: "").trimmingCharacters(in: .whitespaces) }
        else if t.hasPrefix("Device:"), let p = port {
            map[t.replacingOccurrences(of: "Device:", with: "").trimmingCharacters(in: .whitespaces)] = p; port = nil
        }
    }
    return map
}

func ssidIpconfig(_ iface: String) -> String? {
    guard let out = runProc("/usr/sbin/ipconfig", ["getsummary", iface], timeout: 5),
          let re = ssidRe else { return nil }
    let range = NSRange(out.startIndex..., in: out)
    guard let m = re.firstMatch(in: out, range: range), let r = Range(m.range(at: 1), in: out) else { return nil }
    return String(out[r])
}

func ssidProfiler(_ iface: String) -> String? {
    // system_profiler can be huge/slow — timeout + async pipe drain in runProc avoids hangs.
    guard let out = runProc("/usr/sbin/system_profiler", ["SPAirPortDataType", "-json"], timeout: 12),
          let data = out.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let arr = json["SPAirPortDataType"] as? [[String: Any]], let root = arr.first,
          let ifaces = root["spairport_airport_interfaces"] as? [[String: Any]] else { return nil }
    for i in ifaces where (i["_name"] as? String) == iface {
        if let net = i["spairport_current_network_information"] as? [String: Any], let n = net["_name"] as? String { return n }
    }
    return nil
}

/// CoreWLAN is touchy off-main; hop to main briefly for CW* reads only.
func wifiDetails(iface: String) -> (ssid: String?, bssid: String?, rssi: Int?, noise: Int?, txRate: Double?, channel: Int?) {
    var result: (String?, String?, Int?, Int?, Double?, Int?) = (nil, nil, nil, nil, nil, nil)
    let work = {
        guard let cw = CWWiFiClient.shared().interface(withName: iface) else { return }
        result.0 = cw.ssid()
        result.1 = cw.bssid()
        let r = cw.rssiValue(); if r != 0 { result.2 = r }
        let n = cw.noiseMeasurement(); if n != 0 { result.3 = n }
        let tr = cw.transmitRate(); if tr > 0 { result.4 = tr }
        result.5 = cw.wlanChannel()?.channelNumber
    }
    if Thread.isMainThread { work() }
    else { DispatchQueue.main.sync(execute: work) }
    return result
}

func resolveIdentity() -> Identity {
    let (iface, router) = parseRoute()
    guard let iface else {
        return Identity(iface: nil, type: NetType.offline, network: nil, bssid: nil, router: nil, rssi: nil, noise: nil, txRate: nil, channel: nil)
    }
    let ports = hardwarePorts(); let port = ports[iface] ?? ""
    var type = NetType.ethernet, network: String? = port.isEmpty ? iface : port
    var bssid: String?, rssi: Int?, noise: Int?, txRate: Double?, channel: Int?
    let isVPN = iface.hasPrefix("utun") || iface.hasPrefix("ipsec") || iface.hasPrefix("ppp")
    if port == PortName.wifi || port == PortName.airPort { type = NetType.wifi }
    else if port.contains("iPhone") || port.contains("iPad") || port.contains("Bluetooth") { type = NetType.tether }
    else if isVPN { type = NetType.vpn; network = PortName.vpn }
    let wifiIf: String? = {
        if type == NetType.wifi { return iface }
        if type == NetType.vpn { return ports.first(where: { $0.value == PortName.wifi || $0.value == PortName.airPort })?.key }
        return nil
    }()
    if let wif = wifiIf {
        let w = wifiDetails(iface: wif)
        let ssid = w.ssid ?? ssidIpconfig(wif) ?? ssidProfiler(wif)
        if let ssid { network = ssid }
        else { network = type == NetType.wifi ? PortName.wifi : PortName.vpn }
        bssid = w.bssid
        if type == NetType.wifi {
            rssi = w.rssi; noise = w.noise; txRate = w.txRate; channel = w.channel
        }
    } else if type == NetType.wifi {
        network = PortName.wifi
    }
    return Identity(iface: iface, type: type, network: network, bssid: bssid, router: router, rssi: rssi, noise: noise, txRate: txRate, channel: channel)
}

// TCC-free identity for --sample: steps 4b→4d only
func resolveIdentitySample() -> Identity {
    let (iface, router) = parseRoute()
    guard let iface else {
        return Identity(iface: nil, type: NetType.offline, network: nil, bssid: nil, router: nil, rssi: nil, noise: nil, txRate: nil, channel: nil)
    }
    let ports = hardwarePorts(); let port = ports[iface] ?? ""
    var type = NetType.ethernet, network: String? = port.isEmpty ? iface : port
    let isVPN = iface.hasPrefix("utun") || iface.hasPrefix("ipsec") || iface.hasPrefix("ppp")
    if port == PortName.wifi || port == PortName.airPort { type = NetType.wifi }
    else if port.contains("iPhone") || port.contains("iPad") || port.contains("Bluetooth") { type = NetType.tether; network = port }
    else if isVPN { type = NetType.vpn; network = PortName.vpn }
    else { type = NetType.ethernet; network = port.isEmpty ? iface : port }
    let wifiIf: String? = type == NetType.wifi ? iface : (type == NetType.vpn ? ports.first(where: { $0.value == PortName.wifi || $0.value == PortName.airPort })?.key : nil)
    if let wif = wifiIf {
        if let s = ssidIpconfig(wif) { network = s }
        else if let s = ssidProfiler(wif) { network = s }
        else { network = type == NetType.vpn ? PortName.vpn : PortName.wifi }
    }
    return Identity(iface: iface, type: type, network: network, bssid: nil, router: router, rssi: nil, noise: nil, txRate: nil, channel: nil)
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
    var statusItem: NSStatusItem?
    var peakItem: NSMenuItem?
    var rateItem: NSMenuItem?
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
    let statsLock = NSLock()
    let identityLock = NSLock()
    var speedTestRunning = false
    var speedTestCooldownUntil = Date.distantPast
    var prev: Counters = Counters(); var prevAt = Date()
    var peakDown = 0.0, peakUp = 0.0, lastDown = 0.0, lastUp = 0.0
    /// Menu-bar rates — refreshed every `rateDisplayInterval` (avg of 1s samples).
    var displayDown = 0.0, displayUp = 0.0
    var rateDispSumDown = 0.0, rateDispSumUp = 0.0, rateDispTicks = 0
    var rateDispAt = Date()
    var lastLatMs: Double?; var lastLatSrc: String?; var lastLatAt: Date?
    var recentLats: [Double] = []
    var health = HealthTracker()
    var healthDisplay = HealthDisplay()
    var lastInternetChecks: [String: Bool]?
    var lastCaptive: Bool?
    var statusWidth = StableWidth()
    var identity = Identity(iface: nil, type: NetType.offline, network: nil, bssid: nil, router: nil, rssi: nil, noise: nil, txRate: nil, channel: nil)
    /// Snapshot for probe queue — avoids DispatchQueue.main.sync (deadlock risk).
    var identityForProbe = Identity(iface: nil, type: NetType.offline, network: nil, bssid: nil, router: nil, rssi: nil, noise: nil, txRate: nil, channel: nil)
    var winStart = Date()
    var winLats: [Double] = []; var winLatSrc: String?
    var winGW: [Double] = []; var winRejected = 0; var winFailed = 0; var winTotal = 0
    var winDownSum = 0.0, winUpSum = 0.0, winTicks = 0
    var winDownPeak = 0.0, winUpPeak = 0.0
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
        // Draw into a template image — status-item titles reflow/trim text.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageOnly
        statusItem = item
        paintStatus(lat: "✕", health: "", down: "0B", up: "0B")
        let menu = NSMenu()
        let hi = NSMenuItem(title: "Connection health: measuring…", action: nil, keyEquivalent: "")
        hi.isEnabled = false; menu.addItem(hi); healthItem = hi
        let rate = NSMenuItem(title: "Throughput: —", action: nil, keyEquivalent: "")
        rate.isEnabled = false; menu.addItem(rate); rateItem = rate
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

        prev = readCounters(); prevAt = Date(); winStart = Date()
        idQ.async { [weak self] in self?.refreshIdentity() }
        let t = Timer(timeInterval: sampleInterval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        probeQ.async { [weak self] in self?.probeLoop() }
        Timer.scheduledTimer(withTimeInterval: identityInterval, repeats: true) { [weak self] _ in
            self?.idQ.async { self?.refreshIdentity() }
        }
        Timer.scheduledTimer(withTimeInterval: logInterval, repeats: true) { [weak self] _ in
            self?.flushLog()
        }
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
        guard let data = (line + "\n").data(using: .utf8) else { return }
        statsLock.lock(); defer { statsLock.unlock() }
        let url = statsURL
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            _ = try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    func refreshIdentity() {
        let new = resolveIdentity()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !new.sameNetwork(as: self.identity) {
                self.flushLog()
                self.resetWindow()
                self.peakDown = 0; self.peakUp = 0
                self.peakItem?.title = "Peak this connection: —"
                // Start a fresh counter interval so traffic from the previous connection
                // cannot immediately become the new connection's peak.
                self.prev = readCounters(); self.prevAt = Date()
                self.recentLats = []
                self.lastLatMs = nil; self.lastLatSrc = nil; self.lastLatAt = nil
                self.health.reset(); self.healthDisplay.reset()
                self.lastInternetChecks = nil; self.lastCaptive = nil
            }
            self.setIdentity(new)
        }
    }

    func resetWindow() {
        winStart = Date(); winLats = []; winLatSrc = nil; winGW = []
        winRejected = 0; winFailed = 0; winTotal = 0
        winDownSum = 0; winUpSum = 0; winTicks = 0; winDownPeak = 0; winUpPeak = 0
    }

    func noteLatency(_ ms: Double, src: String?) {
        guard let ms = finiteNonNeg(ms) else { return }
        lastLatMs = ms; lastLatAt = Date()
        pushLatency(ms, src: src, into: &recentLats, source: &lastLatSrc, limit: displayLatWindow)
        pushLatency(ms, src: src, into: &winLats, source: &winLatSrc, limit: Self.maxWinSamples)
    }

    func tick() {
        let now = Date(); let dt = now.timeIntervalSince(prevAt)
        let cur = readCounters()
        if dt > 5 {
            prev = cur; prevAt = now; resetWindow()
            rateDispSumDown = 0; rateDispSumUp = 0; rateDispTicks = 0; rateDispAt = now
            return
        }
        let (down, up) = deltaRates(old: prev, new: cur, dt: dt)
        prev = cur; prevAt = now
        lastDown = finiteNonNeg(down, max: 1e13) ?? 0
        lastUp = finiteNonNeg(up, max: 1e13) ?? 0
        if lastDown > peakDown { peakDown = lastDown }
        if lastUp > peakUp { peakUp = lastUp }
        winDownSum += lastDown; winUpSum += lastUp; winTicks += 1
        if lastDown > winDownPeak { winDownPeak = lastDown }
        if lastUp > winUpPeak { winUpPeak = lastUp }

        rateDispSumDown += lastDown; rateDispSumUp += lastUp; rateDispTicks += 1
        if now.timeIntervalSince(rateDispAt) >= rateDisplayInterval, rateDispTicks > 0 {
            displayDown = rateDispSumDown / Double(rateDispTicks)
            displayUp = rateDispSumUp / Double(rateDispTicks)
            rateDispSumDown = 0; rateDispSumUp = 0; rateDispTicks = 0
            rateDispAt = now
            updateTitle()
        }
        if healthDisplay.publish(now: now.timeIntervalSince1970) { updateTitle() }
        peakItem?.title = "Peak this connection: \(fmtRate(peakDown))↓ / \(fmtRate(peakUp))↑"
    }

    static let statusFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let statusAttrs: [NSAttributedString.Key: Any] = [.font: statusFont, .foregroundColor: NSColor.black]
    /// Gap between fields, with a separator line in the middle; an arrow hugs its number.
    static let statusGap: CGFloat = 9
    static let separatorAlpha: CGFloat = 0.3
    /// Health field while it calibrates. Right-aligned like "100%", so the % stays put and the
    /// spinner, drawn over the digit positions, is all that changes when the score arrives.
    static let calibratingText = "%"
    static let spinnerFPS: TimeInterval = 12

    var spinnerTimer: Timer?
    var spinnerPhase = 0
    var lastStatus = (lat: "✕", health: "", down: "0B", up: "0B")

    /// Each field gets a slot wide enough for three digits and is right-aligned in it, so positions
    /// hold as digit counts change. Longer values (1363ms) widen their slot; `StableWidth` keeps
    /// the item from shrinking straight back.
    func paintStatus(lat: String, health: String, down: String, up: String) {
        guard let item = statusItem, let button = item.button else { return }
        lastStatus = (lat, health, down, up)
        var fields = [(lat, "999ms"), (health, "100%")]
        if showThroughput { fields += [(down + "↓", "999K↓"), (up + "↑", "999K↑")] }
        func width(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: Self.statusAttrs).width }
        let slots = fields.map { max(width($0.0), width($0.1)) }
        let content = ceil(slots.reduce(0, +) + Self.statusGap * CGFloat(fields.count - 1))
        let w = CGFloat(statusWidth.fit(Double(content), now: Date().timeIntervalSince1970))
        let angle = CGFloat(spinnerPhase % 12) * 30
        let img = NSImage(size: NSSize(width: w, height: 18), flipped: false) { _ in
            var edge = w - content
            for (i, ((s, _), slot)) in zip(fields, slots).enumerated() {
                if i > 0 {
                    NSColor.black.withAlphaComponent(Self.separatorAlpha).setFill()
                    NSRect(x: (edge - Self.statusGap / 2).rounded() - 0.5, y: 4, width: 1, height: 10).fill()
                }
                edge += slot
                let x = edge - width(s)
                (s as NSString).draw(at: NSPoint(x: x, y: 2), withAttributes: Self.statusAttrs)
                if s == Self.calibratingText {
                    Self.drawSpinner(center: NSPoint(x: x - width("0"), y: 9), angle: angle)
                }
                edge += Self.statusGap
            }
            return true
        }
        img.isTemplate = true
        item.length = w
        button.image = img
    }

    /// A 270° arc; rotating `angle` animates it.
    static func drawSpinner(center: NSPoint, angle: CGFloat) {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: 3.5, startAngle: -angle, endAngle: -angle + 270)
        arc.lineWidth = 1.4
        arc.lineCapStyle = .round
        NSColor.black.setStroke()
        arc.stroke()
    }

    func setSpinning(_ on: Bool) {
        if on, spinnerTimer == nil {
            let t = Timer(timeInterval: 1 / Self.spinnerFPS, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.spinnerPhase += 1
                let s = self.lastStatus
                self.paintStatus(lat: s.lat, health: s.health, down: s.down, up: s.up)
            }
            RunLoop.main.add(t, forMode: .common)
            spinnerTimer = t
        } else if !on {
            spinnerTimer?.invalidate(); spinnerTimer = nil
        }
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
        setSpinning(calibrating)
        let healthText = report.map { "\($0.score)%" } ?? (calibrating ? Self.calibratingText : "")
        paintStatus(lat: lat, health: healthText, down: fmtRate(displayDown), up: fmtRate(displayUp))
        healthItem?.title = healthMenuTitle(report)
        rateItem?.title = "Throughput: \(fmtRate(displayDown))↓ / \(fmtRate(displayUp))↑"
    }

    @objc func toggleThroughput(_ sender: NSMenuItem) {
        showThroughput.toggle()
        UserDefaults.standard.set(showThroughput, forKey: Self.showThroughputKey)
        sender.state = showThroughput ? .on : .off
        // Hiding should narrow the item now, not after the usual shrink delay.
        statusWidth = StableWidth()
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

    func flushLog() {
        let secs = Date().timeIntervalSince(winStart)
        guard secs > 0.5, winTicks > 0 || !winLats.isEmpty || winTotal > 0 else { resetWindow(); return }
        let latMs = median(winLats); let latMin = winLats.min(); let latMax = winLats.max()
        let loss = winTotal > 0 ? Double(winFailed + winRejected) / Double(winTotal) : (winLats.isEmpty ? 1.0 : 0.0)
        let down = winTicks > 0 ? winDownSum / Double(winTicks) : 0
        let up = winTicks > 0 ? winUpSum / Double(winTicks) : 0
        let obj = buildSampleJSON(id: identity, secs: secs, latMs: latMs, latMin: latMin, latMax: latMax,
                                  latSrc: winLatSrc, gwMs: median(winGW), loss: winLats.isEmpty ? 1.0 : loss,
                                  rejected: winRejected, down: down, up: up, downPeak: winDownPeak, upPeak: winUpPeak,
                                  health: health.report() == nil ? nil : healthDisplay.shown?.score,
                                  internetChecks: lastInternetChecks, captive: lastCaptive)
        if let line = jsonLine(obj) { appendStatsLine(line) }
        resetWindow()
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
