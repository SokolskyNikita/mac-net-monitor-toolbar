import Foundation

enum SpeedTestError: Error {
    case budgetExceeded, invalidResponse, networkChanged
    case httpStatus(Int)
}

enum SpeedDirection: String {
    case download, upload
}

struct SpeedMeasurement {
    var bytes: Int
    var seconds: Double
    var mbps: Double { Double(bytes) * 8 / max(seconds, 0.001) / 1e6 }
}

struct SpeedTestResult {
    var download: SpeedMeasurement?
    var upload: SpeedMeasurement?
    var errors: [String: String] = [:]
    var bytesReserved = 0
    var status: String { download == nil && upload == nil ? "failed" : errors.isEmpty ? "ok" : "partial" }

    var title: String {
        func rate(_ measurement: SpeedMeasurement?) -> String {
            guard let measurement else { return "—" }
            return String(format: measurement.mbps < 10 ? "%.1f" : "%.0f", measurement.mbps)
        }
        let reason = [SpeedDirection.download, .upload].compactMap { direction in
            errors[direction.rawValue].map { "\(direction.rawValue): \($0)" }
        }.joined(separator: "; ")
        if status == "failed" { return "Test failed — \(reason)" }
        let rates = "\(rate(download))↓ / \(rate(upload))↑ Mbps"
        return status == "ok" ? "Last test: \(rates)" : "Partial test: \(rates) (\(reason))"
    }
}

/// Short, adaptive transfers keep slow links measurable without retrying multi-MB payloads.
/// All attempts reserve their maximum payload, including failures and upload responses.
enum SpeedTest {
    static let budgetBytes = 8_000_000
    static let responseLimit = 16_384
    static let phaseDuration: TimeInterval = 20
    static let phaseDeadline: TimeInterval = 45
    static let requestTimeout: TimeInterval = 20
    typealias Transfer = (SpeedDirection, Int, TimeInterval) throws -> Void

    static func run(transfer: Transfer,
                    now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                    isCurrentNetwork: () -> Bool = { true },
                    progress: (SpeedDirection) -> Void = { _ in }) -> SpeedTestResult {
        var result = SpeedTestResult()
        for direction in [SpeedDirection.download, .upload] {
            guard isCurrentNetwork() else {
                result.errors[direction.rawValue] = reason(SpeedTestError.networkChanged)
                break
            }
            progress(direction)
            let started = now()
            let target = direction == .download ? 4_000_000 : 1_500_000
            let maxChunk = direction == .download ? 1_000_000 : 256_000
            var chunk = 32_768, bytes = 0, seconds = 0.0, failures = 0
            while bytes < target && (bytes == 0 || now() - started < phaseDuration) {
                guard isCurrentNetwork() else {
                    result.errors[direction.rawValue] = reason(SpeedTestError.networkChanged)
                    break
                }
                let remainingTime = phaseDeadline - (now() - started)
                guard remainingTime > 0 else {
                    result.errors[direction.rawValue] = reason(URLError(.timedOut))
                    break
                }
                let overhead = direction == .upload ? responseLimit : 0
                let size = min(chunk, target - bytes, budgetBytes - result.bytesReserved - overhead)
                guard size > 0 else {
                    result.errors[direction.rawValue] = reason(SpeedTestError.budgetExceeded)
                    break
                }
                result.bytesReserved += size + overhead
                let t0 = now()
                do {
                    try transfer(direction, size, min(requestTimeout, remainingTime))
                    guard isCurrentNetwork() else { throw SpeedTestError.networkChanged }
                    let elapsed = max(now() - t0, 0.001)
                    bytes += size; seconds += elapsed; failures = 0
                    // Aim for three seconds per chunk. Slow links can use as little as 8 KB.
                    chunk = Int(min(Double(maxChunk), max(8192, Double(size) * 3 / elapsed)))
                } catch {
                    // Include time spent on failed attempts so retries cannot inflate the rate.
                    seconds += max(now() - t0, 0)
                    failures += 1
                    if !isRetryable(error) || failures >= 3 || (bytes > 0 && now() - started >= phaseDuration) {
                        result.errors[direction.rawValue] = reason(error)
                        break
                    }
                    chunk = max(8192, size / 2)
                }
            }
            if bytes > 0 {
                let measurement = SpeedMeasurement(bytes: bytes, seconds: seconds)
                if direction == .download { result.download = measurement }
                else { result.upload = measurement }
            }
        }
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
        case SpeedTestError.httpStatus(let status): return "server HTTP \(status)"
        case let error as URLError:
            switch error.code {
            case .timedOut: return "timed out"
            case .networkConnectionLost: return "connection interrupted"
            case .notConnectedToInternet: return "offline"
            case .cannotFindHost, .dnsLookupFailed: return "DNS lookup failed"
            case .cannotConnectToHost: return "server unreachable"
            case .secureConnectionFailed, .serverCertificateUntrusted: return "secure connection failed"
            default: return "network error \(error.code.rawValue)"
            }
        default: return error.localizedDescription
        }
    }
}

/// Task-specific delegate: stream and bound responses instead of buffering a full failed transfer.
/// Each task owns its state, so late cancellation callbacks cannot contaminate a retry.
final class SpeedTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let direction: SpeedDirection
    let size: Int
    private let semaphore = DispatchSemaphore(value: 0)
    private var received = 0
    private var failure: Error?
    private var result: Result<Void, Error>?

    init(direction: SpeedDirection, size: Int) { self.direction = direction; self.size = size }

    func run(session: URLSession, timeout: TimeInterval) throws {
        let url = direction == .download ? URLPart.speedDownURL(bytes: size) : URLPart.speedUpURL
        guard let endpoint = URL(string: url + "\(url.contains("?") ? "&" : "?")n=\(UUID().uuidString)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if direction == .upload {
            request.httpMethod = HTTPMethod.post
            request.httpBody = Data(count: size)
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        let task = session.dataTask(with: request)
        task.delegate = self
        task.resume()
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            throw URLError(.timedOut)
        }
        try (result ?? .failure(URLError(.unknown))).get()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        failure = SpeedTestError.httpStatus(response.statusCode)
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            if !(200..<300).contains(http.statusCode) { failure = SpeedTestError.httpStatus(http.statusCode) }
            else if direction == .download && http.mimeType != "application/octet-stream" {
                failure = SpeedTestError.invalidResponse
            }
        } else { failure = SpeedTestError.invalidResponse }
        let cap = direction == .download ? size : SpeedTest.responseLimit
        if failure == nil && response.expectedContentLength > Int64(cap) { failure = SpeedTestError.invalidResponse }
        completionHandler(failure == nil ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        received += data.count
        if received > (direction == .download ? size : SpeedTest.responseLimit) {
            failure = SpeedTestError.invalidResponse
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = failure ?? error { result = .failure(error) }
        else if direction == .download && received != size { result = .failure(SpeedTestError.invalidResponse) }
        else { result = .success(()) }
        semaphore.signal()
    }
}
