import Foundation
import Testing
@testable import Wingman

private let sample = """
# Weekly sync

**Date:** Oct 7, 2026 at 1:31 PM
**Duration:** 32 min

**Calendar:** Weekly sync, 1:30 PM–2:00 PM
**Organizer:** Ana Ruiz
**Invited:** Ana Ruiz, Carlos Pérez

## Transcript

[00:00:03] **Them 1:** Hi everyone, can you hear me?

[00:00:07] **Daniel:** Yes, loud and clear.

[00:00:12] **Them 2:** Let's start with the numbers. *(unclear)*

[00:01:02] **Them 1:** Them 2: has the slides. **Them 1:** said so.

[00:01:30] **Ana?:** I'll share my screen.

---
*(unclear)* marks lines the speech model wasn't confident about; check them against the audio.

"""

private func data(_ s: String) -> Data { Data(s.utf8) }
private func text(_ d: Data) -> String { String(decoding: d, as: UTF8.self) }

@Suite struct MeetingNoteParsingTests {
    @Test func readsHeaderAndLines() {
        let note = MeetingNote.parse(data(sample))
        #expect(note.readOnly == nil)
        #expect(note.title == "Weekly sync")
        #expect(note.header["Organizer"] == "Ana Ruiz")
        #expect(note.header["Invited"] == "Ana Ruiz, Carlos Pérez")
        #expect(note.header["Calendar"] == "Weekly sync, 1:30 PM–2:00 PM")
        #expect(note.lines.count == 5)
        #expect(note.speakers == ["Them 1", "Daniel", "Them 2", "Ana?"])
        #expect(note.lines[2].mark == .unclear)
        #expect(note.lines[2].text == "Let's start with the numbers.")
        #expect(note.lines[3].start == 62)
        #expect(note.lines[3].text == "Them 2: has the slides. **Them 1:** said so.")
    }

    @Test func roundTripsExactly() {
        for variant in [sample, sample.replacingOccurrences(of: "\n", with: "\r\n"), String(sample.dropLast()), ""] {
            #expect(MeetingNote.parse(data(variant)).data == data(variant))
        }
    }

    @Test func crlfLinesStillParse() {
        let note = MeetingNote.parse(data(sample.replacingOccurrences(of: "\n", with: "\r\n")))
        #expect(note.readOnly == nil)
        #expect(note.lines.count == 5)
        #expect(note.lines[0].speaker == "Them 1")
    }

    @Test func onlyTheTranscriptSectionCounts() {
        let note = MeetingNote.parse(data("""
        # Sync
        **Date:** today
        [00:00:01] **Above:** not a line
        ## Transcript
        [00:00:02] **Them:** inside
        ## My notes
        [00:00:03] **After:** not a line either
        """))
        #expect(note.lines.map(\.speaker) == ["Them"])
    }

    @Test func codeBlocksAreNotTranscript() {
        let note = MeetingNote.parse(data("""
        **Date:** today
        ## Transcript
        [00:00:02] **Them:** inside
        ```
        [00:00:03] **Code:** quoted
        ## Transcript
        ```
        ~~~~
        [00:00:04] **Tilde:** quoted
        ~~~~
        [00:00:05] **Them:** after
        """))
        #expect(note.readOnly == nil)
        #expect(note.lines.map(\.speaker) == ["Them", "Them"])
    }

    @Test func unsafeNotesAreReadOnly() {
        #expect(MeetingNote.parse(data("**Date:** x\n## Transcript\n```\n[00:00:01] **A:** b")).readOnly == .unclosedCodeBlock)
        #expect(MeetingNote.parse(data("**Date:** x\nno transcript")).readOnly == .noTranscript)
        #expect(MeetingNote.parse(data("**Date:** x\n## Transcript\n## Transcript")).readOnly == .severalTranscripts)
        #expect(MeetingNote.parse(data("# Mine\n## Transcript\n[00:00:01] **A:** b")).readOnly == .notWingman)
        #expect(MeetingNote.parse(Data([0x23, 0x20, 0xFF, 0xFE])).readOnly == .notText)
    }

    @Test func speakerKinds() {
        #expect(MeetingNote.kind(of: "Them") == .unnamed)
        #expect(MeetingNote.kind(of: "Them 12") == .unnamed)
        #expect(MeetingNote.kind(of: "Thembeka") == .named)
        #expect(MeetingNote.kind(of: "Ana?") == .guess)
        #expect(MeetingNote.kind(of: "Me") == .me)
        #expect(MeetingNote.kind(of: "Daniel", meName: "Daniel") == .me)
        // Matching today's "my name" setting isn't enough: only the name the note was recorded with.
        #expect(MeetingNote.kind(of: "Daniel") == .named)
    }
}

@Suite struct SpeakerNameTests {
    @Test func cleansNames() {
        #expect(SpeakerName.clean("  Ana   María ") == "Ana María")
        #expect(SpeakerName.clean("**Ana**") == "Ana")
        #expect(SpeakerName.clean("Ana??") == "Ana")
        #expect(SpeakerName.clean("Ana\nRuiz") == "Ana Ruiz")
        #expect(SpeakerName.clean(String(repeating: "a", count: 80))?.count == 60)
        #expect(SpeakerName.clean("C++ (dev)") == "C++ (dev)")
    }

    @Test func rejectsWingmansOwnLabels() {
        for name in ["", "   ", "?", "Me", "me", "Them", "THEM 3", "them 12"] {
            #expect(SpeakerName.clean(name) == nil)
        }
        #expect(SpeakerName.clean("Them 3b") == "Them 3b")
    }
}

@Suite struct NoteRewriterTests {
    @Test func renamesOnlyThatSpeakersLines() throws {
        let renamed = text(try NoteRewriter.renameSpeaker(in: data(sample), from: "Them 1", to: "Carlos"))
        #expect(renamed.contains("[00:00:03] **Carlos:** Hi everyone"))
        // The same words inside what someone said stay as they were.
        #expect(renamed.contains("[00:01:02] **Carlos:** Them 2: has the slides. **Them 1:** said so."))
        #expect(renamed.contains("**Them 2:** Let's start"))
        let changedRows = zip(sample.split(separator: "\n", omittingEmptySubsequences: false),
                              renamed.split(separator: "\n", omittingEmptySubsequences: false)).filter { $0 != $1 }
        #expect(changedRows.count == 2)
    }

    @Test func sameNameIsByteIdentical() throws {
        #expect(try NoteRewriter.renameSpeaker(in: data(sample), from: "Them 2", to: "Them 2") == data(sample))
    }

    @Test func renameAndBackRestoresTheNote() throws {
        let crlf = data(sample.replacingOccurrences(of: "\n", with: "\r\n"))
        let there = try NoteRewriter.renameSpeaker(in: crlf, from: "Them 2", to: "C++ (dev)")
        #expect(text(there).contains("**C++ (dev):** Let's start with the numbers. *(unclear)*\r\n"))
        #expect(try NoteRewriter.renameSpeaker(in: there, from: "C++ (dev)", to: "Them 2") == crlf)
    }

    @Test func confirmsAGuess() throws {
        let renamed = text(try NoteRewriter.renameSpeaker(in: data(sample), from: "Ana?", to: "Ana"))
        #expect(renamed.contains("[00:01:30] **Ana:** I'll share my screen."))
    }

    @Test func mergesUnderTheExistingSpelling() {
        let note = MeetingNote.parse(data(sample))
        #expect(NoteRewriter.spelling(for: "daniel", in: note, renaming: "Them 2") == "Daniel")
        #expect(NoteRewriter.spelling(for: "Carlos", in: note, renaming: "Them 2") == "Carlos")
    }

    @Test func linesInCodeOrOtherSectionsStayUntouched() throws {
        let note = """
        **Date:** today
        ## Transcript
        [00:00:02] **Them:** inside
        ```
        [00:00:03] **Them:** quoted
        ```
        ## Later
        [00:00:04] **Them:** after
        """
        let renamed = text(try NoteRewriter.renameSpeaker(in: data(note), from: "Them", to: "Ana"))
        #expect(renamed.contains("[00:00:02] **Ana:** inside"))
        #expect(renamed.contains("[00:00:03] **Them:** quoted"))
        #expect(renamed.contains("[00:00:04] **Them:** after"))
    }

    @Test func refusesWhatItCantDoSafely() {
        #expect(throws: NoteRewriter.Failure.speakerNotFound) {
            try NoteRewriter.renameSpeaker(in: data(sample), from: "Nobody", to: "Ana")
        }
        #expect(throws: NoteRewriter.Failure.invalidName) {
            try NoteRewriter.renameSpeaker(in: data(sample), from: "Them 1", to: "Ana:** x")
        }
        #expect(throws: NoteRewriter.Failure.readOnly(.unclosedCodeBlock)) {
            try NoteRewriter.renameSpeaker(in: data("**Date:** x\n## Transcript\n[00:00:01] **A:** b\n```"), from: "A", to: "B")
        }
    }

    @Test func verifyCatchesOtherChanges() {
        let old = MeetingNote.parse(data(sample))
        let tampered = MeetingNote.parse(data(sample.replacingOccurrences(of: "loud and clear", with: "LOUD")))
        #expect(throws: NoteRewriter.Failure.unexpectedChange) {
            try NoteRewriter.verify(old: old, new: tampered, from: "Them 1", to: "Them 1")
        }
    }
}

@Suite struct SubtitleRewriterTests {
    private let note = MeetingNote.parse(data("""
    **Date:** today
    ## Transcript
    [00:00:01] **Them 1:** Hello <there>
    [00:00:04] **Ana:** Them 1: hi
    [00:00:09] **Them 1:** Bye
    """))

    private let vtt = """
    WEBVTT - Sync

    00:00:01.200 --> 00:00:04.000
    <v Them 1>Hello &lt;there&gt;

    00:00:04.000 --> 00:00:06.000
    <v Ana>Them 1: hi

    00:00:10.500 --> 00:00:12.000
    <v Them 1>Bye

    """

    private let srt = """
    1
    00:00:01,200 --> 00:00:04,000
    Them 1: Hello <there>

    2
    00:00:04,000 --> 00:00:06,000
    Ana: Them 1: hi

    3
    00:00:10,500 --> 00:00:12,000
    Them 1: Bye


    """

    @Test func renamesVoiceTags() throws {
        let renamed = text(try SubtitleRewriter.renameSpeaker(in: data(vtt), format: .vtt, note: note, from: "Them 1", to: "Carlos <C>"))
        #expect(renamed.contains("<v Carlos &lt;C&gt;>Hello &lt;there&gt;"))
        #expect(renamed.contains("<v Carlos &lt;C&gt;>Bye"))
        #expect(renamed.contains("<v Ana>Them 1: hi"))
    }

    @Test func renamesSrtPrefixesOnly() throws {
        let renamed = text(try SubtitleRewriter.renameSpeaker(in: data(srt), format: .srt, note: note, from: "Them 1", to: "Carlos"))
        #expect(renamed.contains("\nCarlos: Hello <there>\n"))
        #expect(renamed.contains("\nCarlos: Bye\n"))
        #expect(renamed.contains("\nAna: Them 1: hi\n"))
        let otherRows = zip(srt.split(separator: "\n", omittingEmptySubsequences: false),
                            renamed.split(separator: "\n", omittingEmptySubsequences: false)).filter { $0 != $1 }
        #expect(otherRows.count == 2)
    }

    @Test func leavesFilesThatDontLineUp() {
        // A cue removed by hand.
        let edited = srt.replacingOccurrences(of: "2\n00:00:04,000 --> 00:00:06,000\nAna: Them 1: hi\n\n", with: "")
        #expect(throws: SubtitleRewriter.Failure.doesNotLineUp) {
            try SubtitleRewriter.renameSpeaker(in: data(edited), format: .srt, note: note, from: "Them 1", to: "Carlos")
        }
        // A cue far from the line's time.
        let shifted = vtt.replacingOccurrences(of: "00:00:10.500", with: "00:00:30.500")
        #expect(throws: SubtitleRewriter.Failure.doesNotLineUp) {
            try SubtitleRewriter.renameSpeaker(in: data(shifted), format: .vtt, note: note, from: "Them 1", to: "Carlos")
        }
        // A speaker that doesn't match the note.
        let other = vtt.replacingOccurrences(of: "<v Ana>", with: "<v Bob>")
        #expect(throws: SubtitleRewriter.Failure.doesNotLineUp) {
            try SubtitleRewriter.renameSpeaker(in: data(other), format: .vtt, note: note, from: "Them 1", to: "Carlos")
        }
    }

    @Test func matchesWhatTheExporterWrites() throws {
        let lines = [
            TranscriptLine(id: UUID(), speaker: .them, start: 1.4, end: 3, text: "One & two", isFinal: true),
            TranscriptLine(id: UUID(), speaker: .me, start: 2.5, end: 5, text: "Three", isFinal: true),
        ]
        let md = MeetingNote.parse(data("**Date:** x\n## Transcript\n[00:00:01] **Them:** One & two\n[00:00:02] **Daniel:** Three"))
        for format in SubtitleExport.Format.allCases {
            let file = SubtitleExport.render(lines, as: format, title: "T", names: ["Me": "Daniel"])
            let renamed = text(try SubtitleRewriter.renameSpeaker(in: data(file), format: format, note: md, from: "Them", to: "Ana"))
            #expect(renamed.contains(format == .vtt ? "<v Ana>One &amp; two" : "Ana: One & two"))
        }
    }
}
