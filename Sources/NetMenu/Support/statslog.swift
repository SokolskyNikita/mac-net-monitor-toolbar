import Darwin
import Foundation

/// A bounded JSONL log. Ordinary appends do constant filesystem work; compaction reads only
/// the retained tail in bounded chunks and atomically replaces the original file.
final class StatsLog {
    static let maxBytes = 100_000_000

    enum LogError: Error {
        case invalidEntry
        case entryTooLarge
        case unexpectedEOF
    }

    private let limit: UInt64
    private let retainedBytes: UInt64
    private let chunkSize: Int
    private let lock = NSLock()

    init(maxBytes: Int = StatsLog.maxBytes, retainedBytes: Int? = nil, chunkSize: Int = 64 * 1024) {
        let retained = retainedBytes ?? (maxBytes - maxBytes / 10)
        precondition(maxBytes > 0 && retained > 0 && retained <= maxBytes && chunkSize > 0)
        limit = UInt64(maxBytes)
        self.retainedBytes = UInt64(retained)
        self.chunkSize = chunkSize
    }

    /// Accepts one serialized JSON object without a newline. File work is synchronous; callers
    /// should use a background queue. The lock serializes appends and trimming on this instance.
    func append(_ line: String, to url: URL) throws {
        guard !line.contains("\n"), !line.contains("\r") else { throw LogError.invalidEntry }
        guard UInt64(line.utf8.count) < limit else { throw LogError.entryTooLarge }
        var entry = Data(line.utf8)
        entry.append(0x0a)

        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let input = try openFile(url, flags: O_RDWR | O_CREAT | O_APPEND)
        defer { try? input.close() }
        let size = try input.seekToEnd()
        let overLimit = size > limit - UInt64(entry.count)
        var incompleteTail = false
        if size > 0 {
            try input.seek(toOffset: size - 1)
            incompleteTail = try input.read(upToCount: 1)?.first != 0x0a
        }

        if overLimit || incompleteTail {
            // Repair a previously interrupted final write without dropping valid old entries
            // unless the cap also requires it. A new entry larger than the target is kept alone.
            try compact(input, size: size, to: url, appending: entry,
                        target: overLimit ? retainedBytes : limit)
        } else {
            do {
                try writeAll(entry, to: input)
            } catch {
                // A short write followed by an error must not leave a partial JSON record.
                try? input.truncate(atOffset: size)
                throw error
            }
        }
    }

    /// Enforce the cap for an existing log at launch, without creating a missing log.
    func trimIfNeeded(at url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return }
            throw posixError()
        }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        let size = try input.seekToEnd()
        guard size > limit else { return }
        try compact(input, size: size, to: url, appending: Data(), target: retainedBytes)
    }

    private func compact(_ input: FileHandle, size: UInt64, to url: URL,
                         appending entry: Data, target: UInt64) throws {
        let oldBudget = target > UInt64(entry.count) ? target - UInt64(entry.count) : 0
        let end = oldBudget > 0 ? try completeLineEnd(input, size: size) : 0
        let start = end > oldBudget ? end - oldBudget : 0
        var skipPartialLine = false
        if start > 0, start < end {
            try input.seek(toOffset: start - 1)
            skipPartialLine = try input.read(upToCount: 1)?.first != 0x0a
        }
        try input.seek(toOffset: start)

        let temporary = url.deletingLastPathComponent().appendingPathComponent(".stats-\(UUID().uuidString).tmp")
        let output = try openFile(temporary, flags: O_WRONLY | O_CREAT | O_EXCL)
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: temporary)
        }

        var remaining = end - start
        while remaining > 0 {
            // FileHandle's NSData buffers are autoreleased on macOS. Drain each chunk so
            // they cannot accumulate to the full retained size on a long-running queue item.
            try autoreleasepool {
                let count = Int(min(UInt64(chunkSize), remaining))
                guard var chunk = try input.read(upToCount: count), !chunk.isEmpty else { throw LogError.unexpectedEOF }
                remaining -= UInt64(chunk.count)
                if skipPartialLine {
                    guard let newline = chunk.firstIndex(of: 0x0a) else { return }
                    chunk = chunk.subdata(in: (newline + 1)..<chunk.endIndex)
                    skipPartialLine = false
                }
                try writeAll(chunk, to: output)
            }
        }

        try writeAll(entry, to: output)
        try output.synchronize()
        // The temporary file is on the same filesystem: readers see either complete version.
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw posixError() }
    }

    /// Normally one byte suffices. Only an interrupted final write requires a backward scan,
    /// so incomplete bytes do not consume the retention budget for valid older records.
    private func completeLineEnd(_ input: FileHandle, size: UInt64) throws -> UInt64 {
        guard size > 0 else { return 0 }
        try input.seek(toOffset: size - 1)
        if try input.read(upToCount: 1)?.first == 0x0a { return size }
        var end = size
        while end > 0 {
            let count = Int(min(UInt64(chunkSize), end))
            let start = end - UInt64(count)
            try input.seek(toOffset: start)
            let completeEnd: UInt64? = try autoreleasepool {
                var chunk = Data()
                chunk.reserveCapacity(count)
                while chunk.count < count {
                    guard let part = try input.read(upToCount: count - chunk.count), !part.isEmpty else {
                        throw LogError.unexpectedEOF
                    }
                    chunk.append(part)
                }
                if let newline = chunk.lastIndex(of: 0x0a) {
                    return start + UInt64(chunk.distance(from: chunk.startIndex, to: newline) + 1)
                }
                return nil
            }
            if let completeEnd { return completeEnd }
            end = start
        }
        return 0
    }

    private func openFile(_ url: URL, flags: Int32) throws -> FileHandle {
        let descriptor = Darwin.open(url.path, flags | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw posixError() }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private func writeAll(_ data: Data, to file: FileHandle) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(file.fileDescriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                guard count > 0 else { throw posixError(EIO) }
                offset += count
            }
        }
    }

    private func posixError(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
