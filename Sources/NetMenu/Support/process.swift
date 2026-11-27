import Darwin
import Foundation

/// How a helper run ended. Callers that measure the network must tell `launchFailed` (this Mac
/// could not run the probe) apart from a probe that ran and got no answer.
struct ProcResult {
    enum Outcome: Equatable {
        case exited(Int32)
        /// Ended by a signal it did not handle (a crash, or killed by someone else).
        case signaled(Int32)
        /// Killed after the wall-clock timeout.
        case timedOut
        /// Exited, but its output could not be read completely; stdout may be truncated.
        case outputIncomplete
        case launchFailed(String)
    }

    var outcome: Outcome
    var stdout: String
    /// First `stderrLimit` bytes, for classifying failures and for the diagnostic log.
    var stderr: String = ""
    static let stderrLimit = 4096
    /// `stdout` undecoded, for callers that must judge whether a body is valid text.
    var stdoutData = Data()

    var launched: Bool {
        if case .launchFailed = outcome { return false }
        return true
    }

    var succeeded: Bool { outcome == .exited(0) }

    var summary: String {
        switch outcome {
        case .exited(let status): return "exit \(status)"
        case .signaled(let signal): return "signal \(signal)"
        case .timedOut: return "timed out"
        case .outputIncomplete: return "output incomplete"
        case .launchFailed(let reason): return "launch failed: \(reason)"
        }
    }
}

/// Run a helper with a wall-clock timeout. Pipes drain on side queues so large stdout can't
/// deadlock, and every descriptor is closed before returning.
func runProcess(_ path: String, _ args: [String], timeout: TimeInterval = Configuration.reliability.helperTimeout) -> ProcResult {
    guard FileManager.default.isExecutableFile(atPath: path) else {
        return ProcResult(outcome: .launchFailed("\(path) is not executable"), stdout: "")
    }
    return autoreleasepool { () -> ProcResult in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe
        p.standardInput = FileHandle.nullDevice
        // Sleep until the helper exits rather than waking every few milliseconds to ask.
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch {
            for pipe in [outPipe, errPipe] {
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
            let reason = launchFailureReason(error)
            Diagnostics.shared.count(.launchFailure)
            DiagLog.shared.warn("process", "cannot launch \(path): \(reason)", throttleKey: "launch")
            return ProcResult(outcome: .launchFailed(reason), stdout: "")
        }

        HelperPIDs.shared.add(p.processIdentifier)

        final class Box: @unchecked Sendable { var data = Data(); var err = Data(); let lock = NSLock() }
        let box = Box()
        let group = DispatchGroup()
        group.enter()
        // userInitiated — don't starve behind network identity work on utility.
        DispatchQueue.global(qos: .userInitiated).async {
            let d = drainAndClose(outPipe)
            box.lock.lock(); box.data.append(d); box.lock.unlock()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let e = drainAndClose(errPipe).prefix(ProcResult.stderrLimit)
            box.lock.lock(); box.err = Data(e); box.lock.unlock()
            group.leave()
        }

        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut && p.isRunning
        if timedOut {
            Diagnostics.shared.count(.processTimeout)
            terminateProcess(p, grace: Configuration.reliability.helperTerminateGrace)
        }
        // Foundation keeps every Process (with its pipes, handles and a dispatch queue) alive until
        // its exit is reaped by waitUntilExit; without it each helper leaked ~1 KB,
        // ~250 MB a month. It returns at once for a process that has already exited.
        if !p.isRunning { p.waitUntilExit() }
        let readersDone = group.wait(timeout: .now() + Configuration.reliability.helperDrainTimeout) == .success
        if !readersDone {
            // A grandchild may still hold the write end; the reader exits when it closes.
            DiagLog.shared.warn("process", "\(path) output still open after drain deadline", throttleKey: "reader")
        }
        box.lock.lock(); let data = box.data, err = box.err; box.lock.unlock()
        let stdout = String(decoding: data, as: UTF8.self)
        let stderr = String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // terminationStatus raises an Objective-C exception while the process is still running.
        func result(_ outcome: ProcResult.Outcome) -> ProcResult {
            ProcResult(outcome: outcome, stdout: stdout, stderr: stderr, stdoutData: data)
        }
        if timedOut || p.isRunning { return result(.timedOut) }
        if !readersDone { return result(.outputIncomplete) }
        if p.terminationReason == .uncaughtSignal { return result(.signaled(p.terminationStatus)) }
        return result(.exited(p.terminationStatus))
    }
}

/// PIDs of helpers NetMenu started recently, so their traffic (curl) is shown as NetMenu's
/// in Top apps rather than as the user's own `curl`. Bounded by count and age.
final class HelperPIDs: @unchecked Sendable {
    static let shared = HelperPIDs()
    static let maxAge = Configuration.reliability.helperHistoryLifetime
    static let maxCount = 4096
    private let lock = NSLock()
    private var started: [Int32: TimeInterval] = [:]

    func add(_ pid: Int32, at now: TimeInterval = BandwidthClock.now()) {
        lock.lock(); defer { lock.unlock() }
        started[pid] = now
        if started.count > Self.maxCount { started = started.filter { now - $0.value <= Self.maxAge } }
        if started.count > Self.maxCount { started.removeAll() }
    }

    func contains(_ pid: Int32, at now: TimeInterval = BandwidthClock.now()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let at = started[pid] else { return false }
        return now - at <= Self.maxAge
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return started.count }
}

/// Compatibility wrapper: stdout, or nil when the helper could not run (or failed, if required).
func runProc(_ path: String, _ args: [String], timeout: TimeInterval = Configuration.reliability.helperTimeout, requireSuccess: Bool = false) -> String? {
    let r = runProcess(path, args, timeout: timeout)
    guard r.launched else { return nil }
    if requireSuccess && !r.succeeded { return nil }
    return r.stdout
}

/// SIGTERM, then SIGKILL if the process ignores it for `grace` seconds.
func terminateProcess(_ p: Process, grace: TimeInterval) {
    guard p.isRunning else { return }
    p.terminate()
    let killAt = Date().addingTimeInterval(grace)
    while p.isRunning, Date() < killAt { Thread.sleep(forTimeInterval: 0.02) }
    if p.isRunning {
        _ = Darwin.kill(p.processIdentifier, SIGKILL)
        let reapBy = Date().addingTimeInterval(Configuration.reliability.helperReapGrace)
        while p.isRunning, Date() < reapBy { Thread.sleep(forTimeInterval: 0.02) }
    }
}

/// Read a pipe to EOF and close its read end now. Left to dealloc, the handle is autoreleased on
/// a busy GCD worker whose pool rarely drains; thousands piled up until spawning helpers failed.
/// Uses the throwing API: readDataToEndOfFile raises an uncatchable exception on I/O errors.
func drainAndClose(_ pipe: Pipe) -> Data {
    autoreleasepool {
        let handle = pipe.fileHandleForReading
        let data = (try? handle.readToEnd()) ?? Data()
        try? handle.close()
        return data
    }
}

private func launchFailureReason(_ error: Error) -> String {
    let ns = error as NSError
    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
        return String(cString: strerror(Int32(underlying.code)))
    }
    if ns.domain == NSPOSIXErrorDomain { return String(cString: strerror(Int32(ns.code))) }
    return "\(ns.domain) \(ns.code)"
}
