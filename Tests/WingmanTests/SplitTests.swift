import AVFoundation
import Foundation
import Testing
@testable import Wingman

@Suite struct WriterSlotTests {
    private func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    @Test func aSplitMovesAudioToTheNewFileWithoutLosingAny() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wingman-slot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = try TrackWriter(url: folder.appendingPathComponent("a.wav")) { _ in }
        let b = try TrackWriter(url: folder.appendingPathComponent("b.wav")) { _ in }
        let slot = WriterSlot()
        slot.swap(a)
        slot.append([Float](repeating: 0.1, count: 16_000))
        let old = slot.swap(b)
        slot.append([Float](repeating: 0.2, count: 16_000))
        #expect(slot.appended == 32_000)
        old?.finish()
        b.finish()
        #expect(try samples(folder.appendingPathComponent("a.wav")) == [Float](repeating: 0.1, count: 16_000))
        #expect(try samples(folder.appendingPathComponent("b.wav")) == [Float](repeating: 0.2, count: 16_000))
    }

    @Test func joiningPutsTheNewAudioBackInOrder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wingman-slot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = try TrackWriter(url: folder.appendingPathComponent("a.wav")) { _ in }
        let b = try TrackWriter(url: folder.appendingPathComponent("b.wav")) { _ in }
        let slot = WriterSlot()
        slot.swap(a)
        slot.append([Float](repeating: 0.1, count: 16_000))
        let old = slot.swap(b)!
        slot.append([Float](repeating: 0.2, count: 16_000))
        let result = Box<(Bool, URL?)>()
        slot.rejoin(old) { result.set(($0, $1)) }
        slot.append([Float](repeating: 0.3, count: 8_000))
        a.finish()
        #expect(result.value?.0 == true)
        #expect(result.value?.1?.lastPathComponent == "b.wav")
        let joined = try samples(folder.appendingPathComponent("a.wav"))
        #expect(joined.count == 40_000)
        #expect(joined[..<16_000].allSatisfy { $0 == 0.1 })
        #expect(joined[16_000..<32_000].allSatisfy { $0 == 0.2 })
        #expect(joined[32_000...].allSatisfy { $0 == 0.3 })
    }

    /// The source is read on the writer's queue after `rejoin` returns: if the
    /// read fails or is short, the join reports failure (so the caller keeps
    /// the file) and the old track still gets the live audio that follows.
    @Test func aFailedOrShortReadIsReportedAndNothingIsLost() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wingman-slot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for failure in ["missing", "short"] {
            let a = try TrackWriter(url: folder.appendingPathComponent("a-\(failure).wav")) { _ in }
            let b = try TrackWriter(url: folder.appendingPathComponent("b-\(failure).wav")) { _ in }
            let slot = WriterSlot()
            slot.swap(a)
            slot.append([Float](repeating: 0.1, count: 16_000))
            let old = slot.swap(b)!
            slot.append([Float](repeating: 0.2, count: 16_000))
            let result = Box<(Bool, URL?)>()
            let read: @Sendable (URL) throws -> Data = { url in
                if failure == "missing" { throw CocoaError(.fileNoSuchFile) }
                return try Data(contentsOf: url).dropLast(400)
            }
            slot.rejoin(old, read: read) { result.set(($0, $1)) }
            slot.append([Float](repeating: 0.3, count: 8_000))
            a.finish()
            #expect(result.value?.0 == false)
            // The source is still there for the caller to keep.
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("b-\(failure).wav").path))
            #expect(try samples(folder.appendingPathComponent("b-\(failure).wav")).count == 16_000)
            let joined = try samples(folder.appendingPathComponent("a-\(failure).wav"))
            #expect(joined.count == 24_000)
            #expect(joined[16_000...].allSatisfy { $0 == 0.3 })
        }
    }

    @Test func aTrackAJoinCouldntAppendIsKeptBesideTheNote() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wingman-slot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let note = folder.appendingPathComponent("2026-10-14_03_Sync.md")
        let scratch = folder.appendingPathComponent("wingman-x-them.wav")
        for _ in 0..<2 {
            try Data("x".utf8).write(to: scratch)
            _ = Recorder.keepJoinLeftover(scratch, speaker: .them, beside: note)
        }
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        #expect(names == ["2026-10-14_03_Sync-joined-them.wav", "2026-10-14_03_Sync-joined-them 2.wav"])
    }
}

/// A value set from another thread (a completion handler) and read after.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    func set(_ value: T) { lock.lock(); stored = value; lock.unlock() }
    var value: T? { lock.lock(); defer { lock.unlock() }; return stored }
}

@MainActor
@Suite struct MeetingLinesTests {
    private func meeting(_ recorder: Recorder, in folder: URL) -> Meeting {
        Meeting(recorder: recorder, stage: .recording, origin: 0, started: Date(), name: "Test", event: nil,
                nameFromCalendar: false, base: folder.appendingPathComponent("test"), prefix: "test", tracksKept: false,
                meAudio: nil, themAudio: nil, sourceFile: "test")
    }

    @Test func linesMoveBetweenMeetingsInOrder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wingman-lines-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = Recorder()
        let first = meeting(recorder, in: folder)
        let lines = (0..<6).map { TranscriptLine(id: UUID(), speaker: $0 % 2 == 0 ? .me : .them, start: Double($0) * 10,
                                                 end: Double($0) * 10 + 5, text: "line \($0)", isFinal: true) }
        first.replaceLines(lines)
        let moved = first.release(from: 30)
        #expect(moved.map(\.text) == ["line 3", "line 4", "line 5"])
        #expect(first.lines.map(\.text) == ["line 0", "line 1", "line 2"])
        first.adopt(moved.reversed())
        #expect(first.lines.map(\.text) == lines.map(\.text))
        withExtendedLifetime(recorder) {}
    }

    @Test func durationEndsWhenTheMeetingStoppedTakingAudio() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wingman-lines-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = Recorder()
        let first = meeting(recorder, in: folder)
        let started = try #require(first.startedAt)
        // Split 3 min in; it finishes a minute later (the join window).
        first.setEnded(started.addingTimeInterval(185))
        #expect(first.noteText()?.contains("**Duration:** 3 min") == true)
        first.setEnded(nil)
        #expect(first.noteText()?.contains("**Duration:** 0 min") == true)
        withExtendedLifetime(recorder) {}
    }

    @Test func eventsUpdateAPartialLineThenFinalize() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wingman-lines-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = Recorder()
        let m = meeting(recorder, in: folder)
        let id = UUID()
        m.handle(TranscriptEvent(utteranceID: id, speaker: .them, start: 1, end: 2, text: "hel", isFinal: false))
        #expect(m.hasLiveLine)
        m.handle(TranscriptEvent(utteranceID: id, speaker: .them, start: 1, end: 3, text: "hello there", isFinal: true))
        #expect(!m.hasLiveLine)
        #expect(m.lines.map(\.text) == ["hello there"])
        withExtendedLifetime(recorder) {}
    }
}
