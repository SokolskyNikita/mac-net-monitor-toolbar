import Foundation
import Testing
@testable import NetMenu

// MARK: - Simulated link

/// A FIFO bottleneck on an absolute schedule (so sleep overshoot cannot accumulate): each chunk
/// occupies the link for size / rate seconds after the previous one. Each request waits one RTT
/// before its first byte, and uploads are credited on completion like the real transport.
private final class SimLink: @unchecked Sendable {
    let lock = NSLock()
    var bytesPerSecond: Double
    var rtt: TimeInterval
    var nextFree = BandwidthClock.now()
    var failWith: Error?
    var stallAfterBytes: Int?
    var moved = 0
    /// Ground truth: when each chunk finished crossing the link.
    var delivered: [(t: TimeInterval, bytes: Int)] = []
    var latencyMs: Double

    /// What the link really carried over the last half of its bytes, in Mbps.
    func trueRateOfLastHalf() -> Double {
        lock.lock(); defer { lock.unlock() }
        let total = delivered.reduce(0) { $0 + $1.bytes }
        var cum = 0, start: TimeInterval?
        for d in delivered { cum += d.bytes; if start == nil, cum >= total / 2 { start = d.t } }
        guard let start, let end = delivered.last?.t, end > start else { return 0 }
        let bytes = delivered.filter { $0.t > start }.reduce(0) { $0 + $1.bytes }
        return Double(bytes) * 8 / (end - start) / 1e6
    }
    init(mbps: Double, rtt: TimeInterval = 0.01, latencyMs: Double = 12) {
        bytesPerSecond = mbps * 1e6 / 8; self.rtt = rtt; self.latencyMs = latencyMs
    }
}

private final class SimTransport: SpeedTransport, @unchecked Sendable {
    let link: SimLink
    private let lock = NSLock()
    private var cancelled = false
    init(_ link: SimLink) { self.link = link }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func transfer(_ direction: SpeedDirection, size: Int, timeout: TimeInterval, onBytes: @escaping (Int) -> Void) throws {
        if let e = link.lock.withLock({ link.failWith }) { throw e }
        Thread.sleep(forTimeInterval: link.rtt)
        let deadline = Date().addingTimeInterval(timeout)
        var sent = 0
        let chunk = 65_536
        while sent < size {
            if isCancelled { throw SpeedTestError.cancelled }
            if Date() > deadline { throw URLError(.timedOut) }
            let n = min(chunk, size - sent)
            let (doneAt, stalled) = link.lock.withLock { () -> (TimeInterval, Bool) in
                if link.stallAfterBytes.map({ link.moved >= $0 }) == true { return (0, true) }
                let start = max(BandwidthClock.now(), link.nextFree)
                link.nextFree = start + Double(n) / link.bytesPerSecond
                return (link.nextFree, false)
            }
            if stalled { Thread.sleep(forTimeInterval: 0.01); continue }
            let wait = doneAt - BandwidthClock.now()
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            sent += n
            link.lock.withLock { link.moved += n; link.delivered.append((BandwidthClock.now(), n)) }
            if direction == .download { onBytes(n) }
        }
        if direction == .upload { onBytes(size) }
    }

    func probeLatency(timeout: TimeInterval) throws -> Double {
        if isCancelled { throw SpeedTestError.cancelled }
        let ms = link.lock.withLock { link.latencyMs }
        Thread.sleep(forTimeInterval: ms / 1000)
        return ms
    }

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func close() { cancel() }
}

/// Real-time phases are slow; shrink every duration while keeping the shape of the algorithm.
private func fastConfig(budget: Int = 4_000_000, maxBudget: Int? = nil) -> SpeedTestConfig {
    var c = SpeedTestConfig(budgetBytes: budget, maxBudgetBytes: maxBudget ?? budget)
    c.warmup = 0.2; c.maxWarmup = 0.4; c.minSteady = 0.4; c.maxPhase = 2.5; c.stallTimeout = 0.8
    c.requestTarget = 0.15; c.uploadRequestTarget = 0.1; c.maxRequestTarget = 0.5
    c.initialRequest = 16_384; c.minRequest = 4096; c.maxRequest = 1_000_000
    c.latencyProbeInterval = 0.1; c.idleLatencySamples = 3; c.latencyTimeout = 1; c.tick = 0.02
    c.requestTimeout = 3; c.fastLinkMbps = 150
    return c
}

// MARK: - Pure parts

@Suite struct ThroughputMeterTests {
    @Test func interpolatesCumulativeBytesAndRates() {
        var m = ThroughputMeter()
        for i in 0...100 { m.add(1000, at: Double(i) * 0.01) }  // 100 KB/s for 1s
        #expect(m.total == 101_000)
        let r = m.rate(from: 0.2, to: 0.8)!
        #expect(abs(r - 100_000) / 100_000 < 0.1)
        #expect(abs(m.time(reaching: 51_000)! - 0.5) < 0.06)
    }

    @Test func coalescesSoMemoryStaysBounded() {
        var m = ThroughputMeter()
        for i in 0..<100_000 { m.add(10, at: Double(i) * 0.0001) }  // 10s of tiny chunks
        #expect(m.total == 1_000_000)
        let r = m.rate(from: 2, to: 8)!
        #expect(abs(r - 100_000) / 100_000 < 0.05)
    }

    @Test func stabilityNeedsSteadyRateAfterWarmup() {
        var steady = ThroughputMeter(), ramping = ThroughputMeter()
        var cum = 0.0
        for i in 0...400 {
            let t = Double(i) * 0.01
            steady.add(1000, at: t)
            let next = 500 * t * t * 100  // accelerating
            ramping.add(Int(next - cum) + 1, at: t); cum = next
        }
        #expect(steady.isStable(now: 4, steadyFrom: 1, minSteady: 2, tolerance: 0.1))
        #expect(!steady.isStable(now: 2, steadyFrom: 1, minSteady: 2, tolerance: 0.1))
        #expect(!ramping.isStable(now: 4, steadyFrom: 1, minSteady: 2, tolerance: 0.1))
    }

    @Test func budgetNeverOvercommitsUnderConcurrency() {
        let b = ByteBudget(limit: 1_000_000)
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            while b.reserve(7_000, minimum: 1_000) > 0 {}
        }
        #expect(b.used <= 1_000_000)
        #expect(b.used > 990_000)
        b.extend(to: 500)
        #expect(b.limit == 1_000_000)
    }

    @Test func uploadKeepsItsShareAndTotalStaysUnderCeiling() {
        let c = SpeedTestConfig.standard
        #expect(c.downloadBudget == 20_000_000)
        #expect(c.uploadBudget(downloadUsed: 20_000_000) == 12_000_000)
        #expect(c.uploadBudget(downloadUsed: 5_000_000) == 27_000_000)
        #expect(c.uploadBudget(downloadUsed: 40_000_000) == 12_000_000)
        #expect(c.maxDownloadBudget == 40_000_000)
        #expect(SpeedTestConfig.lowData.maxBudgetBytes == SpeedTestConfig.lowData.budgetBytes)
    }
}

@Suite struct SpeedResultFormattingTests {
    func phase(_ d: SpeedDirection, _ mbps: Double?, lower: Bool = false, error: String? = nil) -> SpeedPhaseResult {
        var p = SpeedPhaseResult(direction: d); p.mbps = mbps; p.budgetLimited = lower; p.error = error
        p.streams = 4; p.bytes = 1_000_000
        return p
    }

    @Test func titles() {
        var r = SpeedTestResult(download: phase(.download, 268.4), upload: phase(.upload, 4.26), idleLatencyMs: 9.4)
        r.download?.loadedLatencyMs = 41; r.upload?.loadedLatencyMs = 30
        #expect(r.status == "ok")
        #expect(r.title == "Last test: 268↓ / 4.3↑ Mbps · 9ms, 41ms loaded")
        r.download = phase(.download, 480, lower: true)
        #expect(r.title.hasPrefix("Last test: ≥480↓"))
        r.upload = phase(.upload, nil, error: "timed out")
        #expect(r.status == "partial")
        #expect(r.title == "Partial test: ≥480↓ / —↑ Mbps (upload: timed out)")
        let failed = SpeedTestResult(download: phase(.download, nil, error: "offline"))
        #expect(failed.title == "Test failed — download: offline")
        var cancelled = SpeedTestResult(); cancelled.cancelled = true
        #expect(cancelled.title == "Speed test cancelled")
    }
}

// MARK: - Engine against a simulated link

@Suite(.serialized) struct SpeedEngineTests {
    @Test func measuresSteadyLinkAccuratelyAndStopsEarly() {
        let link = SimLink(mbps: 40)
        let r = SpeedTest.run(config: fastConfig(budget: 40_000_000), makeTransport: { SimTransport(link) })
        let down = try! #require(r.download?.mbps), up = try! #require(r.upload?.mbps)
        #expect(abs(down - 40) / 40 < 0.15, "download \(down)")
        #expect(abs(up - 40) / 40 < 0.2, "upload \(up)")
        #expect(r.download?.stable == true)
        #expect(r.download?.budgetLimited == false)
        #expect(r.idleLatencyMs == 12)
        // Stopped on stability long before spending the budget.
        #expect(r.bytesReserved < 40_000_000)
        #expect(r.status == "ok")
    }

    @Test func slowHighLatencyLinkIsMeasuredWithinTheDeadline() {
        let link = SimLink(mbps: 2, rtt: 0.08, latencyMs: 600)
        let t0 = Date()
        let r = SpeedTest.run(config: fastConfig(), makeTransport: { SimTransport(link) })
        let down = try! #require(r.download?.mbps)
        #expect(abs(down - 2) / 2 < 0.25, "download \(down)")
        #expect(Date().timeIntervalSince(t0) < 12)
    }

    @Test func payloadNeverExceedsBudget() {
        let link = SimLink(mbps: 400)
        let c = fastConfig(budget: 3_000_000)
        let r = SpeedTest.run(config: c, makeTransport: { SimTransport(link) })
        #expect(r.bytesReserved <= c.maxBudgetBytes)
        #expect(link.moved <= c.maxBudgetBytes)
        #expect(r.download?.mbps != nil)
    }

    @Test func onlyFastLinksMayExtendTheBudget() {
        let fast = SimLink(mbps: 250)
        let c = fastConfig(budget: 6_000_000, maxBudget: 12_000_000)
        let r = SpeedTest.run(config: c, makeTransport: { SimTransport(fast) })
        #expect(r.bytesReserved > c.budgetBytes)
        #expect(r.bytesReserved <= c.maxBudgetBytes)
        #expect(fast.moved <= c.maxBudgetBytes)

        let modest = SimLink(mbps: 60)
        var slow = c; slow.maxPhase = 6; slow.minSteady = 5  // force it to run out of budget
        let m = SpeedTest.run(config: slow, makeTransport: { SimTransport(modest) })
        #expect(m.bytesReserved <= c.budgetBytes)
        #expect(m.budgetBytes == c.budgetBytes)
    }

    @Test func cancelStopsPromptly() {
        let link = SimLink(mbps: 5)
        let control = SpeedTestControl()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { control.cancel() }
        let t0 = Date()
        var c = fastConfig(budget: 40_000_000); c.maxPhase = 30; c.minSteady = 30
        let r = SpeedTest.run(config: c, makeTransport: { SimTransport(link) }, control: control)
        #expect(Date().timeIntervalSince(t0) < 2.5)
        #expect(r.cancelled)
        #expect(r.upload == nil)
    }

    @Test func networkChangeStopsAndSkipsUpload() {
        let link = SimLink(mbps: 5)
        let start = Date()
        let r = SpeedTest.run(config: fastConfig(budget: 40_000_000), makeTransport: { SimTransport(link) },
                              isCurrentNetwork: { Date().timeIntervalSince(start) < 0.6 })
        #expect(r.download?.error == "network changed")
        #expect(r.upload == nil)
        #expect(r.networkChanged)
        #expect(r.status == "failed")
        #expect(r.title == "Test stopped — network changed")
    }

    @Test func networkChangeAfterTheLastPhaseStillInvalidatesTheResult() {
        let link = SimLink(mbps: 40)
        // Flip once upload is under way; the final check after both phases must catch it.
        var phasesDone = false
        let flipped = SpeedTest.run(config: fastConfig(budget: 2_000_000), makeTransport: { SimTransport(link) },
                                    isCurrentNetwork: { !phasesDone },
                                    progress: { if case .transfer(.upload, let mbps) = $0, mbps != nil { phasesDone = true } })
        #expect(flipped.networkChanged)
        #expect(flipped.status == "failed")
    }

    @Test func fastLinkIsMeasuredOnItsSteadyPartNotItsRamp() {
        // A budget that runs out during ramp-up: the result must match what the link actually
        // carried at its end, not be dragged down by the start.
        let link = SimLink(mbps: 400)
        var c = fastConfig(budget: 20_000_000); c.maxDownloadShare = 1
        let phase = SpeedTest.runPhase(.download, config: c, budget: ByteBudget(limit: c.budgetBytes), idleRTTms: 10,
                                       makeTransport: { SimTransport(link) }, control: SpeedTestControl(),
                                       isCurrentNetwork: { true }, progress: { _ in })
        let down = try! #require(phase.mbps)
        let truth = link.trueRateOfLastHalf()
        #expect(abs(down - truth) / truth < 0.1, "measured \(down), link carried \(truth)")
        #expect(!phase.budgetLimited, "a flat link must not be reported as a lower bound")
    }

    @Test func reportedBudgetIsTheOneThatApplied() {
        let link = SimLink(mbps: 8)
        var c = fastConfig(budget: 2_000_000, maxBudget: 4_000_000); c.maxPhase = 0.6
        let r = SpeedTest.run(config: c, makeTransport: { SimTransport(link) })
        #expect(r.budgetBytes == c.budgetBytes)
    }

    @Test func stalledLinkFailsWithReason() {
        let link = SimLink(mbps: 5)
        link.stallAfterBytes = 0
        let r = SpeedTest.run(config: fastConfig(), makeTransport: { SimTransport(link) })
        #expect(r.download?.error == "no data received")
        #expect(r.status == "failed")
    }

    @Test func permanentServerErrorIsReportedNotRetriedForever() {
        let link = SimLink(mbps: 5)
        link.failWith = SpeedTestError.httpStatus(403)
        let t0 = Date()
        let r = SpeedTest.run(config: fastConfig(), makeTransport: { SimTransport(link) })
        #expect(r.download?.error == "server HTTP 403")
        #expect(r.title.hasPrefix("Test failed"))
        #expect(Date().timeIntervalSince(t0) < 3)
        #expect(!SpeedTest.isRetryable(SpeedTestError.httpStatus(403)))
        #expect(SpeedTest.isRetryable(SpeedTestError.httpStatus(503)))
        #expect(SpeedTest.isRetryable(URLError(.timedOut)))
    }

    @Test func loadedLatencyIsMeasuredDuringTransfer() {
        let link = SimLink(mbps: 20)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { link.lock.withLock { link.latencyMs = 80 } }
        let r = SpeedTest.run(config: fastConfig(budget: 40_000_000), makeTransport: { SimTransport(link) })
        #expect(r.idleLatencyMs == 12)
        #expect(r.download?.loadedLatencyMs == 80)
    }
}

// MARK: - URLSession transport

private final class SpeedProtocol: URLProtocol {
    static let lock = NSLock()
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var mime = "application/octet-stream"
    nonisolated(unsafe) static var bodySize: Int?
    nonisolated(unsafe) static var stall = false
    nonisolated(unsafe) static var headers: [String: String] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let stall = Self.stall, status = Self.status, mime = Self.mime, fixed = Self.bodySize, extra = Self.headers
        Self.lock.unlock()
        if stall { return }
        let requested = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "bytes" })?.value.flatMap(Int.init) ?? 0
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": mime].merging(extra) { $1 })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(count: fixed ?? requested))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct SpeedTransportTests {
    func transport(status: Int = 200, mime: String = "application/octet-stream", bodySize: Int? = nil,
                   stall: Bool = false, headers: [String: String] = [:]) -> URLSessionSpeedTransport {
        SpeedProtocol.lock.lock()
        SpeedProtocol.status = status; SpeedProtocol.mime = mime; SpeedProtocol.bodySize = bodySize
        SpeedProtocol.stall = stall; SpeedProtocol.headers = headers
        SpeedProtocol.lock.unlock()
        return URLSessionSpeedTransport { $0.protocolClasses = [SpeedProtocol.self] }
    }

    @Test func downloadCountsEveryByteAndUploadCreditsOnCompletion() throws {
        let t = transport(); defer { t.close() }
        var down = 0
        try t.transfer(.download, size: 50_000, timeout: 2) { down += $0 }
        #expect(down == 50_000)
        let u = transport(mime: "text/plain", bodySize: 0); defer { u.close() }
        var up: [Int] = []
        try u.transfer(.upload, size: 30_000, timeout: 2) { up.append($0) }
        #expect(up == [30_000])
    }

    @Test func rejectsPortalRedirectErrorAndWrongSizes() {
        let cases: [URLSessionSpeedTransport] = [
            transport(mime: "text/html"), transport(status: 302), transport(status: 503),
            transport(bodySize: 16), transport(bodySize: 64)
        ]
        for t in cases {
            #expect(throws: (any Error).self) { try t.transfer(.download, size: 32, timeout: 2) { _ in } }
            t.close()
        }
        let big = transport(mime: "text/plain", bodySize: URLSessionSpeedTransport.responseLimit + 1)
        #expect(throws: (any Error).self) { try big.transfer(.upload, size: 32, timeout: 2) { _ in } }
        big.close()
    }

    @Test func stalledTransferTimesOutAndCancelIsPrompt() {
        let t = transport(stall: true); defer { t.close() }
        let t0 = Date()
        #expect(throws: (any Error).self) { try t.transfer(.download, size: 32, timeout: 0.1) { _ in } }
        #expect(Date().timeIntervalSince(t0) < 1.5)

        let c = transport(stall: true); defer { c.close() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { c.cancel() }
        let t1 = Date()
        #expect(throws: (any Error).self) { try c.transfer(.download, size: 32, timeout: 10) { _ in } }
        #expect(Date().timeIntervalSince(t1) < 1.5)
    }

    @Test func latencyProbeSubtractsServerTime() throws {
        #expect(URLSessionSpeedTransport.serverTimingMs("cfSpeedEdge;dur=3, cfSpeedWorker;dur=21") == 21)
        #expect(URLSessionSpeedTransport.serverTimingMs("cfRequestDuration;dur=4.5, cfSpeedWorker;dur=21") == 4.5)
        #expect(URLSessionSpeedTransport.serverTimingMs("cfL4;desc=\"rtt=1\"") == nil)
        #expect(URLSessionSpeedTransport.serverTimingMs(nil) == nil)
        let t = transport(headers: ["Server-Timing": "cfSpeedWorker;dur=100000"]); defer { t.close() }
        #expect(try t.probeLatency(timeout: 2) == 0)
    }

    @Test func randomUploadBodyIsNotCompressible() {
        let d = URLSessionSpeedTransport.randomData(4096)
        #expect(d.count == 4096)
        #expect(Set(d).count > 200)
    }
}
