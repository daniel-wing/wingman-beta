import Foundation
import Testing
@testable import Wingman

@MainActor
@Suite struct MeetingIndexTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wingman-index-\(UUID().uuidString)")
    private let day: TimeInterval = 86_400

    private func meeting(started: Date?, key: String = "2026-10-07/2026-10-07_01_Sync") -> MeetingIndex.Meeting {
        var meeting = MeetingIndex.Meeting(id: UUID(), key: key)
        meeting.started = started
        meeting.speakers = [MeetingIndex.Speaker(id: UUID(), label: "Them 1", lines: [.init(start: 3, ordinal: 0)])]
        return meeting
    }

    private let voice = MeetingIndex.Voice(embedding: [0.1, 0.2], model: VoiceLibrary.currentModel)

    @Test func keepsVoicesAndReadsThemBack() {
        let index = MeetingIndex(folder: folder)
        let entry = meeting(started: Date())
        #expect(index.save(entry))
        #expect(index.keepVoices([entry.speakers[0].id: voice], for: entry.id))
        let again = MeetingIndex(folder: folder)
        #expect(again.meeting(id: entry.id)?.voiceState == .stored)
        #expect(again.voices(for: entry)[entry.speakers[0].id] == voice)
    }

    @Test func aReusedNoteNumberReplacesTheOldEntry() {
        // A note removed in Finder leaves its entry; the next meeting that day
        // can get the same number, so the same key.
        let index = MeetingIndex(folder: folder)
        let old = meeting(started: Date().addingTimeInterval(-3_600))
        #expect(index.save(old))
        #expect(index.keepVoices([old.speakers[0].id: voice], for: old.id))
        let new = meeting(started: Date())
        #expect(index.save(new))
        let again = MeetingIndex(folder: folder)
        #expect(again.meeting(key: new.key)?.id == new.id)
        #expect(again.meeting(id: old.id) == nil)
        #expect(again.voices(for: old).isEmpty)
    }

    @Test func voicesExpire180DaysAfterTheMeetingWhileRunning() {
        let index = MeetingIndex(folder: folder)
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let entry = meeting(started: started)
        index.save(entry)
        index.keepVoices([entry.speakers[0].id: voice], for: entry.id, now: started)
        #expect(!index.voices(for: entry, now: started.addingTimeInterval(179 * day)).isEmpty)
        // No relaunch needed: reading (or the hourly check) deletes them.
        #expect(index.voices(for: entry, now: started.addingTimeInterval(181 * day)).isEmpty)
        #expect(index.meeting(id: entry.id)?.voiceState == .expired)
        #expect(MeetingIndex(folder: folder).voices(for: entry, now: started).isEmpty)
        // An expired meeting's voices are never kept again.
        #expect(!index.keepVoices([entry.speakers[0].id: voice], for: entry.id, now: started.addingTimeInterval(181 * day)))
    }

    @Test func withoutAStartTimeTheDayEndCounts() throws {
        let entry = meeting(started: nil, key: "2026-10-07/13-31 Sync")
        let end = try #require(MeetingIndex.endOfDay(entry.key))
        let components = Calendar.current.dateComponents([.day, .hour, .minute], from: end)
        #expect(components.day == 7 && components.hour == 23 && components.minute == 59)
        #expect(MeetingIndex.voicesExpire(entry) == Calendar.current.date(byAdding: .day, value: 180, to: end))
    }

    @Test func deletedVoicesNeverComeBack() {
        let index = MeetingIndex(folder: folder)
        let entry = meeting(started: Date())
        index.save(entry)
        index.keepVoices([entry.speakers[0].id: voice], for: entry.id)
        let generation = index.meeting(id: entry.id)!.generation
        #expect(index.deleteVoices(of: entry.id))
        let deleted = index.meeting(id: entry.id)!
        #expect(deleted.voiceState == .deleted)
        #expect(deleted.generation == generation + 1)
        #expect(index.voices(for: entry).isEmpty)
        #expect(!index.mayKeepVoices(deleted))
        #expect(!index.keepVoices([entry.speakers[0].id: voice], for: entry.id))
        #expect(MeetingIndex(folder: folder).meeting(id: entry.id)?.voiceState == .deleted)
    }

    @Test func deleteAllAndRecognitionOffCoverOlderMeetingsWithoutAnEntry() {
        let index = MeetingIndex(folder: folder)
        let now = Date()
        let kept = meeting(started: now.addingTimeInterval(-day))
        index.save(kept)
        index.keepVoices([kept.speakers[0].id: voice], for: kept.id)
        #expect(index.deleteAllVoices(because: .notAllowed, now: now))
        #expect(index.meetingsWithVoices.isEmpty)
        #expect(index.meeting(id: kept.id)?.voiceState == .notAllowed)
        // A note Wingman has never seen, from before: still off limits.
        let unseen = meeting(started: now.addingTimeInterval(-2 * day))
        #expect(!index.mayKeepVoices(unseen, now: now))
        // A meeting recorded after recognition was turned back on is fine.
        let later = meeting(started: now.addingTimeInterval(60))
        #expect(index.mayKeepVoices(later, now: now.addingTimeInterval(120)))

        #expect(index.deleteAllVoices(because: .deleted, now: now.addingTimeInterval(200)))
        #expect(!index.mayKeepVoices(later, now: now.addingTimeInterval(300)))
        #expect(MeetingIndex(folder: folder).voicesDeletedBefore != nil)
    }

    @Test func aFileFromANewerWingmanIsLeftAlone() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("meetings.json")
        let newer = Data(#"{"version": 2, "meetings": [], "jobs": [], "somethingNew": true}"#.utf8)
        try newer.write(to: file)
        let index = MeetingIndex(folder: folder)
        #expect(index.readOnly)
        #expect(!index.save(meeting(started: Date())))
        #expect(try Data(contentsOf: file) == newer)
    }

    @Test func nothingChangesWhenItCantBeSaved() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        let index = MeetingIndex(folder: folder)
        let entry = meeting(started: Date())
        index.save(entry)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        #expect(!index.deleteVoices(of: entry.id))
        #expect(index.meeting(id: entry.id)?.voiceState == MeetingIndex.VoiceState.none)
        #expect(index.problem != nil)
    }

    @Test func anOldNoteGetsOneSpeakerPerName() {
        let note = MeetingNote.parse(Data("""
        **Date:** today
        ## Transcript
        [00:00:01] **Them 1:** a
        [00:00:01] **Me:** b
        [00:00:01] **Them 1:** c
        [00:00:05] **Ana:** d
        """.utf8))
        let index = MeetingIndex(folder: folder)
        let entry = index.entry(forKey: "2026-10-07/13-31 Sync", note: note)
        #expect(entry.speakers.map(\.label) == ["Them 1", "Ana"])
        #expect(entry.speakers[0].lines == [.init(start: 1, ordinal: 0), .init(start: 1, ordinal: 2)])
        #expect(entry.voiceState == .none)
    }

    @Test func renameJobsPersistUntilFinished() {
        let index = MeetingIndex(folder: folder)
        var job = MeetingIndex.RenameJob(id: UUID(), meeting: UUID(), from: "Them 1", to: "Ana")
        job.done = [.note]
        index.save(job)
        #expect(MeetingIndex(folder: folder).jobs == [job])
        index.finish(job)
        #expect(MeetingIndex(folder: folder).jobs.isEmpty)
    }
}
