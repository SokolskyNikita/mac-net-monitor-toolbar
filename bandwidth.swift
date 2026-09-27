// Live throughput from interface byte counters, independent of the menu bar UI.

import Darwin
import Foundation

struct Counters {
    var rx: [String: UInt64] = [:]
    var tx: [String: UInt64] = [:]
}

/// Parses the RTM_IFINFO2 records returned by NET_RT_IFLIST2. Names are supplied separately so
/// the binary parser can be tested with synthetic buffers and unknown interface indexes.
enum BandwidthCounterReader {
    static func parseRouteDump(_ bytes: Data, interfaceNames: [UInt16: String]) -> Counters {
        parseRouteDump(bytes) { interfaceNames[$0] }
    }

    static func parseRouteDump(_ bytes: Data, interfaceName: (UInt16) -> String?) -> Counters {
        var counters = Counters()
        bytes.withUnsafeBytes { rawBytes in
            guard let base = rawBytes.baseAddress else { return }
            let totalLength = rawBytes.count
            var offset = 0
            let messageLengthOffset = MemoryLayout<if_msghdr2>.offset(of: \.ifm_msglen) ?? 0
            let messageTypeOffset = MemoryLayout<if_msghdr2>.offset(of: \.ifm_type) ?? 3

            while offset < totalLength {
                let remaining = totalLength - offset
                guard messageLengthOffset + MemoryLayout<UInt16>.size <= remaining,
                      messageTypeOffset < remaining else { break }

                // memcpy avoids assuming that Data's base address or a following record is
                // aligned for UInt16/if_msghdr2 loads.
                var messageLength: UInt16 = 0
                memcpy(&messageLength, base.advanced(by: offset + messageLengthOffset), MemoryLayout<UInt16>.size)
                let length = Int(messageLength)
                guard length >= 4, length <= remaining else { break }

                let messageType = base.advanced(by: offset + messageTypeOffset).load(as: UInt8.self)
                if messageType == UInt8(RTM_IFINFO2) {
                    guard length >= MemoryLayout<if_msghdr2>.size else { break }
                    var header = if_msghdr2()
                    memcpy(&header, base.advanced(by: offset), MemoryLayout<if_msghdr2>.size)
                    if let name = interfaceName(header.ifm_index), name.hasPrefix("en") {
                        counters.rx[name] = header.ifm_data.ifi_ibytes
                        counters.tx[name] = header.ifm_data.ifi_obytes
                    }
                }
                offset += length
            }
        }
        return counters
    }

    /// Fetches a route dump, retrying when the interface list grows between the size query and
    /// the data query. Re-querying the required size on every attempt handles repeated growth.
    static func routeDump() -> Data? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        for _ in 0..<4 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size >= 0 else { return nil }
            if size == 0 { return Data() }

            var bytes = [UInt8](repeating: 0, count: size)
            var actualSize = size
            let result = bytes.withUnsafeMutableBytes { rawBytes -> Int32 in
                sysctl(&mib, u_int(mib.count), rawBytes.baseAddress, &actualSize, nil, 0)
            }
            if result == 0 { return Data(bytes.prefix(actualSize)) }
            guard errno == ENOMEM else { return nil }
        }
        return nil
    }
}

/// Read 64-bit byte totals for physical Ethernet/Wi-Fi interfaces, excluding loopback and VPNs.
func readCounters() -> Counters? {
    guard let dump = BandwidthCounterReader.routeDump() else { return nil }
    return BandwidthCounterReader.parseRouteDump(dump) { index in
        var nameBuffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        let result = nameBuffer.withUnsafeMutableBufferPointer { buffer in
            if_indextoname(UInt32(index), buffer.baseAddress)
        }
        guard result != nil else { return nil }
        return String(cString: nameBuffer)
    }
}

/// Bytes per second across counters present in each matching pair of snapshots. A reset only
/// omits the affected direction; RX and TX can still contribute independently.
func deltaRates(old: Counters, new: Counters, dt: TimeInterval) -> (down: Double, up: Double) {
    guard dt.isFinite, dt > 0 else { return (0, 0) }
    var receivedBytes = 0.0
    for (name, current) in new.rx {
        guard let previous = old.rx[name], current >= previous else { continue }
        receivedBytes += Double(current - previous)
    }
    var sentBytes = 0.0
    for (name, current) in new.tx {
        guard let previous = old.tx[name], current >= previous else { continue }
        sentBytes += Double(current - previous)
    }
    return (receivedBytes / dt, sentBytes / dt)
}

struct BandwidthRates: Equatable {
    var down = 0.0
    var up = 0.0
}

/// Elapsed time that is unaffected by wall-clock adjustments and includes system sleep.
enum BandwidthClock {
    private static let origin = ContinuousClock.now

    static func now() -> TimeInterval {
        let elapsed = origin.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }
}

/// One diagnostic measurement, using the actual interval between counter snapshots.
func measureBandwidth(interval: TimeInterval = BandwidthTracker.sampleInterval,
                      read: () -> Counters? = readCounters,
                      now: () -> TimeInterval = BandwidthClock.now,
                      sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) })
    -> (rates: BandwidthRates, seconds: TimeInterval) {
    let old = read(); let start = now()
    sleep(interval)
    let new = read(); let elapsed = now() - start
    let seconds = elapsed.isFinite && elapsed > 0 ? elapsed : 0
    guard let old, let new else { return (BandwidthRates(), seconds) }
    let rates = deltaRates(old: old, new: new, dt: seconds)
    return (BandwidthRates(down: rates.down, up: rates.up), seconds)
}

/// Duration-weighted mean and per-direction peaks of valid rate samples in a window.
struct BandwidthWindow {
    private(set) var sampleCount = 0
    private(set) var seconds: TimeInterval = 0
    private(set) var peak = BandwidthRates()
    private var downBytes = 0.0, upBytes = 0.0

    var average: BandwidthRates {
        guard seconds > 0 else { return BandwidthRates() }
        return BandwidthRates(down: downBytes / seconds, up: upBytes / seconds)
    }

    mutating func add(_ rates: BandwidthRates, seconds: TimeInterval) {
        guard seconds.isFinite, seconds > 0 else { return }
        downBytes += rates.down * seconds; upBytes += rates.up * seconds
        self.seconds += seconds; sampleCount += 1
        peak.down = max(peak.down, rates.down)
        peak.up = max(peak.up, rates.up)
    }
}

/// Owns live rates, five-second display averaging, connection peaks, and logging aggregates.
/// Callers supply snapshots and monotonic times so calculations can be tested without I/O.
struct BandwidthTracker {
    static let sampleInterval: TimeInterval = 1
    static let displayInterval: TimeInterval = 5
    static let maxSampleInterval: TimeInterval = 5

    enum Update: Equatable {
        case sampled
        case displayUpdated
        /// End of the completed interval, which the caller should log before resetting it.
        case gap(endedAt: TimeInterval)
        case unavailable
        case ignored
    }

    private(set) var current = BandwidthRates()
    private(set) var display = BandwidthRates()
    private(set) var peak = BandwidthRates()
    private(set) var window = BandwidthWindow()
    private var previous: Counters?
    private var previousAt: TimeInterval
    private var displayWindow = BandwidthWindow()
    private var displayedAt: TimeInterval

    init(counters: Counters? = nil, at: TimeInterval = BandwidthClock.now()) {
        previous = counters
        previousAt = at
        displayedAt = at
    }

    mutating func record(_ counters: Counters?, at: TimeInterval) -> Update {
        guard at.isFinite else { return .ignored }
        // A failed read is not zero traffic. Keep the last good baseline so the next
        // successful read includes bytes and elapsed time across this missed snapshot.
        guard let counters else {
            current = BandwidthRates(); display = BandwidthRates()
            return .unavailable
        }
        guard let old = previous else {
            previous = counters; previousAt = at; displayedAt = at
            return .sampled
        }
        let dt = at - previousAt
        let endedAt = previousAt
        previous = counters; previousAt = at
        // Rebase after sleep or an invalid interval. Preserve completed log samples until
        // the caller flushes them, but stop displaying a rate from before the gap.
        if !dt.isFinite || dt <= 0 || dt > Self.maxSampleInterval {
            current = BandwidthRates(); display = BandwidthRates()
            displayWindow = BandwidthWindow(); displayedAt = at
            return .gap(endedAt: endedAt)
        }

        let (down, up) = deltaRates(old: old, new: counters, dt: dt)
        func sanitize(_ rate: Double) -> Double {
            rate.isFinite && rate >= 0 && rate <= 1e13 ? rate : 0
        }
        current = BandwidthRates(down: sanitize(down), up: sanitize(up))
        peak.down = max(peak.down, current.down)
        peak.up = max(peak.up, current.up)
        window.add(current, seconds: dt)
        displayWindow.add(current, seconds: dt)

        if at - displayedAt >= Self.displayInterval {
            display = displayWindow.average
            displayWindow = BandwidthWindow(); displayedAt = at
            return .displayUpdated
        }
        return .sampled
    }

    mutating func resetWindow() {
        window = BandwidthWindow()
    }

    /// The caller flushes the old connection's log before clearing all measurement state.
    mutating func resetConnection(counters: Counters?, at: TimeInterval) {
        self = BandwidthTracker(counters: counters, at: at)
    }
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
