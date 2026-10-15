import Foundation
import Testing
@testable import Wingman

@Suite struct VoiceRecoveryTests {
    private typealias Span = VoiceRecovery.Span
    private func turn(_ speaker: String, _ start: Double, _ end: Double) -> SpeakerSeparation.Turn {
        SpeakerSeparation.Turn(speaker: speaker, start: start, end: end)
    }
    /// A speaker talking in 5 s stretches every 20 s, from `offset`, `count` times.
    private func talk(_ offset: Double, _ count: Int) -> [Span] {
        (0..<count).map { Span(start: offset + Double($0) * 20, end: offset + Double($0) * 20 + 5) }
    }
    private func turns(_ speaker: String, _ spans: [Span]) -> [SpeakerSeparation.Turn] {
        spans.map { turn(speaker, $0.start, $0.end) }
    }

    @Test func twoCleanSpeakersAreOffered() {
        let ana = talk(0, 6), bo = talk(10, 6)
        let result = VoiceRecovery.assign(turns: turns("S1", ana) + turns("S2", bo), spans: ["Ana": ana, "Bo": bo], you: [])
        guard case .offer(let a, _) = result["Ana"]!.outcome, case .offer(let b, _) = result["Bo"]!.outcome else {
            Issue.record("expected offers")
            return
        }
        #expect(a == "S1" && b == "S2")
    }

    @Test func aMergedClusterIsShared() {
        // The separator heard Ana and Bo as one voice: offering it would teach the wrong voice.
        let ana = talk(0, 6), bo = talk(10, 6)
        let result = VoiceRecovery.assign(turns: turns("S1", ana + bo), spans: ["Ana": ana, "Bo": bo], you: [])
        #expect(result["Ana"]!.outcome == .shared)
        #expect(result["Bo"]!.outcome == .shared)
    }

    @Test func aSpeakerSplitOverTwoClustersIsMixed() {
        let ana = talk(0, 6)
        let split = ana.enumerated().map { i, s in turn(i % 2 == 0 ? "S1" : "S2", s.start, s.end) }
        #expect(VoiceRecovery.assign(turns: split, spans: ["Ana": ana], you: [])["Ana"]!.outcome == .mixed)
    }

    @Test func tooLittleSpeechOrNotFound() {
        let ana = talk(0, 6)
        // Only one of six stretches was heard.
        #expect(VoiceRecovery.assign(turns: turns("S1", [ana[0]]), spans: ["Ana": ana], you: [])["Ana"]!.outcome == .tooLittleSpeech)
        // Little speech overall: 2 × 5 s found of 2 × 5 s, but under 8 s on any one voice.
        let short = talk(0, 2)
        let split = [turn("S1", 0, 5), turn("S2", 20, 25)]
        #expect(VoiceRecovery.assign(turns: split, spans: ["Ana": short], you: [])["Ana"]!.outcome == .notFound)
        #expect(VoiceRecovery.assign(turns: [], spans: ["Ana": ana], you: [])["Ana"]!.outcome == .tooLittleSpeech)
    }

    @Test func youCountButAreNeverOffered() {
        // Your voice in the same cluster (echo, or combined audio) makes it someone else's too.
        let ana = talk(0, 6), me = talk(10, 6)
        let result = VoiceRecovery.assign(turns: turns("S1", ana + me), spans: ["Ana": ana, "Me": me], you: ["Me"])
        #expect(result["Me"] == nil)
        #expect(result["Ana"]!.outcome == .shared)
    }

    @Test func spansFollowWordsAndStopAtTheNextLine() {
        let note = MeetingNote.parse(Data("""
        **Date:** x
        ## Transcript
        [00:00:00] **Ana:** one two three four five six seven eight nine ten
        [00:00:03] **Bo:** ok
        [00:00:04] **Me:** a b c d e f g h i j k l m n o p q r s t u v w x y z a b c d e f g h i j k l m n
        [00:00:10] **Ana:** fine
        """.utf8))
        let spans = VoiceRecovery.spans(note, isMe: { $0 == "Me" })
        // 10 words → 4.8 s, but Bo speaks at 3 s.
        #expect(spans["Ana"]![0] == Span(start: 0, end: 3))
        // One word → at least 1.5 s.
        #expect(spans["Bo"]![0] == Span(start: 3, end: 4.5))
        // Your lines run on their own side; capped at 15 s.
        #expect(spans["Me"]![0] == Span(start: 4, end: 19))
        #expect(spans["Ana"]![1] == Span(start: 10, end: 11.5))
    }

    @Test func theSampleIsTheirsAndShort() {
        let ana = talk(0, 6)
        let sample = VoiceRecovery.sample(of: "S1", turns: turns("S1", ana), spans: ana)
        #expect(sample.duration <= 5 && sample.duration >= 3)
        #expect(ana.contains { $0.start <= sample.start && sample.end <= $0.end })
    }
}

@Suite struct FindAndTallyTests {
    @Test func withoutThePhraseLinesWithAllTheWordsAreFound() {
        let texts = ["We should move the launch to Friday.", "Friday works.", "The launch went well."]
        // As a phrase, nowhere.
        #expect(TranscriptFind.phraseMatches("friday launch", in: texts).isEmpty)
        #expect(TranscriptFind.usesAllWords("friday launch", in: texts))
        let found = TranscriptFind.matches("friday launch", in: texts)
        // Only the line with both words; each word highlighted, in reading order.
        #expect(found.map(\.row) == [0, 0])
        #expect(found.map { String(texts[0][$0.range]) } == ["launch", "Friday"])
        // A phrase that exists is found as a phrase, never by its words.
        #expect(!TranscriptFind.usesAllWords("launch went", in: texts))
        #expect(TranscriptFind.matches("launch went", in: texts).map(\.row) == [2])
        // One word alone never falls back.
        #expect(TranscriptFind.matches("tuesday", in: texts).isEmpty)
    }

    @Test func findsIgnoringCaseAccentsAndPunctuation() {
        let texts = ["Testing, since I always forget.", "José said: no!", "Straße und STRASSE", "🙂 emoji 🙂 emoji"]
        #expect(TranscriptFind.matches("testing since i always", in: texts).map(\.row) == [0])
        #expect(TranscriptFind.matches("jose said no", in: texts).map(\.row) == [1])
        #expect(TranscriptFind.matches("strasse", in: texts).count == 2)
        #expect(TranscriptFind.matches("emoji", in: texts).count == 2)
        #expect(TranscriptFind.matches("   ", in: texts).isEmpty)
        #expect(TranscriptFind.matches("nothing here", in: texts).isEmpty)
    }

    @Test func matchesMapBackToTheOriginalText() throws {
        let text = "Well, José — said: hello"
        let match = try #require(TranscriptFind.matches("jose said", in: [text]).first)
        #expect(String(text[match.range]) == "José — said")
    }

    @Test func tallyCountsWhoIsLeft() {
        let tally = SpeakerTally(speakers: ["Them 1", "Ana?", "Bo", "Me", "Them 2", "Daniel"], meName: "Daniel")
        #expect(tally.toName == ["Them 1", "Them 2"])
        #expect(tally.toConfirm == ["Ana?"])
        #expect(tally.named == 1)
        #expect(tally.summary == "2 speakers to name · 1 to confirm")
        #expect(SpeakerTally(speakers: ["Bo"], meName: nil).summary == nil)
    }

    @Test @MainActor func textSizesStepThroughTheLadder() {
        #expect(ReadingPrefs.sizes.first == 11 && ReadingPrefs.sizes.last == 28)
        #expect(ReadingPrefs.sizes.contains(ReadingPrefs.standard))
        #expect(ReadingPrefs.sizes == ReadingPrefs.sizes.sorted())
    }
}
