import Foundation

/// Established TCP connections plus interface-bound UDP sockets; directions overlap.
struct ConnectionCounts: Equatable {
    var open = 0
    var receiving = 0
    var sending = 0
    var processCounts: [Int32: Int] = [:]
    var apps: [AppConnectionUsage] = []
    var packetsReceived = 0
    var packetsSent = 0
    var processPackets: [Int32: PacketCounts] = [:]

    var readout: MenuReadout {
        .row(.connections, value: "\(packetsReceived) received · \(packetsSent) sent packets / \(Int(Configuration.monitoring.appSampleInterval))s")
    }
    var title: String { readout.title }
    var json: [String: Any] {
        ["open": open, "receiving": receiving, "sending": sending,
         "window_s": AppBandwidthMonitor.sampleInterval,
         "packets_received": packetsReceived, "packets_sent": packetsSent, "ranking_basis": "packets",
         "apps": apps.map { ["name": $0.name, "open": $0.open, "packets_received": $0.received, "packets_sent": $0.sent] as [String: Any] }]
    }

    static func parse(_ output: String) -> Self? {
        var tables = 0
        var result = Self()
        var owner: Int32?
        var columns: [String] = []
        for line in output.components(separatedBy: .newlines) {
            if line.hasPrefix(NettopFormat.headerPrefix) {
                columns = Array(line.components(separatedBy: ",").dropFirst().dropLast())
                guard NettopFormat.counterColumns.allSatisfy(columns.contains) else { return nil }
                tables += 1
                result = Self()
                owner = nil
                continue
            }
            guard tables == 2 else { continue }
            var fields = line.components(separatedBy: ",")
            if fields.last == "" { fields.removeLast() }
            guard fields.count >= columns.count + 1 else { continue }
            let label = fields.dropLast(columns.count).joined(separator: ",")
            guard NettopFormat.socketPrefixes.contains(where: label.hasPrefix) else {
                owner = label.split(separator: ".").last.flatMap { Int32($0) }
                continue
            }
            let tail = Array(fields.suffix(columns.count))
            guard !tail[0].isEmpty, tail[0] != NettopFormat.loopbackInterface,
                  NettopFormat.udpPrefixes.contains(where: label.hasPrefix) || tail[1] == NettopFormat.established else { continue }
            func number(_ name: String) -> Int? {
                guard let index = columns.firstIndex(of: name), let value = Int(tail[index]), value >= 0 else { return nil }
                return value
            }
            guard let incoming = number(NettopFormat.bytesIn), let outgoing = number(NettopFormat.bytesOut),
                  let received = number(NettopFormat.packetsIn), let sent = number(NettopFormat.packetsOut) else { return nil }
            result.packetsReceived += received
            result.packetsSent += sent
            if let owner {
                result.processPackets[owner, default: PacketCounts()].received += received
                result.processPackets[owner, default: PacketCounts()].sent += sent
            }
            result.open += 1
            if let owner { result.processCounts[owner, default: 0] += 1 }
            if incoming > 0 { result.receiving += 1 }
            if outgoing > 0 { result.sending += 1 }
        }
        return tables == 2 ? result : nil
    }
}

struct ConnectionDisplay {
    let config: MonitoringConfig
    init(config: MonitoringConfig = Configuration.monitoring) { self.config = config }
    private var counts: ConnectionCounts?
    private var sampledAt: TimeInterval?

    mutating func record(_ counts: ConnectionCounts?, at: TimeInterval) {
        self.counts = counts
        sampledAt = at
    }

    func fresh(at: TimeInterval) -> ConnectionCounts? {
        guard let sampledAt, at >= sampledAt, at - sampledAt <= config.appFreshFor else { return nil }
        return counts
    }

    func consumersReadout(at: TimeInterval) -> MenuReadout {
        fresh(at: at).map { TopConnectionApps($0).readout }
            ?? .row(.connectionApps, value: sampledAt == nil ? "measuring…" : "unavailable")
    }

    func consumersTitle(at: TimeInterval) -> String { consumersReadout(at: at).title }

    func readout(at: TimeInterval) -> MenuReadout {
        fresh(at: at)?.readout ?? .row(.connections, value: sampledAt == nil ? "measuring…" : "unavailable")
    }

    func title(at: TimeInterval) -> String { readout(at: at).title }
}

struct PacketCounts: Equatable {
    var received = 0
    var sent = 0
}

struct AppConnectionUsage: Equatable {
    var id: String? = nil
    let name: String
    var open = 0
    var received = 0
    var sent = 0
    var packets: Int { received + sent }
}

struct TopConnectionApps {
    let apps: [AppConnectionUsage]
    let total: Int

    init(_ counts: ConnectionCounts) {
        var grouped: [String: AppConnectionUsage] = [:]
        for app in counts.apps where app.packets > 0 {
            let name = TopBandwidthApps.cleanName(app.name)
            let key = app.id ?? name.lowercased()
            let old = grouped[key]
            grouped[key] = AppConnectionUsage(id: app.id, name: old.map { min($0.name, name) } ?? name,
                                               open: (old?.open ?? 0) + app.open,
                                               received: (old?.received ?? 0) + app.received,
                                               sent: (old?.sent ?? 0) + app.sent)
        }
        let ranked = grouped.values.sorted { $0.packets == $1.packets ? $0.name < $1.name : $0.packets > $1.packets }
        total = max(counts.packetsReceived + counts.packetsSent, ranked.reduce(0) { $0 + $1.packets })
        apps = TopBandwidthApps.coveringPrefix(ranked, total: Double(total)) { Double($0.packets) }
    }

    var title: String { readout.title }

    var readout: MenuReadout {
        guard !apps.isEmpty else {
            return .row(.connectionApps, value: total == 0 ? "no packet traffic" : "unavailable")
        }
        let share = Int(floor(Double(apps.reduce(0) { $0 + $1.packets }) / Double(total) * 100))
        return .row(.connectionApps, value: apps.map { TopBandwidthApps.menuName($0.name) }.joined(separator: ", "),
                    qualifier: " (~\(share)%)")
    }
}
