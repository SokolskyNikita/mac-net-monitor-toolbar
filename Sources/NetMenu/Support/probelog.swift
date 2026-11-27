// Probe results for the diagnostic log. A healthy network produces the same few lines several
// times a second, which filled the 30 MB log in a day or two. Every result is counted into one
// summary a minute. A result that repeats the previous state of its kind is otherwise not
// written; one whose state differs is written in full at once, preceded by the individual
// results of the last moments and followed by every result for a while, so the detail around
// an event is kept.

import Foundation

final class ProbeLog: @unchecked Sendable {
    static let shared = ProbeLog()

    typealias Sink = (_ category: String, _ message: String, _ date: Date) -> Void
    /// Marks lines written after the fact, whose timestamps precede lines above them.
    static let recalledMark = " (recalled)"
    private static let maxRecent = 256
    private static let maxValues = 512

    private struct Tally {
        var count = 0
        var values: [Double] = []
        var detail: String?
    }
    private struct Line {
        var at: TimeInterval
        var date: Date
        var category: String
        var message: String
    }

    private let lock = NSLock()
    private let sink: Sink
    private let interval: TimeInterval
    private let detailWindow: TimeInterval
    // Intervals are measured on a clock that cannot be set; `Date` is only what gets written.
    private var windowStart: TimeInterval?
    /// Counts for this window, by kind and state ("1.1.1.1 reply"), in order of first use.
    private var tallies: [String: Tally] = [:]
    private var keys: [String] = []
    private var states: [String: String] = [:]
    private var recent: [Line] = []
    private var detailUntil = -TimeInterval.infinity

    init(config: LoggingConfig = Configuration.logging,
         sink: @escaping Sink = { DiagLog.shared.log(.info, $0, $1, at: $2) }) {
        interval = config.probeSummaryInterval
        detailWindow = config.probeDetailWindow
        self.sink = sink
    }

    /// One probe result. `state` is what makes it worth a line of its own when it changes (a
    /// verdict, a health band); `ms` and `detail` vary freely and appear in the summary.
    func record(_ category: String, key: String, state: String, ms: Double? = nil, detail: String? = nil,
                at date: Date = Date(), now: TimeInterval = BandwidthClock.now(), _ message: @autoclosure () -> String) {
        lock.lock(); defer { lock.unlock() }
        summarizeIfDue(at: date, now: now)
        let changed = states[key] != state
        states[key] = state
        let tally = key + " " + state
        if tallies[tally] == nil { tallies[tally] = Tally(); keys.append(tally) }
        tallies[tally]?.count += 1
        if let ms, tallies[tally]?.values.count ?? 0 < Self.maxValues { tallies[tally]?.values.append(ms) }
        tallies[tally]?.detail = detail
        if changed {
            event(category, message(), at: date, now: now)
        } else if now < detailUntil {
            sink(category, message(), date)
        } else {
            recent.append(Line(at: now, date: date, category: category, message: message()))
            let oldest = now - detailWindow
            if recent.count > Self.maxRecent || recent.first.map({ $0.at < oldest }) == true {
                recent.removeAll { $0.at < oldest }
                if recent.count > Self.maxRecent { recent.removeFirst(recent.count - Self.maxRecent) }
            }
        }
    }

    /// A result that always gets its own line, such as the HTTPS fallback.
    func notable(_ category: String, at date: Date = Date(), now: TimeInterval = BandwidthClock.now(), _ message: String) {
        lock.lock(); defer { lock.unlock() }
        summarizeIfDue(at: date, now: now)
        event(category, message, at: date, now: now)
    }

    /// Writes the summary collected so far, e.g. before the app quits.
    func flush(at date: Date = Date(), now: TimeInterval = BandwidthClock.now()) {
        lock.lock(); defer { lock.unlock() }
        summarize(at: date, now: now)
    }

    private func event(_ category: String, _ message: String, at date: Date, now: TimeInterval) {
        let oldest = now - detailWindow
        for line in recent where line.at >= oldest {
            sink(line.category, line.message + Self.recalledMark, line.date)
        }
        recent.removeAll(keepingCapacity: true)
        sink(category, message, date)
        detailUntil = now + detailWindow
    }

    private func summarizeIfDue(at date: Date, now: TimeInterval) {
        guard let start = windowStart else { windowStart = now; return }
        if now - start >= interval { summarize(at: date, now: now) }
    }

    private func summarize(at date: Date, now: TimeInterval) {
        defer { windowStart = now; tallies.removeAll(keepingCapacity: true); keys.removeAll(keepingCapacity: true) }
        guard let start = windowStart, !keys.isEmpty else { return }
        let parts = keys.compactMap { key -> String? in
            guard let tally = tallies[key] else { return nil }
            var part = "\(key) ×\(tally.count)"
            let values = tally.values.sorted()
            if let low = values.first, let high = values.last {
                part += String(format: " %.1f/%.1f/%.1fms", low, values[values.count / 2], high)
            }
            if let detail = tally.detail { part += " (\(detail))" }
            return part
        }
        sink("probe", String(format: "summary %.0fs: ", now - start) + parts.joined(separator: "; "), date)
    }
}
