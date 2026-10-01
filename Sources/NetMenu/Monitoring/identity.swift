import Foundation
import CoreWLAN

private let ssidRe = try? NSRegularExpression(pattern: #"^\s*SSID : (.+)$"#, options: .anchorsMatchLines)

struct Identity: Equatable {
    var iface: String?; var type: String; var network: String?; var bssid: String?
    var router: String?; var rssi: Int?; var noise: Int?; var txRate: Double?; var channel: Int?
    func sameNetwork(as x: Identity) -> Bool {
        guard iface == x.iface && type == x.type && router == x.router else { return false }
        if network == x.network && bssid == x.bssid { return true }
        // Learning the name of the same link (Location access resolving after launch) is not a change.
        return isUnnamedWiFi || x.isUnnamedWiFi
    }

    /// Wi-Fi whose SSID and BSSID macOS has not revealed yet.
    var isUnnamedWiFi: Bool { type == NetType.wifi && bssid == nil && network == PortName.wifi }
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

private let portsLock = NSLock()
private var cachedPorts: (at: TimeInterval, map: [String: String])?
private let portsMaxAge: TimeInterval = 300

/// Interface → hardware port names rarely change; re-read them every 5 minutes, or at once when
/// `iface` is missing (a newly attached adapter or tethered phone).
func hardwarePorts(including iface: String? = nil) -> [String: String] {
    let now = BandwidthClock.now()
    portsLock.lock()
    let cached = cachedPorts
    portsLock.unlock()
    // VPN interfaces are never hardware ports, so their absence is not a reason to re-read.
    let expected = iface.map { !["utun", "ipsec", "ppp"].contains(where: $0.hasPrefix) } ?? false
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
    guard let out = runProc("/usr/sbin/ipconfig", ["getsummary", iface], timeout: 5),
          let re = ssidRe else { return nil }
    let range = NSRange(out.startIndex..., in: out)
    guard let m = re.firstMatch(in: out, range: range), let r = Range(m.range(at: 1), in: out) else { return nil }
    let ssid = String(out[r])
    return isRedactedSSID(ssid) ? nil : ssid
}

private let profilerLock = NSLock()
private var profilerFailedAt: TimeInterval?
/// system_profiler takes ~5s and, without Location access, only returns "<redacted>".
private let profilerRetryAfter: TimeInterval = 600

func ssidProfiler(_ iface: String) -> String? {
    let now = BandwidthClock.now()
    profilerLock.lock()
    let skip = profilerFailedAt.map { now - $0 < profilerRetryAfter } ?? false
    profilerLock.unlock()
    guard !skip else { return nil }
    let name = ssidProfilerUncached(iface)
    profilerLock.lock(); profilerFailedAt = name == nil ? now : nil; profilerLock.unlock()
    return name
}

private func ssidProfilerUncached(_ iface: String) -> String? {
    // system_profiler can be huge/slow — timeout + async pipe drain in runProc avoids hangs.
    guard let out = runProc("/usr/sbin/system_profiler", ["SPAirPortDataType", "-json"], timeout: 12),
          let data = out.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let arr = json["SPAirPortDataType"] as? [[String: Any]], let root = arr.first,
          let ifaces = root["spairport_airport_interfaces"] as? [[String: Any]] else { return nil }
    for i in ifaces where (i["_name"] as? String) == iface {
        if let net = i["spairport_current_network_information"] as? [String: Any], let n = net["_name"] as? String,
           !isRedactedSSID(n) { return n }
    }
    return nil
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
    let ports = hardwarePorts(including: iface); let port = ports[iface] ?? ""
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
