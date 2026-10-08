import Foundation
import Testing
@testable import Wingman

private func line(_ speaker: Speaker, _ start: TimeInterval, _ end: TimeInterval, _ text: String) -> TranscriptLine {
    TranscriptLine(id: UUID(), speaker: speaker, start: start, end: end, text: text, isFinal: true)
}

@Suite struct SubtitleExportTests {
    @Test func trimsPartialOverlapToPreviousEnd() {
        let vtt = SubtitleExport.render([line(.me, 1, 5, "Hello"), line(.them, 4.5, 8, "Hi there")], as: .vtt)
        #expect(vtt.contains("00:00:05.000 --> 00:00:08.000"))
    }

    @Test func lineInsideAnotherKeepsItsOwnTimes() {
        // "Yes" said entirely while the other person was talking.
        let srt = SubtitleExport.render([line(.them, 10, 20, "A long explanation"), line(.me, 12, 13, "Yes")], as: .srt)
        #expect(srt.contains("00:00:12,000 --> 00:00:13,000"))
        #expect(!srt.contains("00:00:13,000 --> 00:00:13,000"))
    }

    @Test func usesNamesAndEscapesVoiceTags() {
        let vtt = SubtitleExport.render([line(.them, 0, 1, "a < b")], as: .vtt, title: "Sync", names: ["Them": "Ana"])
        #expect(vtt.hasPrefix("WEBVTT - Sync\n"))
        #expect(vtt.contains("<v Ana>a &lt; b"))
    }
}

@MainActor
@Suite struct RecorderHelperTests {
    @Test func dayFolderUsesLocalTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        // 23:30 local belongs to that day, whatever the UTC date is.
        let late = calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 23, minute: 30))!
        #expect(Recorder.dayFolderName(for: late) == "2026-03-14")
        #expect(Recorder.timeOfDay(late) == "23-30")
    }

    @Test func timestamps() {
        #expect(Recorder.timestamp(0) == "00:00:00")
        #expect(Recorder.timestamp(3725.9) == "01:02:05")
    }

    @Test func echoSimilarity() {
        #expect(Recorder.similarity("we ship on Friday", "We ship on Friday!") == 1)
        #expect(Recorder.similarity("hello", "goodbye") == 0)
    }
}

@Suite struct StreamTranscriberTests {
    @Test func forcedBreakFitsOneModelWindow() {
        // The utterance can grow by one 4096-sample chunk past the limit before it's cut.
        #expect(StreamTranscriber.maxUtterance + 4096 <= 240_000)
    }
}

@Suite struct SpeakerSeparationTests {
    @Test func ditherReplacesOnlyExactZeros() {
        var samples: [Float] = [0, 0.5, 0, -0.25, 0, 0]
        var state: UInt64 = 1
        samples.withUnsafeMutableBufferPointer { SpeakerSeparation.ditherZeros($0, state: &state) }
        #expect(samples[1] == 0.5)
        #expect(samples[3] == -0.25)
        for i in [0, 2, 4, 5] {
            #expect(abs(samples[i]) <= 3e-4)
            #expect(samples[i] != 0)
        }
    }

    @Test func numbersVoicesInOrderOfFirstTurn() {
        let turns = [
            SpeakerSeparation.Turn(speaker: "B", start: 0, end: 2),
            SpeakerSeparation.Turn(speaker: "A", start: 2, end: 4),
        ]
        let result = SpeakerSeparation.numbered(turns, [(0.2, 1.8), (2.1, 3.9), (0.5, 1.0)])
        #expect(result.voices == [1, 2, 1])
        #expect(result.ids == [1: "B", 2: "A"])
    }

    @Test func singleVoiceGetsNoNumber() {
        let turns = [SpeakerSeparation.Turn(speaker: "A", start: 0, end: 5)]
        #expect(SpeakerSeparation.numbered(turns, [(1, 2), (3, 4)]).voices == [nil, nil])
    }
}

@Suite struct LanguageReviewTests {
    private func line(_ text: String, confidence: Float) -> TranscriptLine {
        TranscriptLine(id: UUID(), speaker: .them, start: 0, end: 3, text: text, isFinal: true, confidence: confidence)
    }

    @Test func unsureOrWrongLanguageLinesAreReviewed() {
        let enabled: Set<SpokenLanguage> = [.spanish, .english]
        #expect(LanguageReview.needsReview(line("Se on itse kohdan.", confidence: 0.63), enabled: enabled))
        #expect(LanguageReview.needsReview(line("Não sei porquê você fez isso.", confidence: 0.95), enabled: enabled))
        #expect(!LanguageReview.needsReview(line("Hemos podido ver algunas cosas de los comportamientos.", confidence: 0.98), enabled: enabled))
        #expect(!LanguageReview.needsReview(line("Claro que sí, lo vemos mañana.", confidence: 0.82), enabled: enabled))
        #expect(!LanguageReview.needsReview(line("We ship on Friday.", confidence: 0.97), enabled: enabled))
        // Fillers and two-word lines are left alone.
        #expect(!LanguageReview.needsReview(line("Em", confidence: 0.68), enabled: enabled))
        #expect(!LanguageReview.needsReview(line("¿Cómo sí?", confidence: 0.80), enabled: enabled))
    }

    @Test func reviewResultInAnotherLanguageIsRejected() {
        let enabled: Set<SpokenLanguage> = [.spanish, .english]
        #expect(LanguageReview.readsAsOtherLanguage("che sta passando per la seconda canzone.", enabled: enabled))
        #expect(!LanguageReview.readsAsOtherLanguage("Un segundito. A ver que los chicos entran.", enabled: enabled))
    }

    @Test func languageIsChosenAmongEnabledOnes() {
        let enabled: Set<SpokenLanguage> = [.spanish, .english]
        // Whisper leans Italian for a garbled Spanish clip; Italian isn't enabled.
        let probs: [String: Float] = ["it": log(0.6), "es": log(0.3), "en": log(0.05)]
        #expect(LanguageReview.chooseLanguage(probs, enabled: enabled, main: .english) == .spanish)
        // Nothing stands out: the main language decides.
        let unsure: [String: Float] = ["it": log(0.9), "es": log(0.05), "en": log(0.04)]
        #expect(LanguageReview.chooseLanguage(unsure, enabled: enabled, main: .english) == .english)
        #expect(LanguageReview.chooseLanguage([:], enabled: enabled, main: .spanish) == .spanish)
    }

    @Test func whisperOutputIsCheckedBeforeUse() {
        #expect(LanguageReview.accept("", seconds: 3) == nil)
        #expect(LanguageReview.accept(" Thank you. ", seconds: 1.5) == nil)
        #expect(LanguageReview.accept("- Claro. - Sí, sí.", seconds: 3) == "Claro. Sí, sí.")
        #expect(LanguageReview.accept(String(repeating: "palabra ", count: 40), seconds: 2) == nil)
        #expect(LanguageReview.accept("eso no sería un feature, esta gente fue root", seconds: 6) != nil)
    }
}

@MainActor
@Suite struct EchoFilterTests {
    @Test func aClearRepeatRightAfterIsAnEcho() {
        #expect(Recorder.echoVerdict(mine: "Hemos podido ver algunas cosas de los comportamientos",
                                     theirs: "hemos podido ver algunas cosas de los comportamientos, pero", delay: 0.2) == .echo)
        #expect(Recorder.echoVerdict(mine: "We ship on Friday, right after the review",
                                     theirs: "We ship on Friday right after the review.", delay: 0) == .echo)
    }

    @Test func aDisagreementIsNeverDeleted() {
        // The review's examples: one word flips the meaning.
        #expect(Recorder.echoVerdict(mine: "We should not deploy today", theirs: "We should deploy today", delay: 0.3) == .possible)
        #expect(Recorder.echoVerdict(mine: "I cannot approve this", theirs: "I can approve this", delay: 0.3) == .possible)
        #expect(Recorder.echoVerdict(mine: "We don't ship on Friday", theirs: "We ship on Friday", delay: 0.3) == .possible)
        // Same words, opposite order.
        #expect(Recorder.echoVerdict(mine: "I was right, you were wrong", theirs: "you were right, I was wrong", delay: 0.2) == .possible)
    }

    @Test func timingAndShortLines() {
        // A repeat said seconds later is a reply, not an echo.
        #expect(Recorder.echoVerdict(mine: "We ship on Friday right after the review", theirs: "We ship on Friday right after the review", delay: 3) == .possible)
        // Short exact repeats ("Thank you" back) are kept, marked.
        #expect(Recorder.echoVerdict(mine: "Buenos días.", theirs: "Buenos días", delay: 0.1) == .possible)
        // "Sí" said by me while the other side's sentence also contains "sí".
        #expect(Recorder.echoVerdict(mine: "Sí.", theirs: "Sí, ok, sí tienen acceso.", delay: 0.1) == .none)
        #expect(Recorder.echoVerdict(mine: "Totally unrelated words here", theirs: "We ship on Friday", delay: 0) == .none)
    }

    @Test func orderedSimilarityCountsWordEdits() {
        #expect(Recorder.orderedSimilarity(["a", "b", "c", "d"], ["a", "b", "c", "d"]) == 1)
        #expect(Recorder.orderedSimilarity(["a", "b", "c", "d"], ["a", "x", "c", "d"]) == 0.75)
        #expect(Recorder.orderedSimilarity(["a", "b"], ["c", "d"]) == 0)
    }
}

@Suite struct CallAudioWarningTests {
    @Test func quietStartIsNotAProblem() {
        // Nobody has spoken yet 18 s in: no warning (the old check warned here and never cleared).
        #expect(!Recorder.callAudioMissing(heard: false, waited: 18, somethingPlaying: true))
    }

    @Test func aMinuteOfNothingWhilePlayingIsWarned() {
        #expect(Recorder.callAudioMissing(heard: false, waited: 61, somethingPlaying: true))
    }

    @Test func warningGoesOnceAudioArrivesOrNothingPlays() {
        #expect(!Recorder.callAudioMissing(heard: true, waited: 90, somethingPlaying: true))
        #expect(!Recorder.callAudioMissing(heard: false, waited: 90, somethingPlaying: false))
    }
}
