import Foundation
import Testing
@testable import NetMenu

@Suite struct AdaptiveSpeedTests {
    @Test func slowLinkUsesSmallChunksAndReportsFractionalMbps() {
        var clock = 0.0
        var largest = 0
        let result = SpeedTest.run(transfer: { _, size, _ in
            largest = max(largest, size)
            clock += Double(size) / 8192 // 64 Kbit/s: the old 4 MB test would take eight minutes.
        }, now: { clock })
        #expect(result.status == "ok")
        #expect(largest == 32_768)
        #expect(abs((result.download?.mbps ?? 0) - 0.065536) < 0.000001)
        #expect(result.download!.bytes < 250_000)
        #expect(result.title.contains("0.1↓ / 0.1↑"))
    }

    @Test func retriesTimeoutWithSmallerPayloadAndCountsFailedTime() {
        var clock = 0.0
        var sizes: [Int] = []
        let result = SpeedTest.run(transfer: { direction, size, _ in
            clock += 1
            if direction == .download {
                sizes.append(size)
                if sizes.count == 1 { throw URLError(.timedOut) }
            }
        }, now: { clock })
        #expect(Array(sizes.prefix(2)) == [32_768, 16_384])
        #expect(result.status == "ok")
        #expect(result.download?.seconds == Double(sizes.count))
        #expect(result.bytesReserved > (result.download!.bytes + result.upload!.bytes))
    }

    @Test func lostUploadPreservesDownloadAndLogsReason() {
        var clock = 0.0
        var uploads = 0
        let result = SpeedTest.run(transfer: { direction, _, _ in
            clock += 1
            if direction == .upload { uploads += 1; throw URLError(.networkConnectionLost) }
        }, now: { clock })
        #expect(uploads == 3)
        #expect(result.download != nil)
        #expect(result.upload == nil)
        #expect(result.status == "partial")
        #expect(result.errors["upload"] == "connection interrupted")
        #expect(result.title.contains("—↑"))
    }

    @Test func failedLaterChunkKeepsConservativePartialMeasurement() {
        var clock = 0.0
        var downloads = 0
        let result = SpeedTest.run(transfer: { direction, _, _ in
            clock += 2
            if direction == .download {
                downloads += 1
                if downloads > 1 { throw URLError(.timedOut) }
            }
        }, now: { clock })
        #expect(result.download?.bytes == 32_768)
        #expect(result.download?.seconds == 8)
        #expect(result.errors["download"] == "timed out")
        #expect(result.status == "partial")
    }

    @Test func eachPhaseHasHardDeadline() {
        var clock = 0.0
        var attempts = 0
        let result = SpeedTest.run(transfer: { _, _, timeout in
            attempts += 1; clock += timeout
            throw URLError(.timedOut)
        }, now: { clock })
        #expect(attempts == 6)
        #expect(clock == 2 * SpeedTest.phaseDeadline)
        #expect(result.status == "failed")
        #expect(result.title.contains("download: timed out"))
    }

    @Test func retriesStayWithinSharedBudget() {
        var clock = 0.0
        var reserved = 0, calls = 0
        let result = SpeedTest.run(transfer: { direction, size, _ in
            clock += 0.1; calls += 1
            reserved += size + (direction == .upload ? SpeedTest.responseLimit : 0)
            #expect(reserved <= SpeedTest.budgetBytes)
            if calls % 2 == 0 { throw URLError(.networkConnectionLost) }
        }, now: { clock })
        #expect(result.bytesReserved == reserved)
        #expect(result.errors.values.contains("data limit reached"))
    }

    @Test func networkChangeStopsFurtherTransfers() {
        var clock = 0.0, current = true
        var calls = 0
        let result = SpeedTest.run(transfer: { _, _, _ in
            calls += 1; clock += 1; current = false
        }, now: { clock }, isCurrentNetwork: { current })
        #expect(calls == 1)
        #expect(result.download == nil && result.upload == nil)
        #expect(result.errors.values.contains("network changed"))
    }

    @Test func permanentErrorsAreNotRetried() {
        var calls = 0
        let result = SpeedTest.run(transfer: { _, _, _ in
            calls += 1; throw SpeedTestError.httpStatus(403)
        })
        #expect(calls == 2)
        #expect(result.status == "failed")
        #expect(!SpeedTest.isRetryable(SpeedTestError.httpStatus(429)))
        #expect(!SpeedTest.isRetryable(URLError(.serverCertificateUntrusted)))
        #expect(SpeedTest.isRetryable(SpeedTestError.httpStatus(503)))
    }
}

private final class SpeedProtocol: URLProtocol {
    static var status = 200
    static var mime = "application/octet-stream"
    static var body = Data()
    static var stall = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if Self.stall { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": Self.mime])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct SpeedTransferTests {
    func transfer(direction: SpeedDirection = .download, size: Int = 32,
                  status: Int = 200, mime: String = "application/octet-stream", bodySize: Int = 32,
                  stall: Bool = false) throws {
        SpeedProtocol.status = status; SpeedProtocol.mime = mime
        SpeedProtocol.body = Data(count: bodySize); SpeedProtocol.stall = stall
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpeedProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        try SpeedTransfer(direction: direction, size: size).run(session: session, timeout: stall ? 0.05 : 2)
    }

    @Test func validDownloadAndEmptyUploadResponseSucceed() throws {
        try transfer()
        try transfer(direction: .upload, status: 200, mime: "text/plain", bodySize: 0)
    }

    @Test func rejectsPortalRedirectAndErrorResponses() {
        #expect(throws: (any Error).self) { try transfer(mime: "text/html") }
        #expect(throws: (any Error).self) { try transfer(status: 302) }
        #expect(throws: (any Error).self) { try transfer(status: 503) }
    }

    @Test func rejectsTruncatedAndOversizedBodies() {
        #expect(throws: (any Error).self) { try transfer(bodySize: 16) }
        #expect(throws: (any Error).self) { try transfer(bodySize: 64) }
        #expect(throws: (any Error).self) {
            try transfer(direction: .upload, bodySize: SpeedTest.responseLimit + 1)
        }
    }

    @Test func cancelsStalledTransferWithoutWaitingForSessionTimeout() {
        let start = ProcessInfo.processInfo.systemUptime
        #expect(throws: (any Error).self) { try transfer(stall: true) }
        #expect(ProcessInfo.processInfo.systemUptime - start < 1)
    }
}
