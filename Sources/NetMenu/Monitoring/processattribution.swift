import Darwin
import Foundation

/// A sample-local history: retain exited processes, but never reuse ownership across windows.
struct ProcessAncestry {
    struct Entry {
        let parent: Int32
        let started: UInt64
        let path: String?
    }
    private(set) var entries: [Int32: Entry] = [:]
    private(set) var reused: Set<Int32> = []

    mutating func record(pid: Int32, entry: Entry) {
        if let old = entries[pid], old.started != entry.started { reused.insert(pid) }
        // Keep the original parent if a process becomes orphaned during this window.
        if let old = entries[pid], old.started == entry.started {
            entries[pid] = Entry(parent: old.parent, started: old.started, path: entry.path ?? old.path)
        } else {
            entries[pid] = entry
        }
    }

    func identity(processName: String, pid: Int32) -> AppBandwidthProcessIdentity {
        let fallback = AppBandwidthProcessGrouper.identity(processName: processName, pid: pid,
            executablePath: reused.contains(pid) ? nil : entries[pid]?.path)
        var current = pid
        var visited: Set<Int32> = []
        while current > 1, visited.insert(current).inserted, !reused.contains(current),
              let entry = entries[current] {
            let identity = AppBandwidthProcessGrouper.identity(processName: processName, pid: current,
                                                               executablePath: entry.path)
            if identity.isApplication { return identity }
            guard let parent = entries[entry.parent], parent.started <= entry.started else { break }
            current = entry.parent
        }
        return fallback
    }

    /// What the process table says about one process. While it is unchanged the process is the
    /// same program as at the last capture, so its parent and path need not be read again.
    private struct Signature: Equatable {
        let startSeconds: Int
        let startMicroseconds: Int32
        /// Set by the first exec after a fork.
        let hasExeced: Bool
        /// The command name, which a later exec replaces. An exec into another executable with
        /// the same name is not detected and keeps the earlier path for the rest of the window.
        let name: UInt64
        let nameTail: UInt64
    }
    private var signatures: [Int32: Signature] = [:]
    private static let execFlag: Int32 = 0x4000 // P_EXEC in <sys/proc.h>

    /// One sysctl reads the whole process table. Only processes that are new or have changed
    /// since the previous capture cost further calls, so repeated captures within a window stay
    /// cheap however many processes are running.
    mutating func capture() {
        let table = Self.processTable()
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        for process in table {
            let pid = process.kp_proc.p_pid
            guard pid > 1 else { continue }
            let signature = Self.signature(process)
            if signatures[pid] == signature, entries[pid] != nil { continue }
            signatures[pid] = signature

            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            let started = info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
            // Executable paths are needed again after exec, even when PID/start time are unchanged.
            path[0] = 0
            let length = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
            // A PID can exit and be reused between the metadata and path reads.
            var confirmed = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &confirmed, size) == size,
                  confirmed.pbi_start_tvsec == info.pbi_start_tvsec,
                  confirmed.pbi_start_tvusec == info.pbi_start_tvusec else { continue }
            record(pid: pid, entry: Entry(parent: Int32(info.pbi_ppid), started: started,
                                         path: length > 0 ? String(cString: path) : nil))
        }
    }

    private static func signature(_ process: kinfo_proc) -> Signature {
        let start = process.kp_proc.p_un.__p_starttime
        let name = withUnsafeBytes(of: process.kp_proc.p_comm) { bytes in
            (bytes.loadUnaligned(fromByteOffset: 0, as: UInt64.self),
             bytes.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
        }
        return Signature(startSeconds: start.tv_sec, startMicroseconds: start.tv_usec,
                         hasExeced: process.kp_proc.p_flag & execFlag != 0,
                         name: name.0, nameTail: name.1)
    }

    /// Every process, retrying when the table grows between the size query and the read.
    private static func processTable() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let stride = MemoryLayout<kinfo_proc>.stride
        for _ in 0..<4 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
            var table = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 64)
            var actualSize = table.count * stride
            let result = table.withUnsafeMutableBytes { sysctl(&mib, u_int(mib.count), $0.baseAddress, &actualSize, nil, 0) }
            if result == 0 {
                table.removeLast(table.count - min(table.count, actualSize / stride))
                return table
            }
            guard errno == ENOMEM else { return [] }
        }
        return []
    }
}

/// Explicit bundle aliases only; names never serve as aggregation keys.
enum AppMenuNames {
    private static let aliases = [
        "com.google.Chrome": "Chrome", "org.mozilla.firefox": "Firefox",
        "com.microsoft.edgemac": "Edge", "com.microsoft.VSCode": "VS Code",
        "com.microsoft.teams": "Teams", "com.microsoft.teams2": "Teams",
        "com.microsoft.Outlook": "Outlook", "com.microsoft.Word": "Word",
        "com.microsoft.Excel": "Excel", "com.microsoft.Powerpoint": "PowerPoint",
        "us.zoom.xos": "Zoom", "com.googlecode.iterm2": "iTerm",
        "com.docker.docker": "Docker",
    ]

    static func shortName(bundleID: String?, fallback: String) -> String {
        return bundleID.flatMap { aliases[$0] } ?? fallback
    }
}
