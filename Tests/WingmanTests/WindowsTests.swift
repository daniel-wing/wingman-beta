import Foundation
import Testing
@testable import Wingman

/// The two windows: the Wingman window's list (one row per meeting, from
/// recording to saved note), what it chooses to show by itself, and the Live
/// Transcript's rules.
@Suite struct WindowsTests {
    private static let day = "2026-10-29"
    private static let noteA = URL(fileURLWithPath: "/notes/2026-10-29/2026-10-29_01_Sync.md")
    private static let noteB = URL(fileURLWithPath: "/notes/2026-10-29/2026-10-29_02_Review.md")
    private static let morning = Date(timeIntervalSince1970: 1_793_260_000)

    private func entry(_ url: URL, toName: Int, at offset: TimeInterval) -> MeetingsStore.Entry {
        var tally = SpeakerTally(speakers: [], meName: nil)
        tally.toName = (0..<toName).map { "Them \($0 + 1)" }
        if toName == 0 { tally.named = 1 }
        return MeetingsStore.Entry(url: url, day: Self.day, title: url.lastPathComponent, time: Self.morning + offset,
                                   tally: tally, readOnly: nil)
    }

    private func open(_ id: UUID, note: URL?, stage: Meeting.Stage, toName: Int = 0, at offset: TimeInterval) -> WingmanSidebar.Open {
        var tally: SpeakerTally?
        if stage == .done {
            var done = SpeakerTally(speakers: [], meName: nil)
            done.toName = (0..<toName).map { "Them \($0 + 1)" }
            if toName == 0 { done.named = 1 }
            tally = done
        }
        return WingmanSidebar.Open(id: id, note: note, title: "Meeting", started: Self.morning + offset, stage: stage, tally: tally)
    }

    // MARK: The Wingman window's list

    @Test func aMeetingInMemoryReplacesItsNotesRow() {
        let recording = UUID(), saved = UUID()
        let entries = [entry(Self.noteA, toName: 2, at: 0), entry(Self.noteB, toName: 0, at: 3600)]
        let sections = WingmanSidebar.sections(
            entries: entries,
            open: [open(recording, note: nil, stage: .recording, at: 7200),
                   open(saved, note: Self.noteA, stage: .done, toName: 1, at: 0)],
            onlyToName: false, today: Self.day)
        #expect(sections.now.map(\.id) == [.meeting(recording)])
        #expect(sections.now.first?.badge == .recording(Self.morning + 7200))
        // The note's own row is gone: the meeting in memory stands for it.
        #expect(sections.days.map(\.day) == [Self.day])
        #expect(sections.days.first?.rows.map(\.id) == [.note(Self.noteB), .meeting(saved)], "newest first")
        #expect(sections.days.first?.rows.last?.badge == .toName(1))
    }

    @Test func aForgottenMeetingComesBackAsItsNote() {
        let sections = WingmanSidebar.sections(entries: [entry(Self.noteA, toName: 2, at: 0)], open: [],
                                               onlyToName: false, today: Self.day)
        #expect(sections.now.isEmpty)
        #expect(sections.days.first?.rows.map(\.id) == [.note(Self.noteA)])
        #expect(sections.days.first?.rows.first?.badge == .toName(2))
    }

    @Test func savingIsNowAndOnlyToNameHidesTheNamed() {
        let finishing = UUID(), done = UUID()
        let sections = WingmanSidebar.sections(
            entries: [entry(Self.noteA, toName: 0, at: 0), entry(Self.noteB, toName: 1, at: 60)],
            open: [open(finishing, note: nil, stage: .finishing("Saving audio…"), at: 120),
                   open(done, note: nil, stage: .done, toName: 0, at: 90)],
            onlyToName: true, today: Self.day)
        #expect(sections.now.map(\.badge) == [.saving], "a call still being saved stays under Now")
        #expect(sections.days.flatMap(\.rows).map(\.id) == [.note(Self.noteB)])
    }

    @MainActor @Test func wingmanMovesOnToTheNextCallOnlyIfTheUserDidntChooseSomething() {
        let nav = WingmanNavigation()
        let first = UUID(), second = UUID()
        nav.follow(first)
        #expect(nav.selection == .meeting(first), "an empty window follows the call")
        nav.follow(second)
        #expect(nav.selection == .meeting(second), "and the next one")
        nav.show(.note(Self.noteA))
        nav.follow(UUID())
        #expect(nav.selection == .note(Self.noteA), "naming speakers isn't interrupted by a new call")
        nav.forget(second)
        #expect(nav.selection == .note(Self.noteA))
        nav.show(.meeting(second))
        nav.forget(second)
        #expect(nav.selection == nil)
    }

    // MARK: The Live Transcript

    @Test func liveTranscriptAppearsHidesAndComesBack() {
        var state = LivePanelState()
        let call = UUID()
        state.current(call)
        #expect(state.visible && state.meeting == call)
        state.close()
        #expect(!state.visible && state.meeting == call, "closing hides it; the recording goes on")
        state.current(call)
        #expect(!state.visible, "and it stays hidden")
        state.show()
        #expect(state.visible)
    }

    @Test func liveTranscriptFollowsASplitAndRespectsBeingHidden() {
        var state = LivePanelState()
        let first = UUID(), second = UUID(), third = UUID()
        state.current(first)
        state.current(second)
        #expect(state.visible && state.meeting == second, "a new note for a new call: it moves on")
        state.close()
        state.current(third)
        #expect(!state.visible && state.meeting == third, "hidden stays hidden through a split")
    }

    @Test func liveTranscriptSaysSavedThenGoes() {
        var state = LivePanelState()
        let call = UUID()
        state.current(call)
        state.current(nil)
        #expect(state.ended && state.visible && state.meeting == call, "the call stopped: Saving…, then Saved")
        state.savedTimeout()
        #expect(state == LivePanelState())
        // A new recording before the timeout starts afresh, even after hiding.
        state.current(call)
        state.close()
        state.current(nil)
        let next = UUID()
        state.current(next)
        #expect(state.visible && state.meeting == next && !state.ended)
    }

    @Test func liveTranscriptClosedAfterTheCallIsDone() {
        var state = LivePanelState()
        state.current(UUID())
        state.current(nil)
        state.close()
        #expect(state == LivePanelState())
        state.show()
        #expect(!state.visible, "nothing to show")
    }

    @Test func liveTranscriptOpacityStaysReadable() {
        #expect(LiveLook.alpha(setting: 0.85, reduceTransparency: false, increaseContrast: false) == 0.85)
        #expect(LiveLook.alpha(setting: 0.2, reduceTransparency: false, increaseContrast: false) == 0.6)
        #expect(LiveLook.alpha(setting: 1.4, reduceTransparency: false, increaseContrast: false) == 1)
        #expect(LiveLook.alpha(setting: 0.7, reduceTransparency: true, increaseContrast: false) == 1)
        #expect(LiveLook.alpha(setting: 0.7, reduceTransparency: false, increaseContrast: true) == 1)
    }

    @Test func teamsSharingBarIsRecognized() {
        #expect(AXProbe.isSharingBar("Sharing control bar"))
        #expect(AXProbe.isSharingBar("Sharing control bar | Microsoft Teams"))
        #expect(!AXProbe.isSharingBar("Meeting compact view"))
    }
}
