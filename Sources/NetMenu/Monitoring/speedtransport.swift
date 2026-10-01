// One connection to Cloudflare's speed test endpoints. Each transport owns its URLSession, so
// parallel transports are separate TCP/QUIC connections even where HTTP/2 would multiplex.

import Darwin
import Foundation

final class URLSessionSpeedTransport: NSObject, SpeedTransport, URLSessionDataDelegate, @unchecked Sendable {
    /// Upload responses are tiny; anything larger is not the speed test server.
    static let responseLimit = 16_384
    static let latencyPath = "/__down?bytes=0"

    private var session: URLSession!
    private let lock = NSLock()
    private var pending: Pending?
    private var cancelled = false

    private final class Pending {
        let task: URLSessionTask
        let direction: SpeedDirection
        let size: Int
        let onBytes: (Int) -> Void
        let done = DispatchSemaphore(value: 0)
        var received = 0
        var failure: Error?
        var finished = false
        var metrics: URLSessionTaskMetrics?
        var serverMs: Double?
        init(task: URLSessionTask, direction: SpeedDirection, size: Int, onBytes: @escaping (Int) -> Void) {
            self.task = task; self.direction = direction; self.size = size; self.onBytes = onBytes
        }
    }

    /// `configure` lets tests install a URLProtocol.
    init(configure: ((URLSessionConfiguration) -> Void)? = nil) {
        super.init()
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 60
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.httpShouldSetCookies = false
        c.httpCookieStorage = nil
        c.httpMaximumConnectionsPerHost = 1
        configure?(c)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "netmenu.speed.delegate"
        session = URLSession(configuration: c, delegate: self, delegateQueue: queue)
    }

    // MARK: - SpeedTransport

    func transfer(_ direction: SpeedDirection, size: Int, timeout: TimeInterval,
                  onBytes: @escaping (Int) -> Void) throws {
        let path = direction == .download
            ? "\(URLPart.speedDownPath)?\(URLPart.bytesQuery)\(size)&n=\(UUID().uuidString)"
            : "\(URLPart.speedUpPath)?n=\(UUID().uuidString)"
        var request = try makeRequest(path, timeout: timeout)
        let task: URLSessionTask
        if direction == .upload {
            request.httpMethod = HTTPMethod.post
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            // Random bytes: a compressing middlebox cannot inflate the result.
            task = session.uploadTask(with: request, from: Self.randomData(size))
        } else {
            task = session.dataTask(with: request)
        }
        let p = try run(task, direction: direction, size: size, timeout: timeout, onBytes: onBytes)
        if let failure = p.failure { throw failure }
        if direction == .download && p.received != size { throw SpeedTestError.invalidResponse }
    }

    func probeLatency(timeout: TimeInterval) throws -> Double {
        let request = try makeRequest(Self.latencyPath + "&n=\(UUID().uuidString)", timeout: timeout)
        let t0 = BandwidthClock.now()
        let p = try run(session.dataTask(with: request), direction: .download, size: 0, timeout: timeout, onBytes: { _ in })
        if let failure = p.failure { throw failure }
        // Request sent → first response byte, on the already-open connection. Falls back to wall time.
        var ms = (BandwidthClock.now() - t0) * 1000
        if let tx = p.metrics?.transactionMetrics.last, let sent = tx.requestStartDate, let first = tx.responseStartDate {
            ms = first.timeIntervalSince(sent) * 1000
        }
        if let server = p.serverMs { ms -= server }
        guard ms.isFinite else { throw SpeedTestError.invalidResponse }
        return max(0, ms)
    }

    func cancel() {
        lock.lock(); cancelled = true; let task = pending?.task; lock.unlock()
        task?.cancel()
    }

    func close() {
        cancel()
        // Also breaks the session → delegate retain cycle.
        session.invalidateAndCancel()
    }

    // MARK: - Plumbing

    private func makeRequest(_ path: String, timeout: TimeInterval) throws -> URLRequest {
        guard let url = URL(string: URLPart.httpsScheme + Host.speedTest + path) else { throw URLError(.badURL) }
        var r = URLRequest(url: url)
        r.timeoutInterval = timeout
        r.cachePolicy = .reloadIgnoringLocalCacheData
        r.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        r.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return r
    }

    private func run(_ task: URLSessionTask, direction: SpeedDirection, size: Int, timeout: TimeInterval,
                     onBytes: @escaping (Int) -> Void) throws -> Pending {
        let p = Pending(task: task, direction: direction, size: size, onBytes: onBytes)
        lock.lock()
        if cancelled { lock.unlock(); throw SpeedTestError.cancelled }
        pending = p
        lock.unlock()
        defer { lock.lock(); if pending === p { pending = nil }; lock.unlock() }
        task.resume()
        if p.done.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            // Wait for the final callback so no byte is counted after we return.
            _ = p.done.wait(timeout: .now() + 2)
            throw URLError(.timedOut)
        }
        lock.lock(); let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { throw SpeedTestError.cancelled }
        return p
    }

    private func current(_ task: URLSessionTask) -> Pending? {
        lock.lock(); defer { lock.unlock() }
        return pending?.task === task ? pending : nil
    }

    static func randomData(_ count: Int) -> Data {
        var d = Data(count: count)
        d.withUnsafeMutableBytes { buf in
            if let base = buf.baseAddress { arc4random_buf(base, buf.count) }
        }
        return d
    }

    /// Server processing time from `Server-Timing` (cfRequestDuration, else cfSpeedWorker), in ms.
    static func serverTimingMs(_ header: String?) -> Double? {
        guard let header else { return nil }
        var found: [String: Double] = [:]
        for entry in header.split(separator: ",") {
            let parts = entry.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let name = parts.first,
                  let dur = parts.dropFirst().first(where: { $0.hasPrefix("dur=") }).flatMap({ Double($0.dropFirst(4)) }),
                  dur.isFinite, dur >= 0 else { continue }
            found[name] = dur
        }
        return found["cfRequestDuration"] ?? found["cfSpeedWorker"]
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // A redirect is a captive portal or proxy, never the speed test server.
        current(task)?.failure = SpeedTestError.httpStatus(response.statusCode)
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let p = current(dataTask) else { completionHandler(.cancel); return }
        if let http = response as? HTTPURLResponse {
            if !(200..<300).contains(http.statusCode) { p.failure = SpeedTestError.httpStatus(http.statusCode) }
            else if p.direction == .download && http.mimeType != "application/octet-stream" {
                p.failure = SpeedTestError.invalidResponse
            }
            p.serverMs = Self.serverTimingMs(http.value(forHTTPHeaderField: "Server-Timing"))
        } else { p.failure = SpeedTestError.invalidResponse }
        let cap = p.direction == .download ? p.size : Self.responseLimit
        if p.failure == nil && response.expectedContentLength > Int64(cap) { p.failure = SpeedTestError.invalidResponse }
        completionHandler(p.failure == nil ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let p = current(dataTask), p.failure == nil else { return }
        p.received += data.count
        let cap = p.direction == .download ? p.size : Self.responseLimit
        if p.received > cap {
            p.failure = SpeedTestError.invalidResponse
            dataTask.cancel()
            return
        }
        if p.direction == .download { p.onBytes(data.count) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        current(task)?.metrics = metrics
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let p = current(task), !p.finished else { return }
        p.finished = true
        if p.failure == nil, let error { p.failure = error }
        // Upload progress callbacks count bytes handed to the kernel; megabytes can sit in send
        // buffers, which read about twice the real rate on a fast link. Credit the body only
        // once the server has answered for all of it.
        if p.failure == nil, p.direction == .upload, p.size > 0 { p.onBytes(p.size) }
        p.done.signal()
    }
}
