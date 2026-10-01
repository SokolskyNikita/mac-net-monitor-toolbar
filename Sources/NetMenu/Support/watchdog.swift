// Last-resort self-healing for a menu bar app that runs for weeks. Known leaks are fixed at the
// source; this catches the unknown ones before they corrupt measurements. Once a minute, off the
// main thread, it checks this process's descriptors, threads, memory, and main-thread
// responsiveness. Past a limit it logs why and relaunches a fresh copy of the app. It never
// relaunches within `minUptime` of launch, so a fault present at startup cannot loop.

import AppKit
import Foundation

final class Watchdog: @unchecked Sendable {
    struct Limits {
        var maxFileDescriptors = 1000
        var maxThreads = 300
        var maxFootprintBytes: UInt64 = 1_500_000_000
        var mainHang: TimeInterval = 120
        var minUptime: TimeInterval = 30 * 60
    }

    struct Reading {
        var fileDescriptors: Int?
        var threads: Int?
        var footprintBytes: UInt64?
        var mainUnresponsive: TimeInterval
        var fileLimit: UInt64? = nil
    }

    static let interval: TimeInterval = 60

    private let limits: Limits
    private let queue = DispatchQueue(label: "netmenu.watchdog", qos: .utility, autoreleaseFrequency: .workItem)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var mainRepliedAt = BandwidthClock.now()
    private var lastTick = BandwidthClock.now()
    private let startedAt = BandwidthClock.now()
    private var relaunching = false

    init(limits: Limits = Limits()) { self.limits = limits }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .seconds(5))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// Reasons to relaunch, empty when healthy. Pure, for tests.
    static func problems(_ r: Reading, limits: Limits) -> [String] {
        var out: [String] = []
        // Leave headroom below the process limit too, or spawns would fail before we notice.
        let fdLimit = r.fileLimit.map { min(limits.maxFileDescriptors, Int(min($0, UInt64(Int.max))) / 2) }
            ?? limits.maxFileDescriptors
        if let fds = r.fileDescriptors, fds > fdLimit { out.append("\(fds) open file descriptors") }
        if let n = r.threads, n > limits.maxThreads { out.append("\(n) threads") }
        if let b = r.footprintBytes, b > limits.maxFootprintBytes { out.append("\(b / 1_000_000) MB memory") }
        if r.mainUnresponsive > limits.mainHang { out.append("main thread unresponsive for \(Int(r.mainUnresponsive))s") }
        return out
    }

    private func tick() {
        let now = BandwidthClock.now()
        lock.lock()
        // The timer does not fire during sleep; a long gap means we just woke, so the main
        // thread's last reply is stale for that reason alone. Start a fresh measurement.
        let woke = now - lastTick > Self.interval * 2
        lastTick = now
        if woke { mainRepliedAt = now }
        let unresponsive = now - mainRepliedAt
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.mainRepliedAt = BandwidthClock.now(); self.lock.unlock()
        }

        let reading = Reading(fileDescriptors: ResourceUsage.openFileDescriptors(),
                              threads: ResourceUsage.threadCount(),
                              footprintBytes: ResourceUsage.footprintBytes(),
                              mainUnresponsive: unresponsive,
                              fileLimit: ResourceUsage.softFileLimit())
        let problems = Self.problems(reading, limits: limits)
        guard !problems.isEmpty else { return }
        let uptime = now - startedAt
        guard uptime >= limits.minUptime else {
            DiagLog.shared.error("watchdog", "unhealthy but up only \(Int(uptime))s, not relaunching: "
                                 + problems.joined(separator: ", "), throttleKey: "watchdog-young")
            return
        }
        relaunch(reason: problems.joined(separator: ", "), mainResponsive: unresponsive < limits.mainHang)
    }

    private func relaunch(reason: String, mainResponsive: Bool) {
        lock.lock()
        guard !relaunching else { lock.unlock(); return }
        relaunching = true
        lock.unlock()

        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else {
            DiagLog.shared.error("watchdog", "unhealthy (\(reason)); not an app bundle, cannot relaunch")
            return
        }
        DiagLog.shared.error("watchdog", "relaunching: \(reason)")
        let opened = runProcess("/usr/bin/open", ["-n", bundle.path], timeout: 15).succeeded
        DiagLog.shared.flush()
        guard opened else {
            DiagLog.shared.error("watchdog", "relaunch failed; continuing")
            lock.lock(); relaunching = false; lock.unlock()
            return
        }
        // _exit, not exit: atexit handlers could deadlock on locks a hung main thread holds,
        // leaving this copy's menu bar item next to the new one. Logs are already flushed.
        if mainResponsive {
            DispatchQueue.main.async { NSApp.terminate(nil) }
            // terminate can be vetoed or stall; the new copy is already running.
            queue.asyncAfter(deadline: .now() + 10) { _exit(0) }
        } else {
            _exit(0)
        }
    }
}
