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
            if identity.id.hasPrefix("app:") { return identity }
            guard let parent = entries[entry.parent], parent.started <= entry.started else { break }
            current = entry.parent
        }
        return fallback
    }

    mutating func capture() {
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return }
        var pids = [Int32](repeating: 0, count: Int(needed) / MemoryLayout<Int32>.size + 256)
        let bytes = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count)) }
        guard bytes > 0 else { return }
        for pid in pids.prefix(Int(bytes) / MemoryLayout<Int32>.size) where pid > 1 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            let started = info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
            // Executable paths are needed again after exec, even when PID/start time are unchanged.
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
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
}

/// Explicit bundle aliases only; names never serve as aggregation keys.
enum AppMenuNames {
    static func shortName(bundleID: String?, fallback: String) -> String {
        let aliases = [
            "com.google.Chrome": "Chrome", "org.mozilla.firefox": "Firefox",
            "com.microsoft.edgemac": "Edge", "com.microsoft.VSCode": "VS Code",
            "com.microsoft.teams": "Teams", "com.microsoft.teams2": "Teams",
            "com.microsoft.Outlook": "Outlook", "com.microsoft.Word": "Word",
            "com.microsoft.Excel": "Excel", "com.microsoft.Powerpoint": "PowerPoint",
            "us.zoom.xos": "Zoom", "com.googlecode.iterm2": "iTerm",
            "com.docker.docker": "Docker",
        ]
        return bundleID.flatMap { aliases[$0] } ?? fallback
    }
}
