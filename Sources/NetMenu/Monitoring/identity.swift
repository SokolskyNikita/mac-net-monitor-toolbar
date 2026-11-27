import Foundation
import CoreWLAN

private enum InterfaceKind {
    static let vpnPrefixes = ["utun", "ipsec", "ppp"]
    static let tetherPortFragments = ["iPhone", "iPad", "Bluetooth"]
    static func isVPN(_ name: String) -> Bool { vpnPrefixes.contains(where: name.hasPrefix) }
    static func isTether(_ port: String) -> Bool { tetherPortFragments.contains(where: port.contains) }
}

private let ssidRe = try? NSRegularExpression(pattern: #"^\s*SSID : (.+)$"#, options: .anchorsMatchLines)

struct Identity: Equatable {
    var iface: String?; var type: String; var network: String?; var bssid: String?
    var router: String?; var rssi: Int?; var noise: Int?; var txRate: Double?; var channel: Int?
    var localRouter: LocalRouter? = nil
    func sameNetwork(as x: Identity) -> Bool {
        guard iface == x.iface && type == x.type && router == x.router, localRouter == x.localRouter else { return false }
        if network == x.network && bssid == x.bssid { return true }
        // Learning the name of the same link (Location access resolving after launch) is not a change.
        return isUnnamedWiFi || x.isUnnamedWiFi
    }

    /// Wi-Fi whose SSID and BSSID macOS has not revealed yet.
    var isUnnamedWiFi: Bool { type == NetType.wifi && bssid == nil && network == PortName.wifi }
}

/// The answers `route`, `netstat` and `ipconfig` gave for the current default routes. Those
/// helpers ran on every identity poll although their answers change only when the default
/// routes do, so each poll now reads the routing table in-process and runs a helper again
/// only when a default route differs, a network event invalidates the cache, or it expires.
final class RouteCache: @unchecked Sendable {
    static let shared = RouteCache()

    private struct Answers {
        var routes: Data
        var readAt: TimeInterval
        var route: (iface: String?, gateway: String?)?
        var localRouters: [String: LocalRouter?] = [:]
        var ssids: [String: (name: String?, at: TimeInterval)] = [:]
    }
    private let lock = NSLock()
    private var generation = 0
    private var answers: Answers?
    private let lifetime: TimeInterval
    private let nameLifetime: TimeInterval
    private let readRoutes: () -> Data?

    init(lifetime: TimeInterval = Configuration.monitoring.routeCacheLifetime,
         nameLifetime: TimeInterval = Configuration.monitoring.networkNameCacheLifetime,
         readRoutes: @escaping () -> Data? = RouteCache.defaultRoutes) {
        self.lifetime = lifetime; self.nameLifetime = nameLifetime; self.readRoutes = readRoutes
    }

    /// A wake or path change can swap networks and leave identical default routes behind.
    func invalidate() {
        lock.lock(); generation &+= 1; answers = nil; lock.unlock()
    }

    /// A helper's answer and whether it may be reused. A helper that failed to run or timed out
    /// looks like "nothing there"; keeping that would hold a wrong answer until the cache expires.
    typealias Asked<T> = (answer: T, reliable: Bool)

    func route(_ ask: () -> Asked<(iface: String?, gateway: String?)>) -> (iface: String?, gateway: String?) {
        answer(read: { $0.route }, write: { $0.route = $1 }, ask: ask)
    }

    func localRouter(key: String, _ ask: () -> Asked<LocalRouter?>) -> LocalRouter? {
        answer(read: { $0.localRouters[key] }, write: { $0.localRouters[key] = .some($1) }, ask: ask)
    }

    func ssid(interface: String, _ ask: () -> Asked<String?>) -> String? {
        // The name is the one answer that can change while the routes stay byte-identical.
        let now = BandwidthClock.now()
        return answer(read: { answers in answers.ssids[interface].flatMap { now - $0.at < self.nameLifetime ? .some($0.name) : nil } },
                      write: { $0.ssids[interface] = ($1, now) }, ask: ask)
    }

    private func answer<T>(read: (Answers) -> T?, write: (inout Answers, T) -> Void, ask: () -> Asked<T>) -> T {
        // Without a readable routing table nothing is known to be unchanged: always ask.
        guard let routes = readRoutes() else { return ask().answer }
        let now = BandwidthClock.now()
        lock.lock()
        if let current = answers, current.routes != routes || now - current.readAt >= lifetime { answers = nil }
        if let known = answers.flatMap(read) { lock.unlock(); return known }
        let asked = generation
        lock.unlock()

        let (fresh, reliable) = ask()
        // Keep the answer only if the helper ran properly and the routes it describes were in
        // place throughout.
        guard reliable, readRoutes() == routes else { return fresh }
        lock.lock(); defer { lock.unlock() }
        guard generation == asked else { return fresh }
        if answers?.routes != routes { answers = Answers(routes: routes, readAt: now) }
        if var current = answers { write(&current, fresh); answers = current }
        return fresh
    }

    /// The stable part of every default route: flags, interface and addresses, without the
    /// traffic counters that change with each packet. Two networks with the same interface and
    /// gateway address read alike (the gateway's hardware address is not visible to an
    /// unprivileged process), which is why network events also invalidate the cache and the
    /// network name is kept for a shorter time.
    static func defaultRoutes() -> Data? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_DUMP2, 0]
        for _ in 0..<4 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var bytes = [UInt8](repeating: 0, count: size + 4096)
            var actualSize = bytes.count
            let result = bytes.withUnsafeMutableBytes { sysctl(&mib, u_int(mib.count), $0.baseAddress, &actualSize, nil, 0) }
            if result == 0 { return bytes.withUnsafeBytes { defaultRoutes(in: UnsafeRawBufferPointer(rebasing: $0[..<actualSize])) } }
            guard errno == ENOMEM else { return nil }
        }
        return nil
    }

    static func defaultRoutes(in dump: UnsafeRawBufferPointer) -> Data {
        var stable = Data()
        let header = MemoryLayout<rt_msghdr2>.stride
        var offset = 0
        while offset + header <= dump.count {
            var message = rt_msghdr2()
            withUnsafeMutableBytes(of: &message) { $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: dump[offset..<offset + header])) }
            let length = Int(message.rtm_msglen)
            guard length >= header, offset + length <= dump.count else { break }
            let addresses = UnsafeRawBufferPointer(rebasing: dump[(offset + header)..<(offset + length)])
            if message.rtm_flags & (RTF_HOST | RTF_WASCLONED) == 0, message.rtm_addrs & RTA_DST != 0,
               isUnspecifiedAddress(addresses) {
                withUnsafeBytes(of: message.rtm_flags) { stable.append(contentsOf: $0) }
                withUnsafeBytes(of: message.rtm_index) { stable.append(contentsOf: $0) }
                withUnsafeBytes(of: message.rtm_addrs) { stable.append(contentsOf: $0) }
                withUnsafeBytes(of: UInt16(addresses.count)) { stable.append(contentsOf: $0) }
                stable.append(contentsOf: addresses)
            }
            offset += length
        }
        return stable
    }

    /// Whether the destination that starts `addresses` is 0.0.0.0 or ::, i.e. a default route.
    private static func isUnspecifiedAddress(_ addresses: UnsafeRawBufferPointer) -> Bool {
        guard addresses.count >= 2 else { return false }
        let length = Int(addresses[0])
        let range: Range<Int>
        switch Int32(addresses[1]) {
        case AF_INET: range = 4..<8
        case AF_INET6: range = 8..<24
        default: return false
        }
        // The kernel shortens an all-zero address; the bytes it leaves out are zero.
        guard length <= addresses.count else { return false }
        return addresses[..<length].dropFirst(range.lowerBound).prefix(range.count).allSatisfy { $0 == 0 }
    }
}

func parseRoute() -> (iface: String?, gateway: String?) {
    RouteCache.shared.route(runRoute)
}

/// Reliable only if every `route` run it rests on finished by itself. One that timed out or
/// could not start says nothing, and must not let the IPv6 route stand in for the IPv4 one.
private func runRoute() -> RouteCache.Asked<(iface: String?, gateway: String?)> {
    func parse(_ out: String) -> (String?, String?) {
        var iface: String?, gw: String?
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("interface:") { iface = t.replacingOccurrences(of: "interface:", with: "").trimmingCharacters(in: .whitespaces) }
            if t.hasPrefix("gateway:") { gw = t.replacingOccurrences(of: "gateway:", with: "").trimmingCharacters(in: .whitespaces) }
        }
        return (iface, gw)
    }
    func finished(_ result: ProcResult) -> Bool {
        if case .exited = result.outcome { return true }
        return false
    }
    let v4 = runProcess("/sbin/route", ["-n", "get", "default"])
    if v4.launched, let route = Optional(parse(v4.stdout)), route.0 != nil { return (route, finished(v4)) }
    let v6 = runProcess("/sbin/route", ["-n", "get", "-inet6", "default"])
    return (v6.launched ? parse(v6.stdout) : (nil, nil), finished(v4) && finished(v6))
}

private let portsLock = NSLock()
private var cachedPorts: (at: TimeInterval, map: [String: String])?
private let portsMaxAge = Configuration.monitoring.portsCacheLifetime

/// Interface → hardware port names rarely change; re-read them every 5 minutes, or at once when
/// `iface` is missing (a newly attached adapter or tethered phone).
func hardwarePorts(including iface: String? = nil) -> [String: String] {
    let now = BandwidthClock.now()
    portsLock.lock()
    let cached = cachedPorts
    portsLock.unlock()
    // VPN interfaces are never hardware ports, so their absence is not a reason to re-read.
    let expected = iface.map { !InterfaceKind.isVPN($0) } ?? false
    if let cached, now - cached.at < portsMaxAge, !expected || iface.map({ cached.map[$0] != nil }) == true {
        return cached.map
    }
    let map = hardwarePortsUncached()
    if !map.isEmpty { portsLock.lock(); cachedPorts = (now, map); portsLock.unlock() }
    return map
}

private func hardwarePortsUncached() -> [String: String] {
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

func isRedactedSSID(_ ssid: String) -> Bool {
    let t = ssid.trimmingCharacters(in: .whitespaces)
    return t.isEmpty || t == "<redacted>"
}

func ssidIpconfig(_ iface: String) -> String? {
    RouteCache.shared.ssid(interface: iface) { runIpconfig(iface) }
}

private func runIpconfig(_ iface: String) -> RouteCache.Asked<String?> {
    let result = runProcess("/usr/sbin/ipconfig", ["getsummary", iface], timeout: Configuration.monitoring.ipconfigTimeout)
    guard result.launched, let re = ssidRe else { return (nil, false) }
    let out = result.stdout
    let range = NSRange(out.startIndex..., in: out)
    guard let m = re.firstMatch(in: out, range: range), let r = Range(m.range(at: 1), in: out) else { return (nil, result.succeeded) }
    let ssid = String(out[r])
    return (isRedactedSSID(ssid) ? nil : ssid, result.succeeded)
}

/// CoreWLAN is touchy off-main; hop to main briefly for CW* reads only.
func wifiDetails(iface: String) -> (ssid: String?, bssid: String?, rssi: Int?, noise: Int?, txRate: Double?, channel: Int?) {
    var result: (String?, String?, Int?, Int?, Double?, Int?) = (nil, nil, nil, nil, nil, nil)
    let work = {
        guard let cw = CWWiFiClient.shared().interface(withName: iface) else { return }
        // Before Location access resolves, macOS returns a placeholder instead of the name.
        result.0 = cw.ssid().flatMap { isRedactedSSID($0) ? nil : $0 }
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
    let ports = hardwarePorts(including: iface); let port = ports[iface] ?? ""
    var type = NetType.ethernet, network: String? = port.isEmpty ? iface : port
    var bssid: String?, rssi: Int?, noise: Int?, txRate: Double?, channel: Int?
    let isVPN = InterfaceKind.isVPN(iface)
    if port == PortName.wifi || port == PortName.airPort { type = NetType.wifi }
    else if InterfaceKind.isTether(port) { type = NetType.tether }
    else if isVPN { type = NetType.vpn; network = PortName.vpn }
    let wifiIf: String? = {
        if type == NetType.wifi { return iface }
        if type == NetType.vpn { return ports.first(where: { $0.value == PortName.wifi || $0.value == PortName.airPort })?.key }
        return nil
    }()
    if let wif = wifiIf {
        let w = wifiDetails(iface: wif)
        // Read current connection metadata only; system_profiler can trigger Wi-Fi scans.
        let ssid = w.ssid ?? ssidIpconfig(wif)
        if let ssid { network = ssid }
        else { network = type == NetType.wifi ? PortName.wifi : PortName.vpn }
        bssid = w.bssid
        if type == NetType.wifi {
            rssi = w.rssi; noise = w.noise; txRate = w.txRate; channel = w.channel
        }
    } else if type == NetType.wifi {
        network = PortName.wifi
    }
    return Identity(iface: iface, type: type, network: network, bssid: bssid, router: router, rssi: rssi, noise: noise, txRate: txRate, channel: channel,
                    localRouter: resolveLocalRouter(preferred: iface, ports: ports))
}

// Identity for --sample without CoreWLAN or Location authorization requests.
func resolveIdentitySample() -> Identity {
    let (iface, router) = parseRoute()
    guard let iface else {
        return Identity(iface: nil, type: NetType.offline, network: nil, bssid: nil, router: nil, rssi: nil, noise: nil, txRate: nil, channel: nil)
    }
    let ports = hardwarePorts(including: iface); let port = ports[iface] ?? ""
    var type = NetType.ethernet, network: String? = port.isEmpty ? iface : port
    let isVPN = InterfaceKind.isVPN(iface)
    if port == PortName.wifi || port == PortName.airPort { type = NetType.wifi }
    else if InterfaceKind.isTether(port) { type = NetType.tether; network = port }
    else if isVPN { type = NetType.vpn; network = PortName.vpn }
    else { type = NetType.ethernet; network = port.isEmpty ? iface : port }
    let wifiIf: String? = type == NetType.wifi ? iface : (type == NetType.vpn ? ports.first(where: { $0.value == PortName.wifi || $0.value == PortName.airPort })?.key : nil)
    if let wif = wifiIf {
        if let s = ssidIpconfig(wif) { network = s }
        else { network = type == NetType.vpn ? PortName.vpn : PortName.wifi }
    }
    return Identity(iface: iface, type: type, network: network, bssid: nil, router: router, rssi: nil, noise: nil, txRate: nil, channel: nil)
}
