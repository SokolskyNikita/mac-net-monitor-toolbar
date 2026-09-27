import Foundation

/// Run a helper with a wall-clock timeout; drain pipes on side queues so large stdout can't deadlock.
func runProc(_ path: String, _ args: [String], timeout: TimeInterval = 10, requireSuccess: Bool = false) -> String? {
    guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
    return autoreleasepool { () -> String? in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe
        do { try p.run() } catch { return nil }

        final class Box: @unchecked Sendable { var data = Data(); let lock = NSLock() }
        let box = Box()
        let group = DispatchGroup()
        group.enter()
        // userInitiated — don't starve behind identity/system_profiler work on utility.
        DispatchQueue.global(qos: .userInitiated).async {
            let d = outPipe.fileHandleForReading.readDataToEndOfFile()
            box.lock.lock(); box.data.append(d); box.lock.unlock()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            _ = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let t0 = Date()
        while p.isRunning, Date().timeIntervalSince(t0) < timeout {
            Thread.sleep(forTimeInterval: 0.03)
        }
        if p.isRunning {
            p.terminate()
            let killAt = Date().addingTimeInterval(1.5)
            while p.isRunning, Date() < killAt { Thread.sleep(forTimeInterval: 0.03) }
        }
        _ = group.wait(timeout: .now() + 2)
        if requireSuccess && (p.isRunning || p.terminationStatus != 0) { return nil }
        box.lock.lock(); let data = box.data; box.lock.unlock()
        return String(data: data, encoding: .utf8)
    }
}
