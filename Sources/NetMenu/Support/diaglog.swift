// Detailed diagnostic log for reproducing problems after the fact, separate from the user-facing
// stats JSONL. Plain text, one event per line, in ~/Library/Logs/NetMenu (Console.app shows it).
//
// Bounded: NetMenu.log rotates to NetMenu.1.log … NetMenu.<archives>.log at `maxFileBytes`, so
// the directory never holds more than (archives + 1) × maxFileBytes. Writing never throws or
// blocks the caller; if the file is deleted or cannot be opened, the next write reopens it.
// Warnings and errors are mirrored to the unified log (`log show --predicate 'subsystem ==
// "me.sokolsky.netmenu"'`), which the OS bounds on its own.

import Darwin
import Foundation
import os

final class DiagLog: @unchecked Sendable {
    static let shared = DiagLog()

    static let defaultDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
        .map { $0.appendingPathComponent("Logs/NetMenu", isDirectory: true) }
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/NetMenu", isDirectory: true)
    static let defaultMaxFileBytes = 10_000_000
    static let defaultArchives = 2
    static let maxLineBytes = 8192

    enum Level: Int, Comparable {
        case debug, info, warn, error
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
        var label: String { ["DEBUG", "INFO", "WARN", "ERROR"][rawValue] }
    }

    private let queue = DispatchQueue(label: "netmenu.diaglog", qos: .utility, autoreleaseFrequency: .workItem)
    private let osLog = Logger(subsystem: "me.sokolsky.netmenu", category: "diagnostics")
    private let stateLock = NSLock()
    private var enabled = false
    private var directory: URL
    private var maxFileBytes: UInt64
    private var archives: Int
    private var throttled: [String: TimeInterval] = [:]
    // Owned by `queue`.
    private var fd: Int32 = -1
    private var size: UInt64 = 0
    private var lastOpenAttempt: TimeInterval = -.infinity
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(directory: URL = DiagLog.defaultDirectory, maxFileBytes: Int = DiagLog.defaultMaxFileBytes,
         archives: Int = DiagLog.defaultArchives) {
        precondition(maxFileBytes > DiagLog.maxLineBytes && archives >= 0)
        self.directory = directory
        self.maxFileBytes = UInt64(maxFileBytes)
        self.archives = archives
    }

    var fileURL: URL { directory.appendingPathComponent("NetMenu.log") }

    func archiveURL(_ n: Int) -> URL { directory.appendingPathComponent("NetMenu.\(n).log") }

    /// Until enabled, only warnings and errors reach the unified log; tests and `--sample` write no files.
    func enable() {
        stateLock.lock(); enabled = true; stateLock.unlock()
    }

    func debug(_ category: String, _ message: @autoclosure () -> String) { log(.debug, category, message()) }
    func info(_ category: String, _ message: @autoclosure () -> String) { log(.info, category, message()) }
    func warn(_ category: String, _ message: @autoclosure () -> String, throttleKey: String? = nil) {
        log(.warn, category, message(), throttleKey: throttleKey)
    }
    func error(_ category: String, _ message: @autoclosure () -> String, throttleKey: String? = nil) {
        log(.error, category, message(), throttleKey: throttleKey)
    }

    /// `throttleKey` limits a repeating message to one line per minute; repeats are counted.
    func log(_ level: Level, _ category: String, _ message: String, throttleKey: String? = nil) {
        let now = Date()
        var text = message
        if let key = throttleKey {
            stateLock.lock()
            let last = throttled[key] ?? -.infinity
            let allowed = now.timeIntervalSince1970 - last >= 60
            if allowed { throttled[key] = now.timeIntervalSince1970 }
            stateLock.unlock()
            guard allowed else { Diagnostics.shared.count(.throttledLogLines); return }
            text += " (repeats suppressed for 60s)"
        }
        if level >= .warn {
            let type: OSLogType = level == .error ? .error : .default
            osLog.log(level: type, "\(category, privacy: .public): \(text, privacy: .public)")
        }
        stateLock.lock(); let on = enabled; stateLock.unlock()
        guard on else { return }
        queue.async { [self] in write(level, category, text, at: now) }
    }

    /// Wait for queued lines, e.g. before the app exits.
    func flush() { queue.sync {} }

    // MARK: - File

    private func write(_ level: Level, _ category: String, _ message: String, at date: Date) {
        var line = "\(formatter.string(from: date)) \(level.label) [\(category)] "
        line += message.replacingOccurrences(of: "\n", with: " ⏎ ").replacingOccurrences(of: "\r", with: "")
        if line.utf8.count > Self.maxLineBytes {
            line = String(decoding: line.utf8.prefix(Self.maxLineBytes - 16), as: UTF8.self) + " …[truncated]"
        }
        line += "\n"
        let bytes = Array(line.utf8)

        guard ensureOpen() else { return }
        if size + UInt64(bytes.count) > maxFileBytes {
            rotate()
            guard ensureOpen() else { return }
        }
        let written = bytes.withUnsafeBytes { buf -> Int in
            var offset = 0
            while offset < buf.count {
                let n = Darwin.write(fd, buf.baseAddress!.advanced(by: offset), buf.count - offset)
                if n < 0 { if errno == EINTR { continue }; return -1 }
                if n == 0 { return -1 }
                offset += n
            }
            return offset
        }
        if written < 0 { closeFile() } else { size += UInt64(written) }
    }

    /// Reopens when the file was deleted or moved away (st_nlink == 0) so logging resumes.
    private func ensureOpen() -> Bool {
        if fd >= 0 {
            var st = stat()
            if fstat(fd, &st) == 0, st.st_nlink > 0 { return true }
            closeFile()
        }
        // After a failed open, retry at most every 5s rather than on every line.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastOpenAttempt >= 5 else { return false }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let d = Darwin.open(fileURL.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, mode_t(0o644))
        guard d >= 0 else { lastOpenAttempt = now; return false }
        var st = stat()
        size = fstat(d, &st) == 0 ? UInt64(max(0, st.st_size)) : 0
        fd = d
        return true
    }

    private func rotate() {
        closeFile()
        let fm = FileManager.default
        if archives == 0 {
            try? fm.removeItem(at: fileURL)
        } else {
            try? fm.removeItem(at: archiveURL(archives))
            for n in stride(from: archives - 1, through: 1, by: -1) {
                _ = Darwin.rename(archiveURL(n).path, archiveURL(n + 1).path)
            }
            _ = Darwin.rename(fileURL.path, archiveURL(1).path)
        }
        lastOpenAttempt = -.infinity
    }

    private func closeFile() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1; size = 0
    }
}

/// Process-wide counters for the heartbeat line, so slow failures show up as trends.
final class Diagnostics: @unchecked Sendable {
    static let shared = Diagnostics()

    enum Counter: String, CaseIterable {
        case launchFailure = "launch_failures"
        case processTimeout = "proc_timeouts"
        case probeCycles = "cycles"
        case discardedCycles = "discarded_cycles"
        case throttledLogLines = "suppressed_log_lines"
    }

    private let lock = NSLock()
    private var counts: [Counter: Int] = [:]

    func count(_ c: Counter, by n: Int = 1) {
        lock.lock(); counts[c, default: 0] &+= n; lock.unlock()
    }

    func value(_ c: Counter) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[c] ?? 0
    }

    var summary: String {
        lock.lock(); defer { lock.unlock() }
        return Counter.allCases.map { "\($0.rawValue)=\(counts[$0] ?? 0)" }.joined(separator: " ")
    }
}

/// This process's own resource use, for leak detection.
enum ResourceUsage {
    static func openFileDescriptors() -> Int? {
        let pid = getpid()
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 32)
        let got = fds.withUnsafeMutableBytes { buf in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buf.baseAddress, Int32(buf.count))
        }
        return got > 0 ? Int(got) / stride : nil
    }

    static func threadCount() -> Int? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return Int(info.pti_threadnum)
    }

    /// Memory as Activity Monitor reports it.
    static func footprintBytes() -> UInt64? {
        var usage = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) == 0
            }
        }
        return ok ? usage.ri_phys_footprint : nil
    }

    /// CPU seconds used by this process and by its exited helpers (ping, curl, nettop…).
    static func cpuSeconds() -> (own: Double, helpers: Double) {
        func seconds(_ who: Int32) -> Double {
            var u = rusage()
            guard getrusage(who, &u) == 0 else { return 0 }
            func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
            return s(u.ru_utime) + s(u.ru_stime)
        }
        return (seconds(RUSAGE_SELF), seconds(RUSAGE_CHILDREN))
    }

    static func softFileLimit() -> UInt64? {
        var lim = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &lim) == 0 else { return nil }
        return UInt64(lim.rlim_cur)
    }

    /// GUI apps start with a 256-descriptor soft limit, little headroom for ~10 helpers every few
    /// seconds. Raise it (within the hard limit) so a transient burst cannot make spawns fail.
    @discardableResult
    static func raiseFileLimit(to wanted: rlim_t = 4096) -> UInt64? {
        var lim = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &lim) == 0 else { return nil }
        if lim.rlim_cur < wanted {
            var perProc: Int32 = 0
            var size = MemoryLayout<Int32>.size
            let cap = sysctlbyname("kern.maxfilesperproc", &perProc, &size, nil, 0) == 0 && perProc > 0
                ? rlim_t(perProc) : wanted
            lim.rlim_cur = min(wanted, lim.rlim_max, cap)
            _ = setrlimit(RLIMIT_NOFILE, &lim)
        }
        return softFileLimit()
    }
}
