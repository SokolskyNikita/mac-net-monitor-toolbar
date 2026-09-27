import Foundation
import Dispatch
import Testing
@testable import NetMenu

private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StatsLogTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

private func contents(of url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
}

private func write(_ text: String, to url: URL) throws {
    try Data(text.utf8).write(to: url)
}

@Suite struct StatsLogTests {
    @Test func appendsUtf8LinesAndAllowsTheExactByteLimit() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("stats.jsonl")
            let log = StatsLog(maxBytes: 7, retainedBytes: 6, chunkSize: 2)

            try log.append("é", to: url) // 2 UTF-8 bytes plus LF
            try log.append("abc", to: url) // Reaches exactly 7 bytes.

            #expect(try Data(contentsOf: url) == Data("é\nabc\n".utf8))
            #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int == 7)
        }
    }

    @Test func ordinaryAppendsUseTheExistingFileWhileThereIsHeadroom() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("stats.jsonl")
            let log = StatsLog(maxBytes: 64, retainedBytes: 32, chunkSize: 3)

            try log.append("first", to: url)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let originalFileNumber = attributes[.systemFileNumber] as? NSNumber
            #expect(originalFileNumber != nil)

            try log.append("second", to: url)
            try log.append("third", to: url)

            let finalFileNumber = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
            #expect(finalFileNumber?.uint64Value == originalFileNumber?.uint64Value)
            #expect(try contents(of: url) == "first\nsecond\nthird\n")
        }
    }

    @Test func overflowingAppendKeepsNewestWholeOldLinesBeforeTheNewEntry() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("stats.jsonl")
            try write("a\nbb\nccc\n", to: url)
            let log = StatsLog(maxBytes: 12, retainedBytes: 8, chunkSize: 2)

            try log.append("ddd", to: url)

            #expect(try contents(of: url) == "ccc\nddd\n")
            #expect(try Data(contentsOf: url).count == 8)
        }
    }

    @Test func trimsAnOversizedExistingFileToTheNewestWholeLines() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("stats.jsonl")
            try write("old\nmid\nnew\nlast\n", to: url)
            let log = StatsLog(maxBytes: 14, retainedBytes: 9, chunkSize: 3)

            try log.trimIfNeeded(at: url)

            #expect(try contents(of: url) == "new\nlast\n")
            #expect(try Data(contentsOf: url).count == 9)
        }
    }

    @Test func skipsAPartialLeadingEntryAcrossSeveralChunks() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("stats.jsonl")
            try write("1234567890\nkeep\nlast\n", to: url)
            let log = StatsLog(maxBytes: 20, retainedBytes: 14, chunkSize: 2)

            try log.trimIfNeeded(at: url)

            #expect(try contents(of: url) == "keep\nlast\n")
        }
    }

    @Test func keepsANewEntryLargerThanTheRetentionTargetWhole() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("stats.jsonl")
            try write("old\n", to: url)
            let log = StatsLog(maxBytes: 12, retainedBytes: 8, chunkSize: 2)

            try log.append("12345678901", to: url)

            #expect(try contents(of: url) == "12345678901\n")
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["stats.jsonl"])
        }
    }

    @Test func compactionLeavesHeadroomForOrdinaryAppends() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("stats.jsonl")
            try write("a\nbb\nccc\n", to: url)
            let log = StatsLog(maxBytes: 12, retainedBytes: 8, chunkSize: 2)
            try log.append("ddd", to: url)
            let fileNumber = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber

            try log.append("ee", to: url)

            #expect(try contents(of: url) == "ccc\nddd\nee\n")
            let after = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
            #expect(after == fileNumber)
        }
    }

    @Test func streamingTrimHandlesChunkSplitsInsideUtf8AndLineTerminators() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("stats.jsonl")
            // Two-byte chunks split both multi-byte scalars and the LF delimiters.
            try write("old\néé\n🌊\n終\npartial", to: url)
            let log = StatsLog(maxBytes: 14, retainedBytes: 9, chunkSize: 2)

            try log.trimIfNeeded(at: url)

            #expect(try contents(of: url) == "🌊\n終\n")
            #expect(try Data(contentsOf: url).count == 9)
        }
    }

    @Test func trimLeavesMissingAndWithinLimitFilesAlone() throws {
        try withTemporaryDirectory { directory in
            let missingURL = directory.appendingPathComponent("missing.jsonl")
            let existingURL = directory.appendingPathComponent("small.jsonl")
            try write("small\n", to: existingURL)
            let log = StatsLog(maxBytes: 16, retainedBytes: 8, chunkSize: 2)

            try log.trimIfNeeded(at: missingURL)
            try log.trimIfNeeded(at: existingURL)

            #expect(!FileManager.default.fileExists(atPath: missingURL.path))
            #expect(try contents(of: existingURL) == "small\n")
        }
    }

    @Test func appendRepairsAnUnterminatedTailAndKeepsEarlierCompleteLines() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("stats.jsonl")
            try write("one\ntwo\npartial-tail", to: url)
            let log = StatsLog(maxBytes: 64, retainedBytes: 48, chunkSize: 3)

            try log.append("three", to: url)

            #expect(try contents(of: url) == "one\ntwo\nthree\n")
        }
    }

    @Test func oversizedOrMalformedEntriesFailWithoutChangingTheFile() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("stats.jsonl")
            try write("keep\n", to: url)
            let log = StatsLog(maxBytes: 8, retainedBytes: 6, chunkSize: 2)

            #expect(throws: (any Error).self) { try log.append("12345678", to: url) }
            #expect(throws: (any Error).self) { try log.append("two\nlines", to: url) }
            #expect(throws: (any Error).self) { try log.append("carriage\rreturn", to: url) }

            #expect(try contents(of: url) == "keep\n")
        }
    }

    @Test func concurrentAppendsToOneInstanceKeepEveryEntryWhole() throws {
        try withTemporaryDirectory { directory in
            let url = directory
                .appendingPathComponent("created", isDirectory: true)
                .appendingPathComponent("stats.jsonl")
            let log = StatsLog(maxBytes: 8_192, retainedBytes: 6_144, chunkSize: 7)
            let entryCount = 160
            let failureLock = NSLock()
            var failureCount = 0

            DispatchQueue.concurrentPerform(iterations: entryCount) { index in
                do {
                    try log.append("entry-\(index)", to: url)
                } catch {
                    failureLock.lock()
                    failureCount += 1
                    failureLock.unlock()
                }
            }

            let lines = try contents(of: url).split(separator: "\n").map(String.init)
            let expected = Set((0..<entryCount).map { "entry-\($0)" })
            #expect(failureCount == 0)
            #expect(lines.count == entryCount)
            #expect(Set(lines) == expected)
        }
    }
}
