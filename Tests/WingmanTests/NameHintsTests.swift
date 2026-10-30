import Foundation
import Testing
@testable import Wingman

/// Naming who's speaking on a line during the call, and what that names after
/// the call (see `NameHints`).
@Suite struct NameHintsTests {
    private func match(_ name: String, confident: Bool = true) -> VoiceLibrary.Match {
        VoiceLibrary.Match(name: name, similarity: confident ? 0.8 : 0.6, confident: confident)
    }

    @Test func aKnownVoiceWithTheSameNameIsNamed() {
        let result = NameHints.resolve([("Them 1", "Ana"), ("Them 1", "ana")], matches: ["Them 1": match("Ana López", confident: false)])
        #expect(result.named == ["Them 1": "Ana López"], "Wingman's spelling, so the voice joins that person")
        #expect(result.toConfirm.isEmpty && result.notices.isEmpty)
    }

    @Test func aNewPersonIsOnlySuggested() {
        let result = NameHints.resolve([("Them 2", "Luis")], matches: [:])
        #expect(result.named.isEmpty)
        #expect(result.toConfirm == ["Them 2": "Luis"])
        #expect(result.notices.isEmpty)
    }

    @Test func aVoiceThatSoundsLikeSomeoneElseIsQuestioned() {
        let result = NameHints.resolve([("Them 2", "Luis")], matches: ["Them 2": match("Marta")])
        #expect(result.toConfirm == ["Them 2": "Luis"])
        #expect(result.notices == ["Them 2 sounds like Marta, but you named them Luis during the call."])
        // An unsure match isn't worth a notice: the user's name stands, to confirm.
        let unsure = NameHints.resolve([("Them 2", "Luis")], matches: ["Them 2": match("Marta", confident: false)])
        #expect(unsure.toConfirm == ["Them 2": "Luis"] && unsure.notices.isEmpty)
    }

    @Test func twoNamesOnOneVoiceAreQuestioned() {
        let result = NameHints.resolve([("Them 1", "Ana"), ("Them 1", "Luis"), ("Them 1", "Luis")],
                                       matches: ["Them 1": match("Luis")])
        #expect(result.named.isEmpty, "even when the voice agrees with one of them")
        #expect(result.toConfirm == ["Them 1": "Luis"], "the name given most")
        #expect(result.notices == ["You named Them 1 both Luis and Ana during the call: check its lines."])
    }

    @Test func oneNameOnTwoVoicesIsAskedForBoth() {
        let result = NameHints.resolve([("Them 1", "Ana"), ("Them 3", "Ana")], matches: [:])
        #expect(result.toConfirm == ["Them 1": "Ana", "Them 3": "Ana"])
    }

    @Test func aSingleRemoteVoiceUsesThem() {
        let result = NameHints.resolve([("Them", "Ana")], matches: ["Them": match("Ana")])
        #expect(result.named == ["Them": "Ana"])
    }

    @Test func aNewerVersionOfALineKeepsItsName() {
        var line = TranscriptLine(id: UUID(), speaker: .them, start: 1, end: 2, text: "so the", isFinal: false)
        line.hint = "Ana"
        let final = TranscriptLine(id: line.id, speaker: .them, start: 1, end: 3, text: "so the numbers", isFinal: true)
        let updated = line.updated(by: final)
        #expect(updated.hint == "Ana" && updated.text == "so the numbers" && updated.isFinal)
    }
}

@MainActor
@Suite struct NamingLinesTests {
    private func meeting(_ recorder: Recorder, in folder: URL) -> Meeting {
        Meeting(recorder: recorder, stage: .recording, origin: 0, started: Date(), name: "Test", event: nil,
                nameFromCalendar: false, base: folder.appendingPathComponent("test"), prefix: "test", tracksKept: false,
                meAudio: nil, themAudio: nil, sourceFile: "test")
    }

    @Test func aNamedLineShowsTheNameButTheNoteKeepsThem() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wingman-hints-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = Recorder()
        let first = meeting(recorder, in: folder)
        let lines = (0..<4).map { TranscriptLine(id: UUID(), speaker: $0 == 0 ? .me : .them, start: Double($0) * 10,
                                                 end: Double($0) * 10 + 5, text: "line \($0)", isFinal: true) }
        first.replaceLines(lines)
        first.nameLine(lines[0].id, as: "Ana")
        #expect(first.lines[0].hint == nil, "only remote lines")
        first.nameLine(lines[1].id, as: " Ana? ")
        first.nameLine(lines[2].id, as: "Luis")
        first.nameLine(lines[3].id, as: "Them 2")
        #expect(first.lines.map(\.hint) == [nil, "Ana", "Luis", nil], "cleaned like any name")
        #expect(first.liveName(first.lines[1]) == "Ana")
        #expect(first.displayName(first.lines[1]) == "Them")
        #expect(first.hintNames == ["Luis", "Ana"], "most recent first")
        let note = try #require(first.noteText())
        #expect(!note.contains("Ana") && !note.contains("Luis"))

        // An update of the line from the speech engine keeps the name.
        first.handle(TranscriptEvent(utteranceID: lines[1].id, speaker: .them, start: 10, end: 16, text: "line 1 again", isFinal: true))
        #expect(first.lines[1].hint == "Ana")

        // A split takes the named lines with it.
        let moved = first.release(from: 20)
        #expect(moved.map(\.hint) == ["Luis", nil])
        first.nameLine(lines[1].id, as: nil)
        #expect(first.lines[1].hint == nil, "not sure")
        withExtendedLifetime(recorder) {}
    }

    @Test func afterTheCallANewNameWaitsForConfirmation() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wingman-hints-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = Recorder()
        let call = meeting(recorder, in: folder)
        let lines = (0..<3).map { TranscriptLine(id: UUID(), speaker: .them, start: Double($0) * 10,
                                                 end: Double($0) * 10 + 5, text: "line \($0)", isFinal: true) }
        call.replaceLines(lines)
        call.nameLine(lines[1].id, as: "Ana")
        // As `finish` does when there's no separation: the name applies to
        // "Them". (Not `finish` itself: it records the meeting in the real index.)
        call.labelsAreFinal()
        #expect(call.labelsFinal)
        #expect(call.guess(for: "Them") == "Ana" && call.guessFromHint.contains("Them"))
        #expect(call.displayName(call.lines[0]) == "Ana?", "every line of that voice")
        #expect(call.liveName(call.lines[0]) == "Ana?")
        #expect(call.guessCount == 1)
        #expect(call.notice?.contains("You named a voice during the call") == true)
        call.nameLine(lines[2].id, as: "Luis")
        #expect(call.lines[2].hint == nil, "lines can't be named once the voices are")
        withExtendedLifetime(recorder) {}
    }
}
