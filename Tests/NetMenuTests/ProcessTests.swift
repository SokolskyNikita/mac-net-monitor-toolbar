import Foundation
import Testing
@testable import NetMenu

@Suite(.serialized) struct ProcessTests {
    private static func openFDs() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
    }

    @Test func returnsStdout() {
        #expect(runProc("/bin/echo", ["hi"]) == "hi\n")
        #expect(runProc("/usr/bin/false", [], requireSuccess: true) == nil)
    }

    /// The probe loop runs helpers back to back on busy GCD threads whose autorelease pools rarely
    /// drain. Pipe handles left for dealloc piled up into thousands of fds until spawns failed.
    @Test func doesNotLeakPipeDescriptors() {
        let before = Self.openFDs()
        let group = DispatchGroup()
        for _ in 0..<8 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                for _ in 0..<25 { _ = runProc("/usr/bin/true", []) }
                group.leave()
            }
        }
        group.wait()
        let grown = Self.openFDs() - before
        #expect(grown < 20, "200 helper runs left \(grown) descriptors open")
    }

    /// Live NSConcreteTask objects in this process, via heap(1).
    private static func liveTasks() -> Int? {
        let r = runProcess("/usr/bin/heap", ["\(getpid())"], timeout: 60)
        guard let line = r.stdout.split(separator: "\n").first(where: { $0.contains("NSConcreteTask") }) else {
            return r.succeeded ? 0 : nil
        }
        return line.split(separator: " ").first.flatMap { Int($0) }
    }

    @Test func finishedHelpersAreFreed() throws {
        guard let before = Self.liveTasks() else { return }  // heap(1) unavailable here
        let group = DispatchGroup()
        for _ in 0..<4 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                for _ in 0..<25 { _ = runProc("/usr/bin/true", []) }
                group.leave()
            }
        }
        group.wait()
        let after = try #require(Self.liveTasks())
        #expect(after - before < 10, "100 helper runs left \(after - before) Process objects alive")
    }

    @Test func launchFailureIsDistinctFromFailure() {
        let missing = runProcess("/nonexistent/ping", [])
        #expect(!missing.launched)
        #expect(runProc("/nonexistent/ping", []) == nil)
        let failed = runProcess("/bin/sh", ["-c", "exit 2"])
        #expect(failed.launched)
        #expect(failed.outcome == .exited(2))
    }

    @Test func helperIgnoringSigtermIsKilled() {
        let t0 = Date()
        let r = runProcess("/bin/sh", ["-c", "trap '' TERM; sleep 30"], timeout: 0.3)
        #expect(r.outcome == .timedOut)
        #expect(Date().timeIntervalSince(t0) < 6)
    }
}

@Suite(.serialized) struct DiagLogTests {
    func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("netmenu-diaglog-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func totalBytes(_ dir: URL) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.reduce(0) { sum, name in
            let size = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path))?[.size] as? Int
            return sum + (size ?? 0)
        }
    }

    @Test func rotationBoundsTotalSize() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = DiagLog(directory: dir, maxFileBytes: 20_000, archives: 2)
        log.enable()
        for i in 0..<2000 { log.info("test", "line \(i) " + String(repeating: "x", count: 100)) }
        log.flush()
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names == ["NetMenu.1.log", "NetMenu.2.log", "NetMenu.log"])
        #expect(totalBytes(dir) <= 3 * 20_000)
        let newest = try String(contentsOf: log.fileURL, encoding: .utf8)
        #expect(newest.contains("line 1999 "))
    }

    @Test func reopensAfterDeletionAndSanitizesLines() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = DiagLog(directory: dir, maxFileBytes: 100_000, archives: 1)
        log.enable()
        log.info("test", "first")
        log.flush()
        try FileManager.default.removeItem(at: dir)
        log.info("test", "second\nforged line")
        log.info("test", String(repeating: "y", count: 50_000))
        log.flush()
        let text = try String(contentsOf: log.fileURL, encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix("second ⏎ forged line"))
        #expect(lines[1].utf8.count <= DiagLog.maxLineBytes)
    }

    @Test func disabledLogWritesNothing() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = DiagLog(directory: dir, maxFileBytes: 100_000, archives: 1)
        log.info("test", "hello")
        log.flush()
        #expect(!FileManager.default.fileExists(atPath: log.fileURL.path))
    }
}

@Suite struct WatchdogTests {
    @Test func healthyProcessHasNoProblems() {
        let r = Watchdog.Reading(fileDescriptors: ResourceUsage.openFileDescriptors(),
                                 threads: ResourceUsage.threadCount(),
                                 footprintBytes: ResourceUsage.footprintBytes(), mainUnresponsive: 0)
        #expect(r.fileDescriptors != nil && r.threads != nil && r.footprintBytes != nil)
        #expect(Watchdog.problems(r, limits: .init()).isEmpty)
    }

    @Test func leaksAndHangsAreReported() {
        let r = Watchdog.Reading(fileDescriptors: 4856, threads: 20, footprintBytes: 50_000_000, mainUnresponsive: 300)
        let problems = Watchdog.problems(r, limits: .init())
        #expect(problems.count == 2)
        #expect(problems[0].contains("4856"))
    }

    @Test func descriptorLimitLeavesHeadroomBelowProcessLimit() {
        let r = Watchdog.Reading(fileDescriptors: 200, threads: 20, footprintBytes: 1, mainUnresponsive: 0, fileLimit: 256)
        #expect(Watchdog.problems(r, limits: .init()).count == 1)
    }

    @Test func learningTheNameOfTheSameLinkIsNotANetworkChange() {
        let unnamed = Identity(iface: "en0", type: NetType.wifi, network: PortName.wifi, bssid: nil, router: "192.168.8.1",
                               rssi: nil, noise: nil, txRate: nil, channel: nil)
        var named = unnamed; named.network = "wds"; named.bssid = "94:83:c4:b1:ab:e5"
        var other = named; other.network = "cafe"; other.bssid = "00:11:22:33:44:55"
        var elsewhere = unnamed; elsewhere.router = "10.0.0.1"
        #expect(unnamed.sameNetwork(as: named))
        #expect(named.sameNetwork(as: unnamed))
        #expect(!named.sameNetwork(as: other))
        #expect(!elsewhere.sameNetwork(as: named))
    }

    @Test func helperPIDsAreRememberedBoundedly() {
        let reg = HelperPIDs()
        reg.add(42, at: 0)
        #expect(reg.contains(42, at: 10))
        #expect(!reg.contains(42, at: HelperPIDs.maxAge + 1))
        for i in 0..<(HelperPIDs.maxCount + 50) { reg.add(Int32(1000 + i), at: Double(i)) }
        #expect(reg.count <= HelperPIDs.maxCount)
        let r = runProcess("/bin/sh", ["-c", "echo $$"])
        #expect(HelperPIDs.shared.contains(Int32(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1))
    }

    @Test func redactedSSIDIsNotANetworkName() {
        #expect(isRedactedSSID("<redacted>"))
        #expect(isRedactedSSID(" "))
        #expect(!isRedactedSSID("wds"))
    }
}
