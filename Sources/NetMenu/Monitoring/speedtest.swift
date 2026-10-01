// Speed test against Cloudflare (speed.cloudflare.com), built to be accurate on links from
// satellite to gigabit within a hard data budget.
//
// Throughput is what all connections together moved per second once TCP has ramped up, not the
// sum of per-request times: those count every request's round trip as idle link time and badly
// under-read fast links. Per direction:
//   1. Four connections (a single TCP flow often cannot fill a fast or lossy path) fetch or post
//      requests that start at 64 KB and double until each takes ~0.75s at the measured rate
//      (longer on high-RTT links, so gaps between requests stay small).
//   2. A meter timestamps every byte. The first second (or 4 RTTs, at most 3s) is warmup and
//      excluded, but measurement always covers at least the last half of the bytes, so a fast
//      link that spends its budget during warmup is measured on its fastest part. Once the
//      budget is spent, the connections drain one by one; that tail is excluded too.
//   3. The phase stops as soon as the rate is stable (four overlapping 1s windows within 10%)
//      after at least 2s of steady state, or after 12s, or when its budget is spent. If the
//      budget ran out while throughput was still climbing (second half of the window >10%
//      faster than the first), the result is a lower bound and shown with ≥.
// Latency is measured idle before the test and under load during each phase (bufferbloat), on
// a separate connection, as the HTTP round trip minus Cloudflare's reported server time.
//
// Upload bytes count when the server confirms the whole request, not as they enter the send
// buffer: buffered megabytes would read about twice the real rate on a fast link. Upload
// requests aim for 0.4s so confirmations arrive often enough to measure.
//
// Every request reserves its full size from the budget before it starts and nothing is given
// back, so payload bytes never exceed the budget even if requests are cut short. HTTP and TLS
// overhead (~1–3%) is extra. The budget is 32 MB: download may use 20 MB and upload the rest
// (at least 12 MB). Only a really fast link (≥150 Mbps when a phase runs out) may grow it,
// once per phase, to 40 MB down and 64 MB in total, since 32 MB lasts under two seconds there.
// On Low Data Mode or metered networks the budget is 8 MB and never grows.

import Darwin
import Foundation

enum SpeedTestError: Error {
    case budgetExceeded, invalidResponse, networkChanged, cancelled, stalled
    case httpStatus(Int)
}

enum SpeedDirection: String {
    case download, upload
}

struct SpeedTestConfig {
    /// Normal total payload budget.
    var budgetBytes: Int
    /// Hard ceiling, reachable only on links at or above `fastLinkMbps`.
    var maxBudgetBytes: Int
    var fastLinkMbps = 150.0
    /// Download may use at most this share; upload gets everything download leaves.
    var maxDownloadShare = 0.625
    var initialStreams = 4
    var maxStreams = 4
    var parallelAboveMbps = 5.0
    var warmup: TimeInterval = 1
    var maxWarmup: TimeInterval = 3
    /// Of the phase budget; measurement never starts later than when this share has arrived.
    var latestWarmupShare = 0.5
    var minSteady: TimeInterval = 2
    var maxPhase: TimeInterval = 12
    /// No byte at all for this long ends the phase.
    var stallTimeout: TimeInterval = 8
    var stabilityTolerance = 0.10
    var requestTarget: TimeInterval = 0.75
    var uploadRequestTarget: TimeInterval = 0.4
    var maxRequestTarget: TimeInterval = 4
    var initialRequest = 65_536
    var minRequest = 16_384
    var maxRequest = 8_000_000
    var requestTimeout: TimeInterval = 15
    var latencyProbeInterval: TimeInterval = 0.4
    var idleLatencySamples = 5
    var latencyTimeout: TimeInterval = 3
    var tick: TimeInterval = 0.1

    static let standardBudget = 32_000_000
    static let fastLinkBudget = 64_000_000
    static let lowDataBudget = 8_000_000
    static let standard = SpeedTestConfig(budgetBytes: standardBudget, maxBudgetBytes: fastLinkBudget)
    static let lowData = SpeedTestConfig(budgetBytes: lowDataBudget, maxBudgetBytes: lowDataBudget)

    var downloadBudget: Int { Int(Double(budgetBytes) * maxDownloadShare) }
    var maxDownloadBudget: Int { Int(Double(maxBudgetBytes) * maxDownloadShare) }

    /// Upload gets what download left of the normal budget, but never less than its own share.
    func uploadBudget(downloadUsed: Int) -> Int {
        min(maxBudgetBytes - downloadUsed, max(budgetBytes - downloadBudget, budgetBytes - downloadUsed))
    }
}

/// Thread-safe stop switch shared with the UI.
final class SpeedTestControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// Reservations only: a request reserves its full size up front and is never refunded, so
/// the payload can never exceed `limit`, however requests end.
final class ByteBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var reserved = 0
    private var cap: Int

    init(limit: Int) { cap = max(0, limit) }

    var limit: Int { lock.lock(); defer { lock.unlock() }; return cap }
    var used: Int { lock.lock(); defer { lock.unlock() }; return reserved }

    /// Raise the limit; never lowers it.
    func extend(to newLimit: Int) {
        lock.lock(); cap = max(cap, newLimit); lock.unlock()
    }

    /// Up to `want` bytes, or 0 if fewer than `minimum` remain.
    func reserve(_ want: Int, minimum: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let grant = min(want, cap - reserved)
        guard grant >= minimum, grant > 0 else { return 0 }
        reserved += grant
        return grant
    }
}

/// Cumulative bytes over monotonic time, coalesced to 50ms points, with linear interpolation.
struct ThroughputMeter {
    static let resolution: TimeInterval = 0.05
    private(set) var total = 0
    private(set) var firstByteAt: TimeInterval?
    private(set) var lastByteAt: TimeInterval?
    /// (time, cumulative bytes by then), times increasing.
    private var points: [(t: TimeInterval, cum: Int)] = []

    mutating func add(_ bytes: Int, at t: TimeInterval) {
        guard bytes > 0, t.isFinite else { return }
        let at = max(t, lastByteAt ?? t)
        if firstByteAt == nil {
            firstByteAt = at
            points.append((at, 0))
        }
        total += bytes
        lastByteAt = at
        // Within `resolution` of the last point, fold into it (keeping its time) so the array
        // stays small: ~20 points per second however many chunks arrive.
        if points.count > 1, let last = points.last, at - last.t < Self.resolution {
            points[points.count - 1].cum = total
        } else {
            points.append((at, total))
        }
    }

    /// Bytes received by time `t`, interpolated between points.
    func cumulative(at t: TimeInterval) -> Double {
        guard let first = points.first else { return 0 }
        if t <= first.t { return 0 }
        guard let last = points.last, t < last.t else { return Double(points.last?.cum ?? 0) }
        var lo = 0, hi = points.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if points[mid].t <= t { lo = mid } else { hi = mid }
        }
        let a = points[lo], b = points[hi]
        let f = b.t > a.t ? (t - a.t) / (b.t - a.t) : 1
        return Double(a.cum) + f * Double(b.cum - a.cum)
    }

    /// When the cumulative count first reached `bytes`.
    func time(reaching bytes: Int) -> TimeInterval? {
        guard let i = points.firstIndex(where: { $0.cum >= bytes }) else { return nil }
        guard i > 0 else { return points[i].t }
        let a = points[i - 1], b = points[i]
        let f = b.cum > a.cum ? Double(bytes - a.cum) / Double(b.cum - a.cum) : 1
        return a.t + f * (b.t - a.t)
    }

    /// Bytes per second over [from, to].
    func rate(from: TimeInterval, to: TimeInterval) -> Double? {
        guard to > from else { return nil }
        let r = (cumulative(at: to) - cumulative(at: from)) / (to - from)
        return r.isFinite && r >= 0 ? r : nil
    }

    /// Four overlapping windows of `window` seconds, spanning the last 2 × `window` before `now`,
    /// all after `steadyFrom`, agree within `tolerance`.
    func isStable(now: TimeInterval, steadyFrom: TimeInterval, minSteady: TimeInterval, tolerance: Double,
                  window: TimeInterval = 1) -> Bool {
        guard now - steadyFrom >= max(minSteady, 2 * window) else { return false }
        let rates = [0.0, 1.0 / 3, 2.0 / 3, 1.0].compactMap { rate(from: now - ($0 + 1) * window, to: now - $0 * window) }
        guard rates.count == 4, let lo = rates.min(), let hi = rates.max(), lo > 0 else { return false }
        let mean = rates.reduce(0, +) / 4
        return (hi - lo) / mean <= tolerance
    }
}

/// Lets tests and other servers stand in for the network. Each transport is one connection.
protocol SpeedTransport: AnyObject {
    /// Blocks until done. Calls `onBytes` as payload moves. Throws on failure or after `cancel()`.
    func transfer(_ direction: SpeedDirection, size: Int, timeout: TimeInterval,
                  onBytes: @escaping (Int) -> Void) throws
    /// One small request's round trip in milliseconds, excluding server processing time.
    func probeLatency(timeout: TimeInterval) throws -> Double
    /// Aborts the current request and fails any later one; safe from any thread.
    func cancel()
    /// Releases the connection. The transport cannot be used afterwards.
    func close()
}

struct SpeedPhaseResult {
    var direction: SpeedDirection
    /// Payload bytes moved, including warmup.
    var bytes = 0
    var mbps: Double?
    /// Seconds of the measurement window.
    var seconds = 0.0
    var streams = 0
    var stable = false
    /// Budget ran out while the rate was still climbing: `mbps` is a lower bound.
    var budgetLimited = false
    var loadedLatencyMs: Double?
    var error: String?
    var elapsed = 0.0
}

struct SpeedTestResult {
    var download: SpeedPhaseResult?
    var upload: SpeedPhaseResult?
    var idleLatencyMs: Double?
    /// The budget that applied: the normal one, or more if a fast phase extended it.
    var budgetBytes = SpeedTestConfig.standardBudget
    var bytesReserved = 0
    var lowData = false
    var cancelled = false
    var networkChanged = false
    var elapsed = 0.0

    var errors: [String: String] {
        var e: [String: String] = [:]
        for p in [download, upload].compactMap({ $0 }) { if let err = p.error { e[p.direction.rawValue] = err } }
        if networkChanged { e["network"] = SpeedTest.reason(SpeedTestError.networkChanged) }
        return e
    }

    var status: String {
        if networkChanged { return "failed" }
        if download?.mbps == nil && upload?.mbps == nil { return cancelled ? "cancelled" : "failed" }
        return errors.isEmpty && download?.mbps != nil && upload?.mbps != nil ? "ok" : "partial"
    }

    var loadedLatencyMs: Double? {
        [download?.loadedLatencyMs, upload?.loadedLatencyMs].compactMap { $0 }.max()
    }

    var title: String {
        if networkChanged { return "Test stopped — network changed" }
        if status == "cancelled" { return "Speed test cancelled" }
        let reason = [download, upload].compactMap { $0 }.compactMap { p in
            p.error.map { "\(p.direction.rawValue): \($0)" }
        }.joined(separator: "; ")
        if status == "failed" { return "Test failed — \(reason.isEmpty ? "no data" : reason)" }
        let rates = "\(Self.rate(download))↓ / \(Self.rate(upload))↑ Mbps"
        var latency = ""
        if let idle = idleLatencyMs {
            latency = " · \(Int(idle.rounded()))ms"
            if let loaded = loadedLatencyMs { latency += ", \(Int(loaded.rounded()))ms loaded" }
        }
        return status == "ok" ? "Last test: \(rates)\(latency)" : "Partial test: \(rates) (\(reason))"
    }

    /// Full breakdown for the diagnostic log and `--speedtest`.
    var detail: String {
        func phase(_ p: SpeedPhaseResult?, _ name: String) -> String {
            guard let p else { return "\(name): not run" }
            var s = "\(name): \(Self.rate(p)) Mbps"
            if p.mbps != nil { s += " over \(p.streams) connection\(p.streams == 1 ? "" : "s")" }
            s += String(format: ", %.1f MB in %.0fs", Double(p.bytes) / 1e6, p.elapsed)
            if p.budgetLimited { s += " (still rising when the data limit was reached)" }
            if let l = p.loadedLatencyMs { s += ", latency \(Int(l.rounded()))ms under load" }
            if let e = p.error { s += " — \(e)" }
            return s
        }
        var lines = [phase(download, "Download"), phase(upload, "Upload")]
        if let idle = idleLatencyMs { lines.append("Idle latency: \(Int(idle.rounded()))ms") }
        lines.append(String(format: "Data used: up to %.1f of %.0f MB%@ · %@", Double(bytesReserved) / 1e6,
                            Double(budgetBytes) / 1e6, lowData ? " (Low Data Mode)" : "", Host.speedTest))
        return lines.joined(separator: "\n")
    }

    static func rate(_ p: SpeedPhaseResult?) -> String {
        guard let p, let mbps = p.mbps else { return "—" }
        let n = mbps < 10 ? String(format: "%.1f", mbps) : String(format: "%.0f", mbps)
        return p.budgetLimited ? "≥" + n : n
    }
}

enum SpeedProgress: Equatable {
    case latency
    case transfer(SpeedDirection, mbps: Double?)
}

enum SpeedTest {
    typealias Clock = () -> TimeInterval

    static func run(config: SpeedTestConfig, lowData: Bool = false,
                    makeTransport: @escaping () -> SpeedTransport,
                    control: SpeedTestControl = SpeedTestControl(),
                    isCurrentNetwork: () -> Bool = { true },
                    progress: (SpeedProgress) -> Void = { _ in },
                    now: @escaping Clock = BandwidthClock.now) -> SpeedTestResult {
        let started = now()
        var result = SpeedTestResult(budgetBytes: config.budgetBytes, lowData: lowData)
        let budget = ByteBudget(limit: config.maxBudgetBytes)
        var allowed = 0

        progress(.latency)
        result.idleLatencyMs = idleLatency(config: config, makeTransport: makeTransport, control: control,
                                           isCurrentNetwork: isCurrentNetwork)

        for direction in [SpeedDirection.download, .upload] {
            if control.isCancelled { result.cancelled = true; break }
            if !isCurrentNetwork() { result.networkChanged = true; break }
            let usedBefore = budget.used
            let cap = direction == .download ? config.downloadBudget : config.uploadBudget(downloadUsed: budget.used)
            let ceiling = direction == .download ? config.maxDownloadBudget : config.maxBudgetBytes - budget.used
            let phaseBudget = ByteBudget(limit: max(0, cap))
            progress(.transfer(direction, mbps: nil))
            let phase = runPhase(direction, config: config, budget: phaseBudget, extendTo: max(0, ceiling),
                                 idleRTTms: result.idleLatencyMs,
                                 makeTransport: makeTransport, control: control,
                                 isCurrentNetwork: isCurrentNetwork,
                                 progress: { progress(.transfer(direction, mbps: $0)) }, now: now)
            _ = budget.reserve(phaseBudget.used, minimum: 0)
            allowed = max(allowed, usedBefore + phaseBudget.limit)
            if direction == .download { result.download = phase } else { result.upload = phase }
            if control.isCancelled { result.cancelled = true; break }
            if phase.error == reason(SpeedTestError.networkChanged) { break }
        }
        // A result that straddled a network change describes neither network.
        if !isCurrentNetwork() { result.networkChanged = true }
        result.bytesReserved = budget.used
        result.budgetBytes = max(config.budgetBytes, budget.used, min(allowed, config.maxBudgetBytes))
        result.elapsed = now() - started
        return result
    }

    /// Median of a few small round trips on a warmed-up connection; nil if none succeed.
    static func idleLatency(config: SpeedTestConfig, makeTransport: () -> SpeedTransport,
                            control: SpeedTestControl, isCurrentNetwork: () -> Bool = { true }) -> Double? {
        let transport = makeTransport()
        defer { transport.close() }
        // The first request pays for DNS, TCP and TLS.
        _ = try? transport.probeLatency(timeout: config.latencyTimeout * 2)
        var samples: [Double] = []
        for _ in 0..<config.idleLatencySamples where !control.isCancelled && isCurrentNetwork() {
            if let ms = try? transport.probeLatency(timeout: config.latencyTimeout) { samples.append(ms) }
        }
        return median(samples)
    }

    /// `extendTo`: the phase budget may grow to this, once, if the link is at least `config.fastLinkMbps`.
    static func runPhase(_ direction: SpeedDirection, config: SpeedTestConfig, budget: ByteBudget,
                         extendTo: Int? = nil, idleRTTms: Double?, makeTransport: @escaping () -> SpeedTransport,
                         control: SpeedTestControl, isCurrentNetwork: () -> Bool,
                         progress: (Double?) -> Void, now: @escaping Clock = BandwidthClock.now) -> SpeedPhaseResult {
        final class State: @unchecked Sendable {
            let lock = NSLock()
            var meter = ThroughputMeter()
            var stop = false
            var running = 0
            var started = 0
            var lastError: Error?
            var budgetExhausted = false
            /// When the first stream found the budget spent: from here, connections drain.
            var exhaustedAt: TimeInterval?
            var transports: [SpeedTransport] = []
            var loaded: [(at: TimeInterval, ms: Double)] = []
            var extended = false
        }
        let st = State()
        let workers = DispatchGroup()
        let rtt = max(0, idleRTTms ?? 50) / 1000
        let baseTarget = direction == .upload ? config.uploadRequestTarget : config.requestTarget
        let requestTarget = min(config.maxRequestTarget, max(baseTarget, 6 * rtt))
        let warmup = min(config.maxWarmup, max(config.warmup, 4 * rtt))
        let began = now()
        var result = SpeedPhaseResult(direction: direction)

        func register(_ t: SpeedTransport) -> Bool {
            st.lock.lock(); defer { st.lock.unlock() }
            guard !st.stop else { return false }
            st.transports.append(t)
            return true
        }

        /// Called by a stream that found the budget spent: grow it once if this link is really fast.
        func tryExtend() -> Bool {
            st.lock.lock(); defer { st.lock.unlock() }
            guard !st.extended, let extendTo, extendTo > budget.limit, let first = st.meter.firstByteAt else { return false }
            let t = now()
            // A gigabit link spends 20 MB in ~0.16s, so decide on whatever has arrived (≥50ms).
            // Ramp-up only makes that rate an underestimate, never an overestimate.
            guard t - first >= 0.05, let rate = st.meter.rate(from: max(first, t - 0.5), to: t),
                  rate * 8 / 1e6 >= config.fastLinkMbps else { return false }
            st.extended = true
            budget.extend(to: extendTo)
            DiagLog.shared.info("speedtest", String(format: "%@ at %.0f Mbps: budget extended to %d MB",
                                                    direction.rawValue, rate * 8 / 1e6, extendTo / 1_000_000))
            return true
        }

        func startStream() {
            let transport = makeTransport()
            guard register(transport) else { transport.close(); return }
            st.lock.lock(); st.running += 1; st.started += 1; st.lock.unlock()
            workers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { st.lock.lock(); st.running -= 1; st.lock.unlock(); workers.leave() }
                var failures = 0
                var lastSize = 0
                while true {
                    st.lock.lock()
                    let stopping = st.stop
                    let t = now()
                    let rate = st.meter.firstByteAt.flatMap { first in
                        t - first >= 0.5 ? st.meter.rate(from: max(first, t - 1), to: t) : nil
                    }
                    let streams = max(1, st.running)
                    st.lock.unlock()
                    if stopping { return }
                    // Double each request until it would take `requestTarget` at the measured rate.
                    let grown = lastSize == 0 ? config.initialRequest : lastSize * 2
                    var want = rate.map { min(grown, Int(min(Double(config.maxRequest), $0 * requestTarget / Double(streams)))) }
                        ?? grown
                    want = min(config.maxRequest, max(config.minRequest, want))
                    var granted = budget.reserve(want, minimum: config.minRequest)
                    if granted == 0, tryExtend() { granted = budget.reserve(want, minimum: config.minRequest) }
                    guard granted > 0 else {
                        st.lock.lock()
                        st.budgetExhausted = true
                        if st.exhaustedAt == nil { st.exhaustedAt = now() }
                        st.lock.unlock()
                        return
                    }
                    lastSize = granted
                    do {
                        try autoreleasepool {
                            try transport.transfer(direction, size: granted, timeout: config.requestTimeout) { n in
                                st.lock.lock(); st.meter.add(n, at: now()); st.lock.unlock()
                            }
                        }
                        failures = 0
                    } catch {
                        st.lock.lock(); let stopping = st.stop; if !stopping { st.lastError = error }; st.lock.unlock()
                        if stopping { return }
                        failures += 1
                        DiagLog.shared.warn("speedtest", "\(direction.rawValue) request of \(granted)B failed: \(reason(error))")
                        if !isRetryable(error) || failures >= 3 { return }
                        Thread.sleep(forTimeInterval: 0.25 * Double(failures))
                    }
                }
            }
        }

        // Latency under load, on its own connection so it queues behind the link, not behind our requests.
        let latencyTransport = makeTransport()
        let latencyDone = DispatchGroup()
        if register(latencyTransport) {
            latencyDone.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { latencyDone.leave() }
                while true {
                    Thread.sleep(forTimeInterval: config.latencyProbeInterval)
                    st.lock.lock(); let stopping = st.stop; st.lock.unlock()
                    if stopping { return }
                    let at = now()
                    if let ms = try? latencyTransport.probeLatency(timeout: config.latencyTimeout) {
                        st.lock.lock(); st.loaded.append((at, ms)); st.lock.unlock()
                    }
                }
            }
        } else {
            latencyTransport.close()
        }

        for _ in 0..<max(1, min(config.initialStreams, config.maxStreams)) { startStream() }

        var steadyFrom: TimeInterval?
        var phaseError: Error?
        var parallel = config.initialStreams >= config.maxStreams
        while true {
            Thread.sleep(forTimeInterval: config.tick)
            let t = now()
            if control.isCancelled { phaseError = SpeedTestError.cancelled; break }
            if !isCurrentNetwork() { phaseError = SpeedTestError.networkChanged; break }
            st.lock.lock()
            let meter = st.meter, running = st.running, lastError = st.lastError
            let exhausted = st.budgetExhausted
            st.lock.unlock()

            guard let first = meter.firstByteAt else {
                if running == 0 { phaseError = lastError ?? SpeedTestError.stalled; break }
                if t - began >= config.stallTimeout { phaseError = SpeedTestError.stalled; break }
                continue
            }
            let byShare = meter.time(reaching: Int(Double(budget.limit) * config.latestWarmupShare))
            let from = min(first + warmup, byShare ?? .infinity)
            steadyFrom = from
            let liveRate = meter.rate(from: max(first, t - 1), to: t)
            progress(liveRate.map { $0 * 8 / 1e6 })

            if running == 0 {
                if !exhausted, let lastError { phaseError = lastError }
                break
            }
            if let last = meter.lastByteAt, t - last >= config.stallTimeout { phaseError = SpeedTestError.stalled; break }
            if !parallel, t - first >= 1, let r = liveRate, r * 8 / 1e6 > config.parallelAboveMbps {
                parallel = true
                st.lock.lock(); let have = st.started; st.lock.unlock()
                for _ in have..<config.maxStreams { startStream() }
            }
            if meter.isStable(now: t, steadyFrom: from, minSteady: config.minSteady, tolerance: config.stabilityTolerance) {
                result.stable = true
                break
            }
            if t - first >= config.maxPhase { break }
        }

        st.lock.lock(); st.stop = true; let transports = st.transports; st.lock.unlock()
        transports.forEach { $0.cancel() }
        if workers.wait(timeout: .now() + 3) == .timedOut {
            DiagLog.shared.warn("speedtest", "\(direction.rawValue) connections did not stop within 3s")
        }
        _ = latencyDone.wait(timeout: .now() + config.latencyTimeout + 1)
        transports.forEach { $0.close() }

        st.lock.lock()
        let meter = st.meter, exhausted = st.budgetExhausted, streams = st.started
        let loaded = st.loaded, exhaustedAt = st.exhaustedAt
        st.lock.unlock()

        result.bytes = meter.total
        result.streams = streams
        result.elapsed = now() - began
        if let first = meter.firstByteAt, let lastByte = meter.lastByteAt {
            // Exclude the drain after the budget ran out, unless that leaves too little.
            var end = lastByte
            if let drainFrom = exhaustedAt, drainFrom - first >= 0.3 { end = min(lastByte, drainFrom) }
            // Start after warmup, but no later than the point where half of the measured bytes
            // had arrived, so a phase that spent its budget during ramp-up is still measured on
            // its faster, later half.
            let byHalf = meter.time(reaching: Int(meter.cumulative(at: end) * config.latestWarmupShare))
            var start = min(first + warmup, byHalf ?? .infinity)
            if end - start < 0.05 { start = first }
            if end - start >= 0.05, let rate = meter.rate(from: start, to: end), rate > 0 {
                result.mbps = rate * 8 / 1e6
                result.seconds = end - start
            }
            // Out of budget before the rate settled: a lower bound only if it was still climbing.
            if exhausted, !result.stable, result.mbps != nil {
                let mid = (start + end) / 2
                if let early = meter.rate(from: start, to: mid), let late = meter.rate(from: mid, to: end) {
                    result.budgetLimited = late > early * (1 + config.stabilityTolerance)
                } else {
                    result.budgetLimited = true
                }
            }
        }
        let steadyLoaded = loaded.filter { $0.at >= (steadyFrom ?? 0) }.map(\.ms)
        result.loadedLatencyMs = median(steadyLoaded.isEmpty ? loaded.map(\.ms) : steadyLoaded)
        if let phaseError { result.error = reason(phaseError) }
        else if result.mbps == nil { result.error = reason(SpeedTestError.stalled) }
        return result
    }

    static func isRetryable(_ error: Error) -> Bool {
        if let error = error as? URLError {
            return [.timedOut, .networkConnectionLost, .cannotConnectToHost,
                    .cannotFindHost, .dnsLookupFailed].contains(error.code)
        }
        if case SpeedTestError.httpStatus(let status) = error { return [500, 502, 503, 504].contains(status) }
        return false
    }

    static func reason(_ error: Error) -> String {
        switch error {
        case SpeedTestError.budgetExceeded: return "data limit reached"
        case SpeedTestError.invalidResponse: return "unexpected server response"
        case SpeedTestError.networkChanged: return "network changed"
        case SpeedTestError.cancelled: return "cancelled"
        case SpeedTestError.stalled: return "no data received"
        case SpeedTestError.httpStatus(let status): return "server HTTP \(status)"
        case let error as URLError:
            switch error.code {
            case .timedOut: return "timed out"
            case .networkConnectionLost: return "connection interrupted"
            case .notConnectedToInternet: return "offline"
            case .cannotFindHost, .dnsLookupFailed: return "DNS lookup failed"
            case .cannotConnectToHost: return "server unreachable"
            case .secureConnectionFailed, .serverCertificateUntrusted: return "secure connection failed"
            case .cancelled: return "cancelled"
            default: return "network error \(error.code.rawValue)"
            }
        default: return error.localizedDescription
        }
    }
}
