import AVFoundation
import Foundation
import Testing
@testable import Wingman

private func tempFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wingman-safety-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func tone(_ count: Int, _ value: Float = 0.25) -> [Float] { (0..<count).map { value * Float(sin(Double($0) * 0.05)) } }

/// How many frames AVAudioFile — what players and the mixer use — sees.
private func frames(_ url: URL) throws -> AVAudioFramePosition { try AVAudioFile(forReading: url).length }

@Suite struct TrackWriterTests {
    @Test func aTrackPlaysWhileStillBeingWritten() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("t-me.wav")
        let writer = try TrackWriter(url: url) { _ in }
        // 5 s of audio, never finished: like a recording when Wingman is killed.
        for _ in 0..<50 { writer.append(tone(1_600)) }
        let midway = folder.appendingPathComponent("copy.wav")
        _ = writer.finishCopyForTesting(to: midway)
        // The header was last updated at a 2 s boundary: at least 4 s readable, minus the 0.5 s held back.
        #expect(try frames(midway) >= 4 * 16_000)
        #expect(writer.finish() == 80_000)
        #expect(try frames(url) == 80_000)
    }

    @Test func redactSilencesOnlyTheHeldBackTail() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("t-me.wav")
        let writer = try TrackWriter(url: url) { _ in }
        writer.append(tone(32_000, 0.5))
        writer.redact(seconds: 0.25)
        writer.finish()
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32_000)!
        try file.read(into: buffer)
        let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        #expect(samples.suffix(4_000).allSatisfy { $0 == 0 })
        #expect(samples.prefix(24_000).contains { $0 != 0 })
    }

    @Test func aWriteProblemIsReportedOnce() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("t.wav")
        let problems = Counter()
        let writer = try TrackWriter(url: url) { _ in problems.add() }
        writer.closeHandleForTesting()
        for _ in 0..<5 { writer.append(tone(16_000)) }
        writer.finish()
        #expect(problems.value == 1)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@Suite struct WAVRepairTests {
    @Test func repairsATrackThat08LeftUnfinished() throws {
        // 0.8.1 wrote tracks with AVAudioFile, which only writes the sizes on close:
        // a copy taken while it's open is what a force quit leaves.
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("open.wav")
        let leftover = folder.appendingPathComponent("left-them.wav")
        do {
            let file = try AVAudioFile(forWriting: url, settings: Resampler.outputFormat.settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: Resampler.outputFormat, frameCapacity: 48_000)!
            buffer.frameLength = 48_000
            for i in 0..<48_000 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.05)) * 0.2 }
            try file.write(from: buffer)
            try FileManager.default.copyItem(at: url, to: leftover)
        }
        #expect(RecordingRecovery.needsRepair(leftover))
        let result = try #require(try WAVRepair.repair(leftover))
        #expect(result.repaired)
        #expect(abs(result.seconds - 3) < 0.1)
        #expect(try frames(leftover) >= 47_000)
        #expect(!RecordingRecovery.needsRepair(leftover))
        // A finished file is left alone.
        #expect(try WAVRepair.repair(url)?.repaired == false)
    }

    @Test func repairsOurOwnTrackCutMidWrite() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("t-me.wav")
        let writer = try TrackWriter(url: url) { _ in }
        writer.append(tone(40_000))
        writer.finish()
        // Cut off mid-sample, with the header still claiming the full length.
        let handle = try FileHandle(forUpdating: url)
        try handle.truncate(atOffset: UInt64(WAVFormat.headerSize + 30_001 * 4 + 2))
        try handle.close()
        #expect(try WAVRepair.repair(url)?.repaired == true)
        #expect(try frames(url) == 30_001)
    }

    @Test func notAWAVIsntTouched() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("x.wav")
        try Data("not audio at all".utf8).write(to: url)
        #expect(try WAVRepair.repair(url) == nil)
        #expect(try Data(contentsOf: url) == Data("not audio at all".utf8))
    }
}

@Suite struct RecordingRecoveryTests {
    private func interrupted(in folder: URL, kept: Bool, keepAudio: Bool = true) throws -> RecordingRecovery.Record {
        let day = folder.appendingPathComponent("notes/2026-10-12")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let note = day.appendingPathComponent("2026-10-12_01_Sync.md")
        try Data("# Sync\n".utf8).write(to: note)
        let place = kept ? day : folder
        var tracks: [URL] = []
        for side in ["me", "them"] {
            let url = place.appendingPathComponent(kept ? "2026-10-12_01_Sync-\(side).wav" : "wingman-x-\(side).wav")
            let writer = try TrackWriter(url: url) { _ in }
            // In small pieces, as audio arrives: the header lags behind the data.
            for _ in 0..<30 { writer.append(tone(1_600)) }
            _ = writer.finishCopyForTesting(to: url.appendingPathExtension("tmp"))
            writer.finish()
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: url.appendingPathExtension("tmp"), to: url)  // the killed state
            tracks.append(url)
        }
        return RecordingRecovery.Record(note: note, tracks: tracks, keepAudio: keepAudio, tracksKept: kept, started: Date())
    }

    @Test func keptTracksBecomeTheMeetingsAudio() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let record = try interrupted(in: folder, kept: true)
        let outcome = RecordingRecovery.finish(record)
        #expect(outcome.combinedSaved)
        #expect(outcome.seconds > 2)
        let day = record.note.deletingLastPathComponent()
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: day.path))
        #expect(names == ["2026-10-12_01_Sync.md", "2026-10-12_01_Sync.m4a", "2026-10-12_01_Sync-me.m4a", "2026-10-12_01_Sync-them.m4a"])
        #expect(try String(contentsOf: record.note, encoding: .utf8) == "# Sync\n")
    }

    @Test func scratchTracksMakeTheCombinedAudioThenGo() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let record = try interrupted(in: folder, kept: false)
        #expect(RecordingRecovery.finish(record).combinedSaved)
        #expect(record.tracks.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(FileManager.default.fileExists(atPath: record.note.deletingPathExtension().appendingPathExtension("m4a").path))
    }

    @Test func withoutSavedAudioScratchTracksJustGo() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let record = try interrupted(in: folder, kept: false, keepAudio: false)
        #expect(!RecordingRecovery.finish(record).combinedSaved)
        #expect(record.tracks.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(!FileManager.default.fileExists(atPath: record.note.deletingPathExtension().appendingPathExtension("m4a").path))
    }

    @Test func ifMixingFailsTheTracksStayNextToTheNote() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let record = try interrupted(in: folder, kept: false)
        let outcome = RecordingRecovery.finish(record) { _, _ in throw CocoaError(.fileWriteUnknown) }
        #expect(!outcome.combinedSaved)
        let day = record.note.deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: day.appendingPathComponent("2026-10-12_01_Sync-me.wav").path))
        #expect(FileManager.default.fileExists(atPath: day.appendingPathComponent("2026-10-12_01_Sync-them.wav").path))
    }

    @Test func recordsAndOrphansAreFound() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let record = try interrupted(in: folder, kept: true)
        RecordingRecovery.save(record, id: UUID(), in: folder)
        #expect(RecordingRecovery.leftovers(in: folder).map(\.record) == [record])
        let orphans = RecordingRecovery.orphanedTracks(in: folder.appendingPathComponent("notes"),
                                                       now: Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 12))!)
        #expect(orphans.count == 1)
        #expect(orphans.first?.note == record.note)
        #expect(orphans.first?.tracks.count == 2)
    }
}

@Suite struct WatchdogTests {
    @Test func reportsAt5_10_30_60ThenEveryMinute() {
        var last = 0.0, times: [Double] = []
        for _ in 0..<6 {
            last = MainThreadWatchdog.nextReport(after: last)
            times.append(last)
        }
        #expect(times == [5, 10, 30, 60, 120, 180])
    }
}

@Suite struct LeftoverScratchTests {
    /// Recovery runs in the background: a meeting recorded meanwhile has its
    /// scratch tracks and record in the same folder, and must keep them.
    @Test func onlyAnEarlierSessionsUnusedFilesGo() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("wingman-scratch-test-\(UUID().uuidString)")
        let scratch = root.appendingPathComponent("Recording")
        let temporary = root.appendingPathComponent("tmp")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let launched = Date()
        let earlier = launched.addingTimeInterval(-600)
        func file(_ folder: URL, _ name: String, modified: Date) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            return url
        }
        let oldTrack = try file(scratch, "wingman-a-me.wav", modified: earlier)
        let oldRecord = try file(scratch, "recording-a.json", modified: earlier)
        let oldInUse = try file(scratch, "wingman-b-them.wav", modified: earlier)
        _ = try file(scratch, "wingman-c-me.wav", modified: launched.addingTimeInterval(5))
        _ = try file(scratch, "recording-c.json", modified: launched.addingTimeInterval(5))
        let oldTemp = try file(temporary, "wingman-import-x.wav", modified: earlier)
        _ = try file(temporary, "someone-else.wav", modified: earlier)
        let found = Recorder.leftoverScratch(in: scratch, temporary: temporary, olderThan: launched,
                                             inUse: [oldInUse.standardizedFileURL])
        #expect(Set(found.map(\.lastPathComponent)) == Set([oldTrack, oldRecord, oldTemp].map(\.lastPathComponent)))
    }
}
