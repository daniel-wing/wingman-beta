import Foundation
import Testing
@testable import Wingman

private struct Injected: Error {}

/// A day folder with one note and its subtitles, plus Wingman's own files, in a
/// temporary folder.
@MainActor
private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("wingman-past-\(UUID().uuidString)")
    let day = Recorder.dayFolderName(for: Date())
    var note: URL { root.appendingPathComponent("notes/\(day)/\(day)_01_Sync.md") }
    var vtt: URL { note.deletingPathExtension().appendingPathExtension("vtt") }
    var srt: URL { note.deletingPathExtension().appendingPathExtension("srt") }
    let index: MeetingIndex
    let voices: VoiceLibrary
    var recognize = true

    static let text = """
    # Sync

    **Date:** Oct 7, 2026 at 1:31 PM
    **Invited:** Carlos Pérez, Ana Ruiz

    ## Transcript

    [00:00:01] **Them 1:** Hello there

    [00:00:04] **Daniel:** Hi

    [00:00:09] **Them 2:** Bye

    """

    init() throws {
        index = MeetingIndex(folder: root.appendingPathComponent("support"))
        voices = VoiceLibrary(file: root.appendingPathComponent("support/voices.json"))
        try FileManager.default.createDirectory(at: note.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Self.text.utf8).write(to: note)
        try Data("WEBVTT - Sync\n\n00:00:01.000 --> 00:00:04.000\n<v Them 1>Hello there\n\n00:00:04.000 --> 00:00:06.000\n<v Daniel>Hi\n\n00:00:09.000 --> 00:00:10.000\n<v Them 2>Bye\n".utf8).write(to: vtt)
        try Data("1\n00:00:01,000 --> 00:00:04,000\nThem 1: Hello there\n\n2\n00:00:04,000 --> 00:00:06,000\nDaniel: Hi\n\n3\n00:00:09,000 --> 00:00:10,000\nThem 2: Bye\n\n".utf8).write(to: srt)
    }

    func open() async throws -> PastMeeting {
        let meeting = try await PastMeeting.open(note, index: index, voices: voices, recognize: { [unowned self] in self.recognize })
        meeting.backups = root.appendingPathComponent("backups")
        return meeting
    }

    func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    func voice(_ seed: Int) -> [Float] { (0..<256).map { Float(sin(Double($0 * (seed + 1)))) } }

    /// Keeps a voice for the speaker shown as `name`, as a 0.9 recording would.
    func keepVoice(for name: String, _ seed: Int, in meeting: PastMeeting) {
        let speaker = meeting.entry.speakers.first { ($0.name ?? $0.label) == name }!
        index.keepVoices([speaker.id: MeetingIndex.Voice(embedding: voice(seed), model: VoiceLibrary.currentModel)], for: meeting.entry.id)
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

@MainActor
@Suite struct PastMeetingTests {
    /// The hash recorded for the note tells an edit made elsewhere (another
    /// app, another Mac) from Wingman's own writes.
    @Test func aNoteChangedElsewhereIsDetected() async throws {
        let f = try Fixture()
        let meeting = try await f.open()
        let original = try Data(contentsOf: f.note)
        #expect(meeting.entry.noteHash == MeetingIndex.hash(original))
        #expect(!meeting.changedElsewhere(original))
        await meeting.rename("Them 1", to: "Carlos Pérez")
        let renamed = try Data(contentsOf: f.note)
        #expect(f.index.meeting(id: meeting.entry.id)?.noteHash == MeetingIndex.hash(renamed))
        #expect(!meeting.changedElsewhere(renamed))
        let edited = Data((f.read(f.note) + "\nA line typed on another Mac.\n").utf8)
        try edited.write(to: f.note)
        #expect(meeting.changedElsewhere(edited))
    }

    @Test func renamesNoteSubtitlesAndIndex() async throws {
        let f = try Fixture()
        let meeting = try await f.open()
        #expect(meeting.tally.toName == ["Them 1", "Them 2"])
        #expect(meeting.suggestions == ["Carlos Pérez", "Ana Ruiz"])
        await meeting.rename("Them 1", to: "Carlos Pérez")
        #expect(meeting.outcome == PastMeeting.Outcome(text: "Name saved.", isError: false, retry: nil))
        #expect(f.read(f.note).contains("[00:00:01] **Carlos Pérez:** Hello there"))
        #expect(f.read(f.vtt).contains("<v Carlos Pérez>Hello there"))
        #expect(f.read(f.srt).contains("\nCarlos Pérez: Hello there\n"))
        #expect(meeting.entry.speakers.first { $0.label == "Them 1" }?.name == "Carlos Pérez")
        #expect(meeting.tally.toName == ["Them 2"])
        #expect(f.index.jobs.isEmpty)
        // A backup of all three, taken first.
        let backups = NoteFile.backups(in: f.root.appendingPathComponent("backups"))
        #expect(backups.count == 1)
        let copied = try FileManager.default.contentsOfDirectory(atPath: backups[0].path)
        #expect(Set(copied).count == 3)
        #expect(try String(contentsOf: backups[0].appendingPathComponent(f.note.lastPathComponent), encoding: .utf8) == Fixture.text)
    }

    @Test func anEditMadeElsewhereIsKept() async throws {
        let f = try Fixture()
        let meeting = try await f.open()
        // Edited in another app after Wingman showed it.
        let edited = Fixture.text.replacingOccurrences(of: "Hello there", with: "Hello there!") + "\n## My notes\nFollow up.\n"
        try Data(edited.utf8).write(to: f.note)
        await meeting.rename("Them 1", to: "Carlos")
        #expect(f.read(f.note) == edited.replacingOccurrences(of: "**Them 1:**", with: "**Carlos:**"))
        // The cue no longer matches the edited line's text, but it still lines up by time and speaker.
        #expect(f.read(f.vtt).contains("<v Carlos>Hello there"))
    }

    @Test func aSpeakerRemovedElsewhereAbortsAndReloads() async throws {
        let f = try Fixture()
        let meeting = try await f.open()
        let edited = Fixture.text.replacingOccurrences(of: "**Them 1:**", with: "**Bea:**")
        try Data(edited.utf8).write(to: f.note)
        await meeting.rename("Them 1", to: "Carlos")
        #expect(meeting.outcome?.isError == true)
        #expect(meeting.outcome?.text.hasPrefix("Not saved") == true)
        #expect(f.read(f.note) == edited)
        #expect(meeting.note.speakers.contains("Bea"))
        #expect(f.index.jobs.isEmpty)
    }

    @Test func noBackupMeansNoChange() async throws {
        let f = try Fixture()
        let meeting = try await f.open()
        meeting.backups = URL(fileURLWithPath: "/dev/null/backups")
        await meeting.rename("Them 1", to: "Carlos")
        #expect(meeting.outcome?.text.hasPrefix("Nothing was changed") == true)
        #expect(f.read(f.note) == Fixture.text)
        #expect(f.index.jobs.isEmpty)
    }

    @Test func failedSubtitlesAreReportedAndRetried() async throws {
        let f = try Fixture()
        let meeting = try await f.open()
        meeting.inject = { step in if step == .subtitles { throw Injected() } }
        await meeting.rename("Them 1", to: "Carlos")
        #expect(f.read(f.note).contains("**Carlos:**"))
        #expect(!f.read(f.vtt).contains("Carlos"))
        let outcome = try #require(meeting.outcome)
        #expect(outcome.isError)
        #expect(outcome.text.hasPrefix("Name saved. The subtitles"))
        let job = try #require(outcome.retry)
        #expect(f.index.jobs.count == 1)

        meeting.inject = nil
        await meeting.resume(job)
        #expect(f.read(f.vtt).contains("<v Carlos>Hello there"))
        #expect(f.read(f.srt).contains("\nCarlos: Hello there\n"))
        #expect(meeting.outcome?.isError == false)
        #expect(f.index.jobs.isEmpty)
        // The note was renamed once, not twice.
        #expect(f.read(f.note).components(separatedBy: "**Carlos:**").count == 2)
    }

    @Test func aJobLeftByAQuitIsFinishedNextTime() async throws {
        let f = try Fixture()
        let first = try await f.open()
        first.inject = { step in if step == .index { throw Injected() } }
        await first.rename("Them 1", to: "Carlos")
        #expect(f.index.jobs.count == 1)

        // Next launch: the job is read back from disk and finished.
        let index = MeetingIndex(folder: f.root.appendingPathComponent("support"))
        let job = try #require(index.jobs.first)
        #expect(job.done.contains(.note))
        let again = try await PastMeeting.open(f.note, index: index, voices: f.voices, recognize: { true })
        again.backups = f.root.appendingPathComponent("backups")
        await again.resume(job)
        #expect(index.jobs.isEmpty)
        #expect(again.entry.speakers.first { $0.label == "Them 1" }?.name == "Carlos")
    }

    @Test func aQuitRightAfterTheNoteWasSavedIsHandled() async throws {
        let f = try Fixture()
        let meeting = try await f.open()
        // The note was swapped, then the app quit before marking the step.
        let them1 = meeting.entry.speakers.first { $0.label == "Them 1" }!.id
        let job = MeetingIndex.RenameJob(id: UUID(), meeting: meeting.entry.id, from: "Them 1", to: "Carlos", speakers: [them1])
        f.index.save(job)
        try NoteRewriter.renameSpeaker(in: Data(contentsOf: f.note), from: "Them 1", to: "Carlos").write(to: f.note)
        let after = try await f.open()
        await after.resume(job)
        #expect(after.outcome?.isError == false)
        #expect(f.read(f.vtt).contains("<v Carlos>Hello there"))
        #expect(f.index.jobs.isEmpty)
    }

    @Test func aKeptVoiceIsLearnedOnceEvenWhenRetried() async throws {
        let f = try Fixture()
        let meeting = try await f.open()
        f.keepVoice(for: "Them 1", 1, in: meeting)
        meeting.inject = { step in if step == .learn { throw Injected() } }
        await meeting.rename("Them 1", to: "Carlos")
        #expect(f.voices.people.isEmpty)
        let job = try #require(meeting.outcome?.retry)
        meeting.inject = nil
        await meeting.resume(job)
        await meeting.resume(job)
        #expect(f.voices.people.map(\.name) == ["Carlos"])
        #expect(f.voices.people[0].meetings == 1)
        // Learned: no longer kept as an unnamed voice.
        #expect(f.index.voices(for: meeting.entry).isEmpty)
    }

    @Test func correctingANameMovesTheVoice() async throws {
        let f = try Fixture()
        let meeting = try await f.open()
        f.keepVoice(for: "Them 1", 1, in: meeting)
        await meeting.rename("Them 1", to: "Carlos")
        await meeting.rename("Carlos", to: "Bruno")
        #expect(f.voices.people.map(\.name) == ["Bruno"])
        #expect(f.voices.people[0].meetings == 1)
    }

    @Test func nothingIsLearnedWhileRecognitionIsOff() async throws {
        let f = try Fixture()
        let meeting = try await f.open()
        f.keepVoice(for: "Them 1", 1, in: meeting)
        f.recognize = false
        await meeting.rename("Them 1", to: "Carlos")
        #expect(f.read(f.note).contains("**Carlos:**"))
        #expect(f.voices.people.isEmpty)
    }

    @Test func mergingTwoSpeakersDoesntPoolDifferentVoices() async throws {
        let f = try Fixture()
        let meeting = try await f.open()
        let them1 = meeting.entry.speakers.first { $0.label == "Them 1" }!.id
        let them2 = meeting.entry.speakers.first { $0.label == "Them 2" }!.id
        f.index.keepVoices([them1: .init(embedding: f.voice(1), model: VoiceLibrary.currentModel),
                            them2: .init(embedding: f.voice(2), model: VoiceLibrary.currentModel)], for: meeting.entry.id)
        await meeting.rename("Them 1", to: "Carlos")
        await meeting.rename("Them 2", to: "carlos")
        // One name in the note (the existing spelling), two speakers in the index, one voice learned.
        #expect(meeting.note.speakers.filter { $0 == "Carlos" }.count == 1)
        #expect(!f.read(f.note).contains("**carlos:**"))
        #expect(meeting.entry.speakers.filter { $0.name == "Carlos" }.count == 2)
        #expect(f.voices.people.count == 1)
        #expect(f.voices.people.first?.meetings == 1)
        #expect(meeting.outcome?.text.contains("doesn't sound like") == true)
    }

    @Test func deletedVoicesArentLearned() async throws {
        let f = try Fixture()
        let meeting = try await f.open()
        f.keepVoice(for: "Them 1", 1, in: meeting)
        f.index.deleteVoices(of: meeting.entry.id)
        let reopened = try await f.open()
        await reopened.rename("Them 1", to: "Carlos")
        #expect(f.voices.people.isEmpty)
        #expect(reopened.voiceStatus.hasPrefix("Voices deleted"))
    }

    @Test func voicesFoundInOldAudioAreOnlyOffered() async throws {
        let f = try Fixture()
        let meeting = try await f.open()
        let them1 = meeting.entry.speakers.first { $0.label == "Them 1" }!.id
        f.index.keepVoices([them1: .init(embedding: f.voice(1), model: VoiceLibrary.currentModel, recovered: true, sample: [1, 4])],
                           for: meeting.entry.id)
        await meeting.rename("Them 1", to: "Carlos")
        // Named, but not learned: the user listens first.
        #expect(f.voices.people.isEmpty)
        let offer = try #require(meeting.offers.first)
        #expect(offer.name == "Carlos")
        #expect(offer.sample == VoiceRecovery.Span(start: 1, end: 4))
        meeting.learn(offer)
        #expect(f.voices.people.map(\.name) == ["Carlos"])
        #expect(meeting.offers.isEmpty)
    }

    @Test func notNowKeepsTheVoiceUnlearned() async throws {
        let f = try Fixture()
        let meeting = try await f.open()
        let them1 = meeting.entry.speakers.first { $0.label == "Them 1" }!.id
        f.index.keepVoices([them1: .init(embedding: f.voice(1), model: VoiceLibrary.currentModel, recovered: true)], for: meeting.entry.id)
        await meeting.rename("Them 1", to: "Carlos")
        meeting.notNow(try #require(meeting.offers.first))
        #expect(meeting.offers.isEmpty)
        #expect(f.voices.people.isEmpty)
        #expect(!f.index.voices(for: meeting.entry).isEmpty)
    }

    @Test func readOnlyNotesArentChanged() async throws {
        let f = try Fixture()
        try Data((Fixture.text + "```\nunclosed\n").utf8).write(to: f.note)
        let meeting = try await f.open()
        await meeting.rename("Them 1", to: "Carlos")
        #expect(meeting.outcome?.isError == true)
        #expect(!f.read(f.note).contains("**Carlos:**"))
    }

    @Test func reservedNamesAreRefusedButLabelsCanComeBack() async throws {
        let f = try Fixture()
        let meeting = try await f.open()
        await meeting.rename("Them 1", to: "Them 2")
        #expect(meeting.outcome?.isError == true)
        await meeting.rename("Them 1", to: "Carlos")
        await meeting.rename("Carlos", to: "them 1")
        #expect(f.read(f.note).contains("**Them 1:** Hello there"))
        #expect(meeting.entry.speakers.first { $0.label == "Them 1" }?.name == nil)
    }
}

@Suite struct NoteFileTests {
    private func temp() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wingman-notefile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func keepsTagsPermissionsAndCreationDate() throws {
        let folder = try temp()
        defer { try? FileManager.default.removeItem(at: folder) }
        var file = folder.appendingPathComponent("note.md")
        try Data("one".utf8).write(to: file)
        var values = URLResourceValues()
        values.tagNames = ["Work"]
        try file.setResourceValues(values)
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o600, .creationDate: created], ofItemAtPath: file.path)

        let result = try NoteFile.rewrite(file) { _ in Data("two".utf8) }
        #expect(result.attributesLost.isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "two")
        let after = NoteFile.Attributes(file)
        #expect(after.tags == ["Work"])
        #expect(after.permissions == 0o600)
        #expect(abs((after.created ?? .distantPast).timeIntervalSince(created)) < 1)
        // No temporary file left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["note.md"])
    }

    @Test func aWriteMeanwhileWins() throws {
        let folder = try temp()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("note.md")
        try Data("one".utf8).write(to: file)
        #expect(throws: NoteFile.Failure.changedWhileWriting) {
            try NoteFile.rewrite(file, before: {
                // Another app (that doesn't coordinate) saves just before the swap.
                Thread.sleep(forTimeInterval: 1.1)
                try? Data("theirs!".utf8).write(to: file)
            }) { _ in Data("ours".utf8) }
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "theirs!")
    }

    @Test func aFailedChangeWritesNothing() throws {
        let folder = try temp()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("note.md")
        try Data("one".utf8).write(to: file)
        #expect(throws: NoteRewriter.Failure.speakerNotFound) {
            try NoteFile.rewrite(file) { _ in throw NoteRewriter.Failure.speakerNotFound }
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "one")
    }

    @Test func backupsAreKept30DaysAndTenPerMeeting() throws {
        let folder = try temp()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("note.md")
        try Data("one".utf8).write(to: file)
        let meeting = UUID()
        let backups = folder.appendingPathComponent("backups")
        let now = Date()
        try NoteFile.backUp([file], meeting: meeting, in: backups, now: now.addingTimeInterval(-31 * 86_400))
        #expect(NoteFile.backups(in: backups).count == 1)
        for i in 0..<12 {
            try NoteFile.backUp([file], meeting: meeting, in: backups, now: now.addingTimeInterval(Double(i)))
        }
        #expect(NoteFile.backups(in: backups).count == 10)
        // Only you can read them.
        let permissions = try FileManager.default.attributesOfItem(atPath: NoteFile.backups(in: backups)[0].path)[.posixPermissions] as? Int
        #expect(permissions == 0o700)
    }
}
