// NetMenu — macOS menu bar network monitor
// Human setup (not agent tasks):
// 1. First GUI launch (`make run`) prompts Location (SSID/BSSID) and on macOS 15+ Local Network (gateway). Deny → null fields.
// 2. TCC ties grants to signing identity. Ad-hoc (SIGN_ID=-) resets each rebuild. Persist: Keychain Access → Certificate Assistant
//    → Create a Certificate → name `netmenu-selfsign`, type Code Signing; then `make app SIGN_ID=netmenu-selfsign`.
// FUTURE: file rotation

import AppKit
import Network
import CoreWLAN
import CoreLocation

let icmpTargets = ["1.1.1.1", "8.8.8.8"]
let tlsFallback = (host: "one.one.one.one", port: UInt16(443))
let probeInterval: TimeInterval = 3
let fallbackInterval: TimeInterval = 30
let staleAfter: TimeInterval = 60
let sampleInterval: TimeInterval = 1
let identityInterval: TimeInterval = 15
let logInterval: TimeInterval = 60

func runProc(_ path: String, _ args: [String]) -> String? {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    let o = Pipe(), e = Pipe(); p.standardOutput = o; p.standardError = e
    do { try p.run() } catch { return nil }
    p.waitUntilExit()
    return String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
}

func fmtRate(_ bps: Double) -> String {
    if bps < 1000 { return String(format: "%.0fB", bps) }
    if bps < 1e6 { return String(format: "%.0fK", bps / 1e3) }
    if bps < 1e9 { return String(format: "%.1fM", bps / 1e6) }
    return String(format: "%.1fG", bps / 1e9)
}

func median(_ xs: [Double]) -> Double? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted(); let n = s.count
    return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
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

struct PingResult { var ms: Double?; var rejected: Bool; var failed: Bool }

func pingHost(_ host: String, timeoutMs: String, honesty: Bool) -> PingResult {
    guard let out = runProc("/sbin/ping", ["-c", "1", "-W", timeoutMs, "-s", "16", host]) else {
        return PingResult(ms: nil, rejected: false, failed: true)
    }
    let timeRe = try! NSRegularExpression(pattern: #"time=([0-9.]+)"#)
    let ttlRe = try! NSRegularExpression(pattern: #"ttl=([0-9]+)"#)
    let range = NSRange(out.startIndex..., in: out)
    guard let tm = timeRe.firstMatch(in: out, range: range), let tr = Range(tm.range(at: 1), in: out),
          let ms = Double(out[tr]) else {
        return PingResult(ms: nil, rejected: false, failed: true)
    }
    if !honesty { return PingResult(ms: ms, rejected: false, failed: false) }
    guard let ttlm = ttlRe.firstMatch(in: out, range: range), let tlr = Range(ttlm.range(at: 1), in: out),
          let ttl = Int(out[tlr]) else {
        return PingResult(ms: nil, rejected: false, failed: true)
    }
    let initial = [64, 128, 255].filter { $0 >= ttl }.min() ?? 255
    if initial - ttl <= 1 { return PingResult(ms: nil, rejected: true, failed: false) }
    return PingResult(ms: ms, rejected: false, failed: false)
}

func tlsProbe() -> Double? {
    let conn = NWConnection(host: .init(tlsFallback.host), port: .init(rawValue: tlsFallback.port)!, using: .tls)
    let sem = DispatchSemaphore(value: 0); var ok = false; let t0 = Date()
    conn.stateUpdateHandler = { s in
        if case .ready = s { ok = true; sem.signal() }
        if case .failed = s { sem.signal() }
    }
    conn.start(queue: .global())
    _ = sem.wait(timeout: .now() + 4)
    conn.cancel()
    return ok ? Date().timeIntervalSince(t0) * 1000 : nil
}

struct WanProbe {
    var ms: Double?; var src: String?; var rejected: Int; var failed: Int; var total: Int; var gwMs: Double?
}

func probeWAN(forceTLS: Bool, lastTLS: inout Date?, gateway: String?, doGW: Bool) -> WanProbe {
    var honest: [Double] = [], rejected = 0, failed = 0, total = 0
    for h in icmpTargets {
        total += 1
        let r = pingHost(h, timeoutMs: "1000", honesty: true)
        if r.rejected { rejected += 1 }
        else if r.failed { failed += 1 }
        else if let m = r.ms { honest.append(m) }
    }
    var ms: Double?, src: String?
    if let m = honest.max() { ms = m; src = "icmp" }
    else {
        let due = forceTLS || lastTLS.map { Date().timeIntervalSince($0) >= fallbackInterval } ?? true
        if due {
            total += 1
            if let t = tlsProbe() { ms = t; src = "tls"; lastTLS = Date() }
            else { failed += 1; lastTLS = Date() }
        }
    }
    var gw: Double?
    if doGW, let g = gateway {
        let r = pingHost(g, timeoutMs: "500", honesty: false)
        gw = r.ms
    }
    return WanProbe(ms: ms, src: src, rejected: rejected, failed: failed, total: total, gwMs: gw)
}

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
    guard let out = runProc("/usr/sbin/ipconfig", ["getsummary", iface]) else { return nil }
    let re = try! NSRegularExpression(pattern: #"^\s*SSID : (.+)$"#, options: .anchorsMatchLines)
    let range = NSRange(out.startIndex..., in: out)
    guard let m = re.firstMatch(in: out, range: range), let r = Range(m.range(at: 1), in: out) else { return nil }
    return String(out[r])
}

func ssidProfiler(_ iface: String) -> String? {
    guard let out = runProc("/usr/sbin/system_profiler", ["SPAirPortDataType", "-json"]),
          let data = out.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let arr = json["SPAirPortDataType"] as? [[String: Any]], let root = arr.first,
          let ifaces = root["spairport_airport_interfaces"] as? [[String: Any]] else { return nil }
    for i in ifaces where (i["_name"] as? String) == iface {
        if let net = i["spairport_current_network_information"] as? [String: Any], let n = net["_name"] as? String { return n }
    }
    return nil
}

func resolveIdentity() -> Identity {
    let (iface, router) = parseRoute()
    guard let iface else {
        return Identity(iface: nil, type: "offline", network: nil, bssid: nil, router: nil, rssi: nil, noise: nil, txRate: nil, channel: nil)
    }
    let ports = hardwarePorts(); let port = ports[iface] ?? ""
    var type = "ethernet", network: String? = port.isEmpty ? iface : port
    var bssid: String?, rssi: Int?, noise: Int?, txRate: Double?, channel: Int?
    let isVPN = iface.hasPrefix("utun") || iface.hasPrefix("ipsec") || iface.hasPrefix("ppp")
    if port == "Wi-Fi" || port == "AirPort" { type = "wifi" }
    else if port.contains("iPhone") || port.contains("iPad") || port.contains("Bluetooth") { type = "tether" }
    else if isVPN { type = "vpn"; network = "VPN" }
    let wifiIf: String? = {
        if type == "wifi" { return iface }
        if type == "vpn" { return ports.first(where: { $0.value == "Wi-Fi" || $0.value == "AirPort" })?.key }
        return nil
    }()
    if let wif = wifiIf {
        let cw = CWWiFiClient.shared().interface(withName: wif)
        let ssid = cw?.ssid() ?? ssidIpconfig(wif) ?? ssidProfiler(wif)
        if let ssid { network = ssid }
        else { network = type == "wifi" ? "Wi-Fi" : "VPN" }
        bssid = cw?.bssid()
        if type == "wifi", let cw {
            let r = cw.rssiValue(); if r != 0 { rssi = r }
            let n = cw.noiseMeasurement(); if n != 0 { noise = n }
            let tr = cw.transmitRate(); if tr > 0 { txRate = tr }
            channel = cw.wlanChannel()?.channelNumber
        }
    } else if type == "wifi" {
        network = "Wi-Fi"
    }
    return Identity(iface: iface, type: type, network: network, bssid: bssid, router: router, rssi: rssi, noise: noise, txRate: txRate, channel: channel)
}

// TCC-free identity for --sample: steps 4b→4d only
func resolveIdentitySample() -> Identity {
    let (iface, router) = parseRoute()
    guard let iface else {
        return Identity(iface: nil, type: "offline", network: nil, bssid: nil, router: nil, rssi: nil, noise: nil, txRate: nil, channel: nil)
    }
    let ports = hardwarePorts(); let port = ports[iface] ?? ""
    var type = "ethernet", network: String? = port.isEmpty ? iface : port
    let isVPN = iface.hasPrefix("utun") || iface.hasPrefix("ipsec") || iface.hasPrefix("ppp")
    if port == "Wi-Fi" || port == "AirPort" { type = "wifi" }
    else if port.contains("iPhone") || port.contains("iPad") || port.contains("Bluetooth") { type = "tether"; network = port }
    else if isVPN { type = "vpn"; network = "VPN" }
    else { type = "ethernet"; network = port.isEmpty ? iface : port }
    let wifiIf: String? = type == "wifi" ? iface : (type == "vpn" ? ports.first(where: { $0.value == "Wi-Fi" || $0.value == "AirPort" })?.key : nil)
    if let wif = wifiIf {
        if let s = ssidIpconfig(wif) { network = s }
        else if let s = ssidProfiler(wif) { network = s }
        else { network = type == "vpn" ? "VPN" : "Wi-Fi" }
    }
    return Identity(iface: iface, type: type, network: network, bssid: nil, router: router, rssi: nil, noise: nil, txRate: nil, channel: nil)
}

func buildSampleJSON(id: Identity, secs: Double, latMs: Double?, latMin: Double?, latMax: Double?, latSrc: String?,
                     gwMs: Double?, loss: Double, rejected: Int, down: Double, up: Double, downPeak: Double, upPeak: Double) -> [String: Any] {
    func n(_ v: Double?) -> Any { v.map { $0 as Any } ?? NSNull() }
    func i(_ v: Int?) -> Any { v.map { $0 as Any } ?? NSNull() }
    func s(_ v: String?) -> Any { v.map { $0 as Any } ?? NSNull() }
    let fmt = ISO8601DateFormatter(); fmt.formatOptions = [.withInternetDateTime]
    return [
        "ts": fmt.string(from: Date()), "event": "sample", "secs": secs,
        "if": s(id.iface), "type": id.type, "network": s(id.network), "bssid": s(id.bssid), "router": s(id.router),
        "lat_ms": n(latMs), "lat_min": n(latMin), "lat_max": n(latMax), "lat_src": s(latSrc),
        "gw_ms": n(gwMs), "loss": loss, "rejected": rejected,
        "rssi": i(id.rssi), "noise": i(id.noise), "tx_rate_mbps": n(id.txRate), "channel": i(id.channel),
        "down_Bps": down, "up_Bps": up, "down_peak_Bps": downPeak, "up_peak_Bps": upPeak
    ]
}

func jsonLine(_ obj: [String: Any]) -> String? {
    guard let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) else { return nil }
    return s
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var peakItem: NSMenuItem!
    var speedItem: NSMenuItem!
    var locationManager: CLLocationManager?
    let session = URLSession(configuration: .default)
    var prev: Counters = Counters(); var prevAt = Date()
    var peakDown = 0.0, peakUp = 0.0, lastDown = 0.0, lastUp = 0.0
    var lastLatMs: Double?; var lastLatSrc: String?; var lastLatAt: Date?
    var identity = Identity(iface: nil, type: "offline", network: nil, bssid: nil, router: nil, rssi: nil, noise: nil, txRate: nil, channel: nil)
    var winStart = Date()
    var winLats: [Double] = []; var winLatSrc: String?
    var winGW: [Double] = []; var winRejected = 0; var winFailed = 0; var winTotal = 0
    var winDownSum = 0.0, winUpSum = 0.0, winTicks = 0
    var winDownPeak = 0.0, winUpPeak = 0.0
    var probeQ = DispatchQueue(label: "netmenu.probe", qos: .utility)
    var idQ = DispatchQueue(label: "netmenu.id", qos: .utility)

    var statsURL: URL {
        let b = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let d = b.appendingPathComponent("NetMenu", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("stats.jsonl")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Draw into a fixed-size template image with 3 column anchors — status-item titles reflow/trim text.
        statusItem = NSStatusBar.system.statusItem(withLength: Self.statusWidth)
        statusItem.button?.imagePosition = .imageOnly
        paintStatus(lat: "✕", down: "0B", up: "0B")
        let menu = NSMenu()
        peakItem = NSMenuItem(title: "Peak this session: —", action: nil, keyEquivalent: "")
        peakItem.isEnabled = false; menu.addItem(peakItem)
        speedItem = NSMenuItem(title: "No speed test run yet", action: nil, keyEquivalent: "")
        speedItem.isEnabled = false; menu.addItem(speedItem)
        let st = NSMenuItem(title: "Run speed test (uses ~7 MB)", action: #selector(runSpeedTest), keyEquivalent: "")
        st.target = self; menu.addItem(st)
        let rev = NSMenuItem(title: "Reveal stats file", action: #selector(revealStats), keyEquivalent: "")
        rev.target = self; menu.addItem(rev)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        locationManager = CLLocationManager()
        if locationManager!.authorizationStatus == .notDetermined {
            locationManager!.requestWhenInUseAuthorization()
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

    func refreshIdentity() {
        let new = resolveIdentity()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !new.sameNetwork(as: self.identity) {
                self.flushLog()
                self.resetWindow()
                self.identity = new
            } else {
                self.identity = new
            }
        }
    }

    func resetWindow() {
        winStart = Date(); winLats = []; winLatSrc = nil; winGW = []
        winRejected = 0; winFailed = 0; winTotal = 0
        winDownSum = 0; winUpSum = 0; winTicks = 0; winDownPeak = 0; winUpPeak = 0
    }

    func tick() {
        let now = Date(); let dt = now.timeIntervalSince(prevAt)
        let cur = readCounters()
        if dt > 5 {
            prev = cur; prevAt = now; resetWindow(); return
        }
        let (down, up) = deltaRates(old: prev, new: cur, dt: dt)
        prev = cur; prevAt = now; lastDown = down; lastUp = up
        if down > peakDown { peakDown = down }
        if up > peakUp { peakUp = up }
        winDownSum += down; winUpSum += up; winTicks += 1
        if down > winDownPeak { winDownPeak = down }
        if up > winUpPeak { winUpPeak = up }
        updateTitle(); peakItem.title = "Peak this session: \(fmtRate(peakDown))↓ / \(fmtRate(peakUp))↑"
    }

    static let statusFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    // lat | num↓ | num↑ — arrows fixed after values; nums right-aligned in minimal slots
    static let statusLayout: (w: CGFloat, latEdge: CGFloat, downEdge: CGFloat, downArr: CGFloat, upEdge: CGFloat, upArr: CGFloat) = {
        let a: [NSAttributedString.Key: Any] = [.font: statusFont]
        func sw(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: a).width }
        let latW = sw("~9999ms"), arrW = max(sw("↓"), sw("↑")), numW = sw("1000.0M")
        let g: CGFloat = 4, ga: CGFloat = 1  // group gap, number→arrow gap
        let latEdge = latW
        let downEdge = latEdge + g + numW
        let downArr = downEdge + ga
        let upEdge = downArr + arrW + g + numW
        let upArr = upEdge + ga
        return (upArr + arrW, latEdge, downEdge, downArr, upEdge, upArr)
    }()
    static let statusWidth: CGFloat = statusLayout.w

    func paintStatus(lat: String, down: String, up: String) {
        let L = Self.statusLayout
        let img = NSImage(size: NSSize(width: L.w, height: 18), flipped: false) { _ in
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.statusFont, .foregroundColor: NSColor.black]
            func drawRight(_ s: String, _ edge: CGFloat) {
                let sz = (s as NSString).size(withAttributes: attrs)
                (s as NSString).draw(at: NSPoint(x: edge - sz.width, y: 2), withAttributes: attrs)
            }
            drawRight(lat, L.latEdge)
            drawRight(down, L.downEdge)
            ("↓" as NSString).draw(at: NSPoint(x: L.downArr, y: 2), withAttributes: attrs)
            drawRight(up, L.upEdge)
            ("↑" as NSString).draw(at: NSPoint(x: L.upArr, y: 2), withAttributes: attrs)
            return true
        }
        img.isTemplate = true
        statusItem.button?.image = img
    }

    func updateTitle() {
        let lat: String
        if let m = lastLatMs, let at = lastLatAt, Date().timeIntervalSince(at) <= staleAfter {
            let n = Int(m.rounded())
            lat = lastLatSrc == "tls" ? "~\(n)ms" : "\(n)ms"
        } else { lat = "✕" }
        paintStatus(lat: lat, down: fmtRate(lastDown), up: fmtRate(lastUp))
    }

    func probeLoop() {
        var tls: Date?
        while true {
            let probeIdentity = DispatchQueue.main.sync { identity }
            let r = probeWAN(forceTLS: false, lastTLS: &tls, gateway: probeIdentity.router, doGW: true)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.identity.sameNetwork(as: probeIdentity) else { return }
                self.winTotal += r.total; self.winRejected += r.rejected; self.winFailed += r.failed
                if let m = r.ms {
                    self.lastLatMs = m; self.lastLatSrc = r.src; self.lastLatAt = Date()
                    self.winLats.append(m); self.winLatSrc = r.src
                }
                if let g = r.gwMs { self.winGW.append(g) }
                self.updateTitle()
            }
            Thread.sleep(forTimeInterval: probeInterval)
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
                                  rejected: winRejected, down: down, up: up, downPeak: winDownPeak, upPeak: winUpPeak)
        if let line = jsonLine(obj), let data = (line + "\n").data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: statsURL) {
                _ = try? h.seekToEnd(); _ = try? h.write(contentsOf: data); _ = try? h.close()
            } else {
                try? data.write(to: statsURL)
            }
        }
        resetWindow()
    }

    @objc func revealStats() {
        _ = statsURL
        NSWorkspace.shared.activateFileViewerSelecting([statsURL])
    }

    @objc func runSpeedTest() {
        guard speedItem.title != "Testing…" else { return }
        speedItem.title = "Testing…"
        let sess = session, testIdentity = identity
        func req(_ url: String, method: String = "GET", body: Data? = nil) -> URLRequest {
            var r = URLRequest(url: URL(string: url)!); r.httpMethod = method
            r.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            r.cachePolicy = .reloadIgnoringLocalCacheData; r.timeoutInterval = 15; r.httpBody = body
            return r
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let (warm, _) = try sess.synchronousData(req("https://speed.cloudflare.com/__down?bytes=1000000"))
                guard warm.count == 1_000_000 else { throw URLError(.badServerResponse) }
                let t0 = Date()
                let (timed, _) = try sess.synchronousData(req("https://speed.cloudflare.com/__down?bytes=4000000"))
                guard timed.count == 4_000_000 else { throw URLError(.badServerResponse) }
                let downMbps = 4_000_000.0 * 8 / Date().timeIntervalSince(t0) / 1e6
                _ = try sess.synchronousData(req("https://speed.cloudflare.com/__up", method: "POST", body: Data(count: 500_000)))
                let t1 = Date()
                _ = try sess.synchronousData(req("https://speed.cloudflare.com/__up", method: "POST", body: Data(count: 1_500_000)))
                let upMbps = 1_500_000.0 * 8 / Date().timeIntervalSince(t1) / 1e6
                DispatchQueue.main.async {
                    guard self.identity.sameNetwork(as: testIdentity) else { self.speedItem.title = "Test failed — click to retry"; return }
                    self.speedItem.title = String(format: "Last test: %.0f↓ / %.0f↑ Mbps", downMbps, upMbps)
                    let fmt = ISO8601DateFormatter(); fmt.formatOptions = [.withInternetDateTime]
                    let obj: [String: Any] = [
                        "ts": fmt.string(from: Date()), "event": "speedtest",
                        "type": testIdentity.type, "network": testIdentity.network as Any? ?? NSNull(),
                        "down_mbps": Int(downMbps.rounded()), "up_mbps": Int(upMbps.rounded())
                    ]
                    if let line = jsonLine(obj), let data = (line + "\n").data(using: .utf8) {
                        if let h = try? FileHandle(forWritingTo: self.statsURL) {
                            _ = try? h.seekToEnd(); _ = try? h.write(contentsOf: data); _ = try? h.close()
                        } else { try? data.write(to: self.statsURL) }
                    }
                }
            } catch {
                DispatchQueue.main.async { self.speedItem.title = "Test failed — click to retry" }
            }
        }
    }
}

extension URLSession {
    func synchronousData(_ request: URLRequest) throws -> (Data, URLResponse) {
        var result: Result<(Data, URLResponse), Error>!
        let sem = DispatchSemaphore(value: 0)
        dataTask(with: request) { data, resp, err in
            if let err { result = .failure(err) }
            else if let data, let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                result = .success((data, http))
            }
            else { result = .failure(URLError(.unknown)) }
            sem.signal()
        }.resume()
        sem.wait()
        return try result.get()
    }
}

if CommandLine.arguments.contains("--sample") {
    let c0 = readCounters(); Thread.sleep(forTimeInterval: 1); let c1 = readCounters()
    let (down, up) = deltaRates(old: c0, new: c1, dt: 1)
    var tls: Date? = nil
    let r = probeWAN(forceTLS: true, lastTLS: &tls, gateway: nil, doGW: false)
    let id = resolveIdentitySample()
    let latStr = r.ms.map { String(format: "%.1f", $0) } ?? "nan"
    let netJSON = String(data: try! JSONSerialization.data(withJSONObject: [id.network ?? "none"]), encoding: .utf8)!
    print("latency_ms=\(latStr) down_Bps=\(UInt64(down.rounded())) up_Bps=\(UInt64(up.rounded())) type=\(id.type) network=\(netJSON.dropFirst().dropLast())")
    let loss = r.total > 0 ? Double(r.failed + r.rejected) / Double(r.total) : 1.0
    let obj = buildSampleJSON(id: id, secs: 1, latMs: r.ms, latMin: r.ms, latMax: r.ms, latSrc: r.src,
                              gwMs: nil, loss: r.ms == nil ? 1.0 : loss, rejected: r.rejected,
                              down: down, up: up, downPeak: down, upPeak: up)
    if let line = jsonLine(obj) { print(line) }
    exit(0)
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
