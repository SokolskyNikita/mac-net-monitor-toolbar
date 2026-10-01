// Best-effort per-process attribution for the live physical-interface byte totals.

import AppKit
import Darwin
import Foundation

struct AppBandwidthUsage: Equatable {
    let id: String
    let name: String
    let downBytes: Double
    let upBytes: Double
}

struct AppBandwidthSnapshot: Equatable {
    let apps: [AppBandwidthUsage]
    let totalBytes: Double
    let seconds: TimeInterval
}

struct NetTopProcessCounters: Equatable {
    let processName: String
    let pid: Int32
    let bytesIn: UInt64
    let bytesOut: UInt64
}

/// Parses nettop's repeated bytes_in/bytes_out tables. The first table is its lifetime baseline;
/// only the second table contains the requested interval delta.
enum AppBandwidthParser {
    static func parse(_ output: String) -> [NetTopProcessCounters]? {
        var blocks: [[String]] = []
        var activeBlock: Int?

        for line in output.components(separatedBy: .newlines) {
            if isHeader(line) {
                blocks.append([])
                activeBlock = blocks.count - 1
            } else if let activeBlock {
                blocks[activeBlock].append(line)
            }
        }

        guard blocks.count >= 2 else { return nil }
        let intervalLines = blocks[1].compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        var rows: [NetTopProcessCounters] = []
        for line in intervalLines {
            // A process can disappear between nettop's sample and PID attribution, and some
            // process labels cannot be resolved to a PID. Keep the rows we can attribute.
            if let row = parseRow(line) { rows.append(row) }
        }
        // Header-only interval blocks are valid idle samples. A non-empty interval that has no
        // parseable process rows is malformed, so callers can expose unavailable exceptionally.
        guard intervalLines.isEmpty || !rows.isEmpty else { return nil }
        return rows
    }

    private static func isHeader(_ line: String) -> Bool {
        let columns = line.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                .lowercased()
        }
        guard let bytesIn = columns.firstIndex(of: "bytes_in"),
              bytesIn + 1 < columns.count else { return false }
        return columns[bytesIn + 1] == "bytes_out"
    }

    private static func parseRow(_ line: String) -> NetTopProcessCounters? {
        var fields = line.split(separator: ",", omittingEmptySubsequences: false)
        // nettop emits a trailing delimiter after each data row.
        if fields.last?.isEmpty == true { fields.removeLast() }
        guard fields.count >= 3,
              let bytesIn = UInt64(fields[fields.count - 2].trimmingCharacters(in: .whitespaces)),
              let bytesOut = UInt64(fields[fields.count - 1].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }

        // Rejoin everything before the numeric tail so process names containing commas remain
        // intact. nettop appends the pid after the final dot in that process label.
        var label = fields.dropLast(2).joined(separator: ",").trimmingCharacters(in: .whitespaces)
        if label.count >= 2, label.first == "\"", label.last == "\"" {
            label.removeFirst(); label.removeLast()
            label = label.replacingOccurrences(of: "\"\"", with: "\"")
        }
        guard let dot = label.lastIndex(of: ".") else { return nil }
        let pidText = label[label.index(after: dot)...]
        guard let pid = Int32(pidText), pid > 0 else { return nil }
        let name = String(label[..<dot]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return NetTopProcessCounters(processName: name, pid: pid, bytesIn: bytesIn, bytesOut: bytesOut)
    }
}

struct AppBandwidthProcessIdentity: Equatable {
    let id: String
    let name: String
}

/// Resolves processes to their outer .app bundle when possible, so nested XPC/helper executables
/// contribute to the owning application. Standalone executables group by their full path.
enum AppBandwidthProcessGrouper {
    static func identity(processName: String,
                         pid: Int32,
                         executablePath: String?,
                         runningApplicationName: String? = nil) -> AppBandwidthProcessIdentity {
        let processName = processName.trimmingCharacters(in: .whitespacesAndNewlines)
        let runningName = nonEmpty(runningApplicationName)

        if let executablePath, !executablePath.isEmpty {
            let path = URL(fileURLWithPath: executablePath).standardizedFileURL.path
            if let bundlePath = outermostAppBundle(in: path) {
                let bundleURL = URL(fileURLWithPath: bundlePath, isDirectory: true)
                let bundle = Bundle(url: bundleURL)
                let bundleName = nonEmpty(bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                    ?? nonEmpty(bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? nonEmpty(bundle?.localizedInfoDictionary?["CFBundleName"] as? String)
                    ?? nonEmpty(bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                let fallbackName = URL(fileURLWithPath: bundlePath).deletingPathExtension().lastPathComponent
                return AppBandwidthProcessIdentity(
                    id: "app:\(bundlePath)",
                    // A helper may have a localizedName such as "Codex (Service)". The owning
                    // outer bundle's own metadata or directory name is the stable display name.
                    name: bundleName ?? nonEmpty(fallbackName) ?? runningName ?? processName
                )
            }

            let executableName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            return AppBandwidthProcessIdentity(
                id: "exec:\(path)",
                name: runningName ?? nonEmpty(executableName) ?? processName
            )
        }

        let fallback = runningName ?? processName
        // Without a path we cannot know whether equal or truncated nettop names belong to the
        // same executable, so keep the pid in the key to avoid merging unrelated processes.
        return AppBandwidthProcessIdentity(id: "process:\(fallback.lowercased()):\(pid)", name: fallback)
    }

    static func aggregate(_ rows: [NetTopProcessCounters],
                          identityFor: (NetTopProcessCounters) -> AppBandwidthProcessIdentity)
        -> [AppBandwidthUsage] {
        struct Totals {
            var identity: AppBandwidthProcessIdentity
            var down = 0.0
            var up = 0.0
        }

        var totals: [String: Totals] = [:]
        for row in rows {
            let identity = identityFor(row)
            var current = totals[identity.id] ?? Totals(identity: identity)
            current.down += Double(row.bytesIn)
            current.up += Double(row.bytesOut)
            // Prefer an identity with a non-empty display name if a fallback row was seen first.
            if current.identity.name.isEmpty, !identity.name.isEmpty { current.identity = identity }
            totals[identity.id] = current
        }

        return totals.values.map {
            AppBandwidthUsage(id: $0.identity.id, name: $0.identity.name,
                              downBytes: $0.down, upBytes: $0.up)
        }.sorted {
            let lhs = $0.downBytes + $0.upBytes, rhs = $1.downBytes + $1.upBytes
            return lhs == rhs ? $0.id.localizedStandardCompare($1.id) == .orderedAscending : lhs > rhs
        }
    }

    private static func outermostAppBundle(in path: String) -> String? {
        let components = URL(fileURLWithPath: path).pathComponents
        guard let index = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else { return nil }
        return NSString.path(withComponents: Array(components.prefix(index + 1)))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Repeatedly samples nettop away from the main thread and pairs process byte deltas with an
/// optional physical-interface delta. Attribution is approximate because the samplers start at
/// slightly different times; process totals remain available when interface counters cannot be read.
final class AppBandwidthMonitor {
    static let sampleInterval: TimeInterval = 10
    private static let commandTimeout = sampleInterval + 5
    private static let maxSampleSeconds = sampleInterval + 5

    private let condition = NSCondition()
    private var generation = 0
    private var started = false
    private var handler: ((AppBandwidthSnapshot?) -> Void)?
    private var currentProcess: Process?

    func start(handler: @escaping (AppBandwidthSnapshot?) -> Void) {
        condition.lock()
        self.handler = handler
        guard !started else { condition.unlock(); return }
        started = true
        generation += 1
        let token = generation
        condition.unlock()
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.sampleLoop(generation: token) }
    }

    /// Starts a fresh sampler run. In-flight results and callbacks already queued to main are
    /// invalidated, which is used when the active network connection changes.
    func reset() {
        condition.lock()
        generation += 1
        let token = generation
        let shouldRestart = started
        let process = currentProcess
        currentProcess = nil
        condition.broadcast()
        condition.unlock()
        requestTermination(process)
        if shouldRestart {
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.sampleLoop(generation: token) }
        }
    }

    func stop() {
        condition.lock()
        generation += 1
        started = false
        handler = nil
        let process = currentProcess
        currentProcess = nil
        condition.broadcast()
        condition.unlock()
        requestTermination(process)
    }

    private func sampleLoop(generation token: Int) {
        var failures = 0
        while isCurrent(token) {
            // This loop is one never-ending work item: without a pool per sample, everything
            // Process, Pipe and NSRunningApplication autorelease piles up (~35 MB/day).
            let snapshot = autoreleasepool { collect(generation: token) }
            if let snapshot {
                failures = 0
                deliver(snapshot, generation: token)
            } else {
                failures += 1
                deliver(nil, generation: token)
                let backoff = min(30.0, pow(2.0, Double(min(failures - 1, 5))))
                guard wait(seconds: backoff, generation: token) else { break }
            }
        }
    }

    private func collect(generation token: Int) -> AppBandwidthSnapshot? {
        guard isCurrent(token) else { return nil }
        let before = readCounters()
        let beganAt = BandwidthClock.now()
        guard let output = runNettop(generation: token), isCurrent(token),
              let rows = AppBandwidthParser.parse(output) else { return nil }
        let after = readCounters()
        guard isCurrent(token) else { return nil }
        let seconds = BandwidthClock.now() - beganAt
        guard seconds.isFinite, seconds > 0, seconds <= Self.maxSampleSeconds else { return nil }

        let identities = AppBandwidthProcessGrouper.aggregate(rows) { row in
            // NetMenu's own website checks (curl) count as NetMenu, not as the user's curl.
            if HelperPIDs.shared.contains(row.pid) {
                return AppBandwidthProcessGrouper.identity(processName: "NetMenu", pid: getpid(),
                                                           executablePath: Bundle.main.executablePath,
                                                           runningApplicationName: "NetMenu")
            }
            let runningApplication = NSRunningApplication(processIdentifier: row.pid)
            let path = processPath(pid: row.pid) ?? runningApplication?.bundleURL?.path
            let appName = runningApplication?.localizedName
            return AppBandwidthProcessGrouper.identity(processName: row.processName,
                                                       pid: row.pid,
                                                       executablePath: path,
                                                       runningApplicationName: appName)
        }
        let processTotal = identities.reduce(0.0) { $0 + $1.downBytes + $1.upBytes }
        var totalBytes = processTotal
        if let before, let after {
            let rates = deltaRates(old: before, new: after, dt: seconds)
            let physicalDown = max(0, rates.down * seconds)
            let physicalUp = max(0, rates.up * seconds)
            let physicalTotal = physicalDown + physicalUp
            if physicalTotal.isFinite { totalBytes = physicalTotal }
        }
        return AppBandwidthSnapshot(apps: identities, totalBytes: totalBytes, seconds: seconds)
    }

    private func runNettop(generation token: Int) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        // nettop accumulates all bytes between the baseline and the second sample. A ten-second
        // interval ranks the whole window, rather than publishing a delayed five-second reading.
        process.arguments = ["-P", "-L", "2", "-n", "-x", "-d", "-s", String(Int(Self.sampleInterval)),
                             "-J", "bytes_in,bytes_out", "-t", "wifi", "-t", "wired", "-c"]
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        // macOS nettop busy-spins if stdin is EOF. Keep the pipe writer open for the full run.
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do { try process.run() } catch {
            for pipe in [inputPipe, outputPipe, errorPipe] {
                try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close()
            }
            DiagLog.shared.warn("apps", "cannot launch nettop: \(error.localizedDescription)", throttleKey: "nettop-launch")
            return nil
        }
        guard attach(process, generation: token) else {
            // Stop nettop first: draining a running nettop would block until it exits on its own.
            terminateAndWait(process)
            try? inputPipe.fileHandleForWriting.close()
            _ = drainAndClose(outputPipe); _ = drainAndClose(errorPipe)
            terminateAndWait(process)
            return nil
        }

        final class DataBox: @unchecked Sendable {
            let lock = NSLock()
            var data = Data()
        }
        let output = DataBox()
        let drainGroup = DispatchGroup()
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = drainAndClose(outputPipe)
            output.lock.lock(); output.data = data; output.lock.unlock()
            drainGroup.leave()
        }
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            _ = drainAndClose(errorPipe)
            drainGroup.leave()
        }
        defer { try? inputPipe.fileHandleForWriting.close() }

        let startedAt = BandwidthClock.now()
        var timedOut = false
        while process.isRunning {
            if !isCurrent(token) {
                requestTermination(process)
                break
            }
            if BandwidthClock.now() - startedAt >= Self.commandTimeout {
                timedOut = true
                requestTermination(process)
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning { terminateAndWait(process) }
        if !process.isRunning { process.waitUntilExit() }
        _ = drainGroup.wait(timeout: .now() + 2)
        detach(process, generation: token)

        // terminationStatus raises an Objective-C exception while the process is still running.
        guard !process.isRunning else {
            DiagLog.shared.error("apps", "nettop survived SIGKILL", throttleKey: "nettop-zombie")
            return nil
        }
        guard !timedOut, isCurrent(token) else {
            if timedOut { DiagLog.shared.warn("apps", "nettop timed out", throttleKey: "nettop-timeout") }
            return nil
        }
        guard process.terminationStatus == 0 else {
            DiagLog.shared.warn("apps", "nettop exited \(process.terminationStatus)", throttleKey: "nettop-exit")
            return nil
        }
        output.lock.lock(); let data = output.data; output.lock.unlock()
        return String(data: data, encoding: .utf8)
    }

    private func attach(_ process: Process, generation token: Int) -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard started, generation == token else { return false }
        currentProcess = process
        return true
    }

    private func detach(_ process: Process, generation token: Int) {
        condition.lock(); defer { condition.unlock() }
        if generation == token, currentProcess === process { currentProcess = nil }
    }

    private func isCurrent(_ token: Int) -> Bool {
        condition.lock(); defer { condition.unlock() }
        return started && generation == token
    }

    private func wait(seconds: TimeInterval, generation token: Int) -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard started, generation == token else { return false }
        _ = condition.wait(until: Date().addingTimeInterval(seconds))
        return started && generation == token
    }

    private func deliver(_ snapshot: AppBandwidthSnapshot?, generation token: Int) {
        condition.lock()
        guard started, generation == token, let handler else { condition.unlock(); return }
        condition.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrent(token) else { return }
            handler(snapshot)
        }
    }

    private func requestTermination(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            if process.isRunning { _ = Darwin.kill(pid, SIGKILL) }
        }
    }

    private func terminateAndWait(_ process: Process) {
        terminateProcess(process, grace: 1.0)
    }

    private func processPath(pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is a C macro that is not imported by Swift.
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = path.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let baseAddress = buffer.baseAddress else { return 0 }
            return proc_pidpath(pid, baseAddress, UInt32(buffer.count))
        }
        guard length > 0 else { return nil }
        return path.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return nil }
            return String(cString: baseAddress)
        }
    }
}
