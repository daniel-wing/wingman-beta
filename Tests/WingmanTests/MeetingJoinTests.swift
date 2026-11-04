import AVFoundation
import Foundation
import Testing
@testable import Wingman

@Suite struct MeetingJoinTests {
    @Test func speakersAreMatchedOrNumberedAfterTheEarlierOnes() {
        let map = MeetingJoin.speakerMap(earlier: ["Wing", "Them 1", "Ana", "Them 2"],
                                         later: ["Me", "Them 1", "Them 2", "Them 3", "Ana", "Luis?", "Them"],
                                         earlierMe: "Wing", laterMe: nil, sameVoice: ["Them 2": "Them 1"])
        #expect(map["Me"] == "Wing", "you are you")
        #expect(map["Them 2"] == "Them 1", "the same voice")
        #expect(map["Them 1"] == "Them 3", "a voice not matched, whose label is taken")
        #expect(map["Them 3"] == "Them 4")
        #expect(map["Ana"] == "Ana" && map["Luis?"] == "Luis?", "names and guesses stay")
        #expect(map["Them"] == "Them", "a label the earlier meeting doesn't use stays")
    }

    @Test func theLaterLinesFollowAtTheirTimeWithTheGapMarked() {
        let earlier = MeetingNote.parse(Data("""
        # Weekly sync

        **Date:** 2 Nov 2026 at 9:00
        **Duration:** 9 min

        **Recording:** Wingman stopped unexpectedly at 9:09, so it ends there.  

        ## Transcript

        [00:00:05] **Them:** Can you hear me

        [00:08:50] **Me:** Yes I can

        """.utf8))
        let later = MeetingNote.parse(Data("""
        # Weekly sync

        **Date:** 2 Nov 2026 at 9:10
        **Duration:** 30 min

        ## Transcript

        [00:00:03] **Them 1:** We're back

        [00:00:09] **Me:** Good *(unclear)*

        """.utf8))
        let text = MeetingJoin.joinedNote(earlier: earlier, later: later, offset: 600, earlierEnd: 540,
                                          names: ["Them 1": "Them", "Me": "Me"], minutes: 40)
        let joined = MeetingNote.parse(Data(text.utf8))
        #expect(joined.readOnly == nil)
        #expect(joined.lines.map(\.start) == [5, 530, 603, 609])
        #expect(joined.lines.map(\.speaker) == ["Them", "Me", "Them", "Me"])
        #expect(joined.lines.last?.mark == .unclear)
        #expect(text.contains("*[00:09:00] Not recorded for 60 s (between two recordings).*"))
        #expect(text.contains("**Duration:** 40 min"))
        #expect(text.contains(MeetingNote.Mark.unclear.explanation))
        #expect(joined.header["Date"] == "2 Nov 2026 at 9:00", "the earlier note's header stays")
        #expect(!text.contains("Wingman stopped unexpectedly"), "the recording no longer ends where the earlier one stopped")
    }

    @Test func theAudioIsTheEarlierThenSilenceThenTheLater() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wingman-join-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func make(_ name: String, seconds: Int) throws -> URL {
            let wav = folder.appendingPathComponent(name + ".wav")
            let writer = try TrackWriter(url: wav) { _ in }
            writer.append((0..<(seconds * 16_000)).map { 0.3 * Float(sin(Double($0) * 0.05)) })
            writer.finish()
            let m4a = folder.appendingPathComponent(name + ".m4a")
            try AudioMix.mix([wav], to: m4a)
            return m4a
        }
        let a = try make("a", seconds: 2), b = try make("b", seconds: 3)
        let out = folder.appendingPathComponent("joined.m4a")
        try MeetingJoin.joinAudio(earlier: a, later: b, offset: 5, to: out)
        let seconds = try #require(MeetingJoin.seconds(of: out))
        #expect(abs(seconds - 8) < 0.2, "2 s, silence to 5 s, then 3 s: \(seconds)")
        // Only one side: its time is silence.
        try MeetingJoin.joinAudio(earlier: nil, later: b, offset: 4, to: out)
        #expect(abs((MeetingJoin.seconds(of: out) ?? 0) - 7) < 0.2)
    }
}
