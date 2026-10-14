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

    var title: String { "Connections: \(packetsReceived) received · \(packetsSent) sent packets / 10s" }
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
            if line.hasPrefix(",interface,state,") {
                columns = Array(line.components(separatedBy: ",").dropFirst().dropLast())
                guard ["packets_in", "packets_out", "bytes_in", "bytes_out"].allSatisfy(columns.contains) else { return nil }
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
            guard ["tcp4 ", "tcp6 ", "udp4 ", "udp6 "].contains(where: label.hasPrefix) else {
                owner = label.split(separator: ".").last.flatMap { Int32($0) }
                continue
            }
            let tail = Array(fields.suffix(columns.count))
            guard !tail[0].isEmpty, tail[0] != "lo0",
                  label.hasPrefix("udp") || tail[1] == "Established" else { continue }
            func number(_ name: String) -> Int? {
                guard let index = columns.firstIndex(of: name), let value = Int(tail[index]), value >= 0 else { return nil }
                return value
            }
            guard let incoming = number("bytes_in"), let outgoing = number("bytes_out"),
                  let received = number("packets_in"), let sent = number("packets_out") else { return nil }
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
    private var counts: ConnectionCounts?
    private var sampledAt: TimeInterval?

    mutating func record(_ counts: ConnectionCounts?, at: TimeInterval) {
        self.counts = counts
        sampledAt = at
    }

    func fresh(at: TimeInterval) -> ConnectionCounts? {
        guard let sampledAt, at >= sampledAt, at - sampledAt <= 15 else { return nil }
        return counts
    }

    func consumersTitle(at: TimeInterval) -> String {
        fresh(at: at).map { TopConnectionApps($0).title }
            ?? (sampledAt == nil ? "Top conn. consumers: measuring…" : "Top conn. consumers: unavailable")
    }

    func title(at: TimeInterval) -> String {
        fresh(at: at)?.title ?? (sampledAt == nil ? "Connections: measuring…" : "Connections: unavailable")
    }
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

    var title: String {
        guard !apps.isEmpty else {
            return total == 0 ? "Top conn. consumers: no packet traffic" : "Top conn. consumers: unavailable"
        }
        let share = Int(floor(Double(apps.reduce(0) { $0 + $1.packets }) / Double(total) * 100))
        return "Top conn. consumers (~\(share)%): " + apps.map { TopBandwidthApps.menuName($0.name) }.joined(separator: ", ")
    }
}
