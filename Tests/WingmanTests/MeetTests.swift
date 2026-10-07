import Foundation
import Testing
@testable import Wingman

// MARK: - Recognizing Meet from titles and addresses

@Suite struct MeetDetectionTests {
    @Test func meetingCodesAndAddresses() {
        #expect(MeetDetection.meetingCode(in: "join abc-defg-hij now") == "abc-defg-hij")
        #expect(MeetDetection.meetingCode(in: "abc-defg-hijk") == nil)
        #expect(MeetDetection.meetingCode(fromAddress: "meet.google.com/abc-defg-hij?authuser=0") == "abc-defg-hij")
        #expect(MeetDetection.meetingCode(fromAddress: "https://meet.google.com/abc-defg-hij") == "abc-defg-hij")
        #expect(MeetDetection.meetingCode(fromAddress: "meet.google.com.evil.com/abc-defg-hij") == nil)
        #expect(MeetDetection.meetingCode(fromAddress: "https://evil.com/meet.google.com/abc-defg-hij") == nil)
        #expect(MeetDetection.meetingCode(fromAddress: "meet.google.com/landing?lfhs=2") == nil)
        #expect(MeetDetection.meetingCode(fromAddress: "chrome://accessibility") == nil)
    }

    @Test func meetTitlesInMeasuredLanguages() {
        #expect(MeetDetection.meetTitleCode("Meet – abc-defg-hij - Microphone recording") == "abc-defg-hij")  // en
        #expect(MeetDetection.meetTitleCode("Meet - abc-defg-hij - Microphone recording") == "abc-defg-hij")  // es
        #expect(MeetDetection.meetTitleCode("Meet: abc-defg-hij") == "abc-defg-hij")                        // pt-BR
        #expect(MeetDetection.isMeetTitle("Meet - Camera and microphone recording"))                        // before its page is drawn
        #expect(MeetDetection.meetTitleCode("Meet - Camera and microphone recording") == nil)
        #expect(!MeetDetection.isMeetTitle("Meeting notes – abc-defg-hij"))
        #expect(!MeetDetection.isMeetTitle("Docs – abc-defg-hij - Microphone recording"))
    }

    @Test func recordingNotes() {
        #expect(MeetDetection.hasRecordingNote("Meet – abc-defg-hij - Camera and microphone recording"))
        #expect(MeetDetection.hasRecordingNote("Meet – abc-defg-hij - Part of group Work - Microphone recording"))
        #expect(!MeetDetection.hasRecordingNote("Meet – abc-defg-hij - Audio playing"))  // the leave sound
        #expect(!MeetDetection.hasRecordingNote("Meet – abc-defg-hij - Camera recording"))  // nothing about the mic
        #expect(!MeetDetection.hasRecordingNote("Meet – abc-defg-hij"))
        #expect(MeetDetection.notesReadable(preferredLanguages: ["en-MX", "es-MX"]))
        #expect(!MeetDetection.notesReadable(preferredLanguages: ["es-MX", "en"]))
        #expect(!MeetDetection.notesReadable(preferredLanguages: []))
    }

    private func window(_ tabs: [(String, Bool)], address: String?) -> BrowserWindowScan {
        BrowserWindowScan(tabs: tabs.map { BrowserTab(title: $0.0, isSelected: $0.1) }, address: address)
    }

    @Test func verifiedOnlyByItsOwnWindowsAddress() {
        let recording = "Meet – abc-defg-hij - Microphone recording"
        // Selected, and the same window's address has the same code: strong.
        let strong = MeetDetection.candidates(in: [window([(recording, true)], address: "meet.google.com/abc-defg-hij?authuser=0")], meetApp: nil)
        #expect(strong == [MeetCandidate(code: "abc-defg-hij", evidence: .strong, source: .tab)])
        // A background tab: the window's address is the selected tab's, so title only.
        let background = MeetDetection.candidates(
            in: [window([("Docs", true), (recording, false)], address: "docs.google.com/document/d/x")], meetApp: nil)
        #expect(background.map(\.evidence) == [.weak])
        // Another window showing that meeting's address doesn't vouch for this tab.
        let otherWindow = MeetDetection.candidates(in: [
            window([(recording, false)], address: "example.com"),
            window([("Meet – abc-defg-hij", true)], address: "meet.google.com/abc-defg-hij"),
        ], meetApp: nil)
        #expect(otherWindow.map(\.evidence) == [.weak])
    }

    @Test func notMeetCalls() {
        // The "You've left" page keeps the code but loses the note.
        #expect(MeetDetection.candidates(in: [window([("Meet – abc-defg-hij", true)], address: "meet.google.com/abc-defg-hij")], meetApp: nil).isEmpty)
        // Another site with a code-like title.
        #expect(MeetDetection.candidates(in: [window([("Docs – abc-defg-hij - Microphone recording", true)], address: "docs.google.com")], meetApp: nil).isEmpty)
    }

    @Test func sameMeetingTwiceIsOneCandidate() {
        let tabs = [("Meet – abc-defg-hij - Microphone recording", true), ("Meet – abc-defg-hij - Camera and microphone recording", false)]
        let found = MeetDetection.candidates(in: [window(tabs, address: "meet.google.com/abc-defg-hij")], meetApp: nil)
        #expect(found == [MeetCandidate(code: "abc-defg-hij", evidence: .strong, source: .tab)])
    }

    @Test func codelessTabAndTheMeetApp() {
        let codeless = MeetDetection.candidates(in: [window([("Meet - Microphone recording", false)], address: nil)], meetApp: nil)
        #expect(codeless == [MeetCandidate(code: nil, evidence: .weak, source: .tab)])
        // Selected but not drawn yet (a window that isn't on screen): its own address gives the code.
        let undrawn = MeetDetection.candidates(
            in: [window([("Meet - Microphone recording", true)], address: "meet.google.com/abc-defg-hij?authuser=0")], meetApp: nil)
        #expect(undrawn == [MeetCandidate(code: "abc-defg-hij", evidence: .strong, source: .tab)])
        // Not when the selected tab's title names another meeting.
        let mismatch = MeetDetection.candidates(
            in: [window([("Meet – zzz-zzzz-zzz - Microphone recording", true)], address: "meet.google.com/abc-defg-hij")], meetApp: nil)
        #expect(mismatch == [MeetCandidate(code: "zzz-zzzz-zzz", evidence: .weak, source: .tab)])
        // And never for a background tab.
        let background = MeetDetection.candidates(
            in: [window([("Docs", true), ("Meet - Microphone recording", false)], address: "meet.google.com/abc-defg-hij")], meetApp: nil)
        #expect(background == [MeetCandidate(code: nil, evidence: .weak, source: .tab)])
        #expect(MeetDetection.candidates(in: [], meetApp: .capturing) == [MeetCandidate(code: nil, evidence: .strong, source: .app)])
        #expect(MeetDetection.candidates(in: [], meetApp: .unknown) == [MeetCandidate(code: nil, evidence: .weak, source: .app)])
        #expect(MeetDetection.candidates(in: [], meetApp: .idle).isEmpty)
    }

    @Test func unreadableNotesAreWeakAtMost() {
        let tabs = [("Meet – abc-defg-hij - Grabando", true)]
        let found = MeetDetection.candidates(in: [window(tabs, address: "meet.google.com/abc-defg-hij")], meetApp: nil, notesReadable: false)
        #expect(found.map(\.evidence) == [.weak])
        // With the Meet app clearly capturing, a leftover Meet tab isn't guessed at.
        let withApp = MeetDetection.candidates(in: [window(tabs, address: nil)], meetApp: .capturing, notesReadable: false)
        #expect(withApp.map(\.source) == [.app])
    }

    @Test func captureIndicatorAndMeetApp() {
        #expect(MeetDetection.isCaptureIndicator("This page is accessing your microphone."))
        #expect(MeetDetection.isCaptureIndicator("This page is accessing your camera and microphone."))
        #expect(!MeetDetection.isCaptureIndicator("This page is accessing your camera."))
        #expect(MeetDetection.isMeetApp(bundleID: "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan", shortcutURL: nil))
        #expect(MeetDetection.isMeetApp(bundleID: "com.microsoft.edgemac.app.other", shortcutURL: "https://meet.google.com/landing?lfhs=2"))
        #expect(!MeetDetection.isMeetApp(bundleID: "com.google.Chrome.app.hnpfjngllnobngcgfapefoaidbinmjnm", shortcutURL: "https://web.whatsapp.com/"))
    }

    #if !APP_STORE
    @Test func scanLimitsMakeTheReadPartial() {
        // Time running out before the Meet tab is reached: the read says so.
        var late = MeetInspector.Reading(deadline: .distantPast)
        let lateGoesOn = late.visit()
        #expect(!lateGoesOn)
        #expect(!late.complete)
        // So does a tab strip bigger than the node limit.
        var big = MeetInspector.Reading(deadline: .distantFuture)
        for _ in 0..<3_000 { _ = big.visit() }
        #expect(big.complete)
        let bigGoesOn = big.visit()
        #expect(!bigGoesOn)
        #expect(!big.complete)
    }
    #endif

    @Test func logSummaryHasNoCodes() {
        #expect(MeetDetection.summary([]) == "no Meet call")
        let found = [MeetCandidate(code: "abc-defg-hij", evidence: .strong, source: .tab),
                     MeetCandidate(code: nil, evidence: .weak, source: .tab),
                     MeetCandidate(code: nil, evidence: .weak, source: .app)]
        #expect(MeetDetection.summary(found) == "Meet tab strong, Meet tab weak (no code yet), Meet app weak")
    }

    @Test func policyForEveryCombination() {
        for meet in AutoRecordPolicy.allCases {
            for browser in AutoRecordPolicy.allCases {
                #expect(MeetDetection.effectivePolicy(evidence: .strong, meet: meet, browser: browser) == meet)
                #expect(MeetDetection.effectivePolicy(evidence: .none, meet: meet, browser: browser) == browser)
                let weak = MeetDetection.effectivePolicy(evidence: .weak, meet: meet, browser: browser)
                #expect(weak != .automatic)  // weak evidence never records on its own
                #expect(weak == ((meet == .off || browser == .off) ? .off : .ask))
            }
        }
    }
}

// MARK: - Sessions

@Suite struct CallTrackerTests {
    private struct Driver {
        var tracker: CallTracker
        var sequence = 0
        init() {
            var count = 0
            tracker = CallTracker(makeID: {
                count += 1
                return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", count))!
            })
        }
        mutating func poll(_ t: Double, apps: Set<CallApp> = [], _ browsers: [String: BrowserScan] = [:]) -> [CallTracker.Event] {
            sequence += 1
            return tracker.update(MicObservation(apps: apps, browsers: browsers), at: Date(timeIntervalSince1970: t), sequence: sequence)
        }
        /// Polls once a second from `from` up to `to`, collecting events.
        mutating func run(_ from: Int, _ to: Int, apps: Set<CallApp> = [], _ browsers: [String: BrowserScan] = [:]) -> [CallTracker.Event] {
            (from...to).flatMap { poll(Double($0), apps: apps, browsers) }
        }
    }

    private let chrome = "com.google.Chrome|100"
    private func meet(_ code: String?, _ evidence: MeetEvidence = .strong) -> MeetCandidate {
        MeetCandidate(code: code, evidence: evidence, source: .tab)
    }
    private func started(_ events: [CallTracker.Event]) -> [CallSession] {
        events.compactMap { if case .started(let s) = $0 { return s } else { return nil } }
    }
    private func ended(_ events: [CallTracker.Event]) -> [CallSession] {
        events.compactMap { if case .ended(let s) = $0 { return s } else { return nil } }
    }
    private func updated(_ events: [CallTracker.Event]) -> [CallSession] {
        events.compactMap { if case .updated(let s) = $0 { return s } else { return nil } }
    }

    @Test func teamsStartsAfter3sAndEndsAfter6s() {
        var d = Driver()
        #expect(started(d.run(0, 2, apps: [.teams])).isEmpty)
        let teams = started(d.run(3, 3, apps: [.teams]))
        #expect(teams.map(\.app) == [.teams])
        #expect(ended(d.run(4, 8)).isEmpty)
        #expect(ended(d.run(9, 9)).map(\.id) == teams.map(\.id))
    }

    @Test func meetThenVoiceTypingThenMeetEndsThenAnotherMeet() {
        var d = Driver()
        let a = started(d.run(0, 9, [chrome: .complete([meet("aaa-aaaa-aaa")])]))
        #expect(a.map(\.app) == [.meet])
        #expect(a.first?.meetingCode == "aaa-aaaa-aaa")
        // Meet left; voice typing keeps Chrome's mic (not a Meet tab, so not a candidate).
        let afterLeaving = d.run(10, 25, [chrome: .complete([])])
        #expect(ended(afterLeaving).map(\.id) == a.map(\.id))
        #expect(started(afterLeaving).isEmpty)  // the leftover isn't offered as a browser call
        // A second Meet while Docs still holds the mic is still found.
        let b = started(d.run(26, 30, [chrome: .complete([meet("bbb-bbbb-bbb")])]))
        #expect(b.map(\.meetingCode) == ["bbb-bbbb-bbb"])
    }

    @Test func voiceTypingThenMeetJoins() {
        var d = Driver()
        let plain = started(d.run(0, 4, [chrome: .complete([])]))
        #expect(plain.map(\.app) == [.browser])
        let events = d.run(5, 9, [chrome: .complete([meet("aaa-aaaa-aaa")])])
        #expect(started(events).map(\.app) == [.meet])
        #expect(ended(events).isEmpty)  // the browser call isn't ended by the Meet one
    }

    @Test func newCodeOnTheSameTabIsANewSession() {
        var d = Driver()
        let first = started(d.run(0, 10, [chrome: .complete([meet("aaa-aaaa-aaa")])]))
        let events = d.run(11, 17, [chrome: .complete([meet("ccc-cccc-ccc")])])
        #expect(ended(events).map(\.id) == first.map(\.id))
        let second = started(events)
        #expect(second.map(\.meetingCode) == ["ccc-cccc-ccc"])
        #expect(second.first?.id != first.first?.id)
    }

    @Test func twoMeetingsAtOnceAreSeparate() {
        var d = Driver()
        let a = started(d.run(0, 3, [chrome: .complete([meet("aaa-aaaa-aaa")])]))
        let events = d.run(4, 20, [chrome: .complete([meet("aaa-aaaa-aaa"), meet("bbb-bbbb-bbb")])])
        #expect(started(events).map(\.meetingCode) == ["bbb-bbbb-bbb"])
        #expect(ended(events).isEmpty)  // another meeting never ends the first
        #expect(d.tracker.isActive(a[0].id))
    }

    @Test func incompleteScansNeverEndAMeeting() {
        var d = Driver()
        let a = started(d.run(0, 3, [chrome: .complete([meet("aaa-aaaa-aaa")])]))
        // The scan stops (time or size limit) before reaching the Meet tab.
        #expect(ended(d.run(4, 30, [chrome: .partial([])])).isEmpty)
        #expect(ended(d.run(31, 60, [chrome: .unavailable])).isEmpty)
        // Only complete scans run the clock, and an unknown one resets it.
        #expect(ended(d.run(61, 64, [chrome: .complete([])])).isEmpty)
        #expect(ended(d.run(65, 65, [chrome: .partial([])])).isEmpty)
        #expect(ended(d.run(66, 71, [chrome: .complete([])])).isEmpty)
        #expect(ended(d.run(72, 72, [chrome: .complete([])])).map(\.id) == a.map(\.id))
    }

    @Test func micReleaseEndsEverything() {
        var d = Driver()
        _ = d.run(0, 3, [chrome: .complete([meet("aaa-aaaa-aaa")])])
        _ = d.run(4, 7, [chrome: .unavailable])
        #expect(ended(d.run(8, 12)).isEmpty)
        #expect(ended(d.run(13, 13)).map(\.app) == [.meet])
    }

    @Test func staleResultsAreIgnored() {
        var d = Driver()
        _ = d.run(0, 3, [chrome: .complete([meet("aaa-aaaa-aaa")])])
        let before = d.tracker.sessions
        let late = d.tracker.update(MicObservation(browsers: [chrome: .complete([meet("zzz-zzzz-zzz")])]),
                                    at: Date(timeIntervalSince1970: 100), sequence: 1)
        #expect(late.isEmpty)
        #expect(d.tracker.sessions == before)
    }

    @Test func evidenceImprovesInTheSameSessionAndNeverDrops() {
        var d = Driver()
        let weak = started(d.run(0, 3, [chrome: .complete([meet("aaa-aaaa-aaa", .weak)])]))
        #expect(weak.map(\.evidence) == [.weak])
        let events = d.run(4, 4, [chrome: .complete([meet("aaa-aaaa-aaa", .strong)])])
        #expect(started(events).isEmpty)
        #expect(updated(events).map(\.id) == weak.map(\.id))
        #expect(updated(events).map(\.evidence) == [.strong])
        // Switching back to another tab (title only) doesn't lower it.
        #expect(d.run(5, 10, [chrome: .complete([meet("aaa-aaaa-aaa", .weak)])]).isEmpty)
        #expect(d.tracker.session(weak[0].id)?.evidence == .strong)
    }

    @Test func codelessTabGetsItsCodeInTheSameSession() {
        var d = Driver()
        let s = started(d.run(0, 3, [chrome: .complete([meet(nil, .weak)])]))
        #expect(s.map(\.meetingCode) == [nil])
        let events = d.run(4, 4, [chrome: .complete([meet("aaa-aaaa-aaa", .strong)])])
        #expect(started(events).isEmpty)
        #expect(updated(events).map(\.id) == s.map(\.id))
        #expect(updated(events).first?.meetingCode == "aaa-aaaa-aaa")
    }

    @Test func movedOrDuplicatedTabsKeepTheSession() {
        // Moving a tab to another window or reordering it changes nothing the
        // tracker sees: the meeting is the code. The same code twice is one candidate.
        var d = Driver()
        let a = started(d.run(0, 3, [chrome: .complete([meet("aaa-aaaa-aaa")])]))
        #expect(d.run(4, 30, [chrome: .complete([meet("aaa-aaaa-aaa", .weak)])]).isEmpty)
        #expect(d.tracker.isActive(a[0].id))
    }

    @Test func twoBrowsersAreIndependent() {
        var d = Driver()
        let brave = "com.brave.Browser|200"
        let both = started(d.run(0, 3, [chrome: .complete([meet("aaa-aaaa-aaa")]), brave: .complete([meet("bbb-bbbb-bbb")])]))
        #expect(Set(both.compactMap(\.browser)) == [chrome, brave])
        let events = d.run(4, 10, [brave: .complete([meet("bbb-bbbb-bbb")])])
        #expect(ended(events).map(\.browser) == [chrome])
    }

    @Test func browserCallWhenTabsCantBeRead() {
        var d = Driver()
        let safari = "com.apple.Safari|300"
        #expect(started(d.run(0, 3, [safari: .unavailable])).map(\.app) == [.browser])
    }
}

// MARK: - Offers, settings, calendar

@Suite struct MeetCallTests {
    @Test func callAppAdditions() {
        #expect(CallApp.allCases == [.teams, .zoom, .meet, .browser])
        #expect(CallApp.meet.bundlePrefixes.isEmpty)
        #expect(CallApp.matching(bundleID: "com.google.Chrome.helper") == .browser)
        #expect(CallApp.matching(bundleID: "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan") == .browser)
        #expect(CallApp.browserFamily(of: "com.google.Chrome.helper") == "com.google.Chrome")
        #expect(CallApp.browser.callTitle == "Browser call")
        #expect(CallApp.meet.callTitle == "Google Meet call")
        #if APP_STORE
        #expect(!CallApp.shown.contains(.meet))
        #else
        #expect(CallApp.shown == CallApp.allCases)
        #endif
    }

    @MainActor @Test func upgradersKeepTheirBrowserChoiceForMeet() {
        #expect(CallWatcher.meetPolicy(saved: ["browser": "off"]) == .off)
        #expect(CallWatcher.meetPolicy(saved: ["browser": "ask", "meet": "automatic"]) == .automatic)
        #expect(CallWatcher.meetPolicy(saved: [:]) == nil)  // new install: Ask me first
    }

    @MainActor @Test func improvedEvidenceDoesntAskAgain() {
        let id = UUID(), other = UUID()
        #expect(CallWatcher.actsOnUpdate(id, answered: [], offered: [], recording: nil, deferred: nil))
        #expect(!CallWatcher.actsOnUpdate(id, answered: [id], offered: [], recording: nil, deferred: nil))  // Ignore stays
        #expect(!CallWatcher.actsOnUpdate(id, answered: [], offered: [id], recording: nil, deferred: nil))  // one prompt at most
        #expect(!CallWatcher.actsOnUpdate(id, answered: [], offered: [], recording: id, deferred: nil))  // no restart
        #expect(!CallWatcher.actsOnUpdate(id, answered: [], offered: [], recording: nil, deferred: id))
        #expect(CallWatcher.actsOnUpdate(id, answered: [other], offered: [other], recording: other, deferred: other))
    }

    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func event(_ title: String, start: Double, end: Double, codes: Set<String>) -> CalendarLookup.Choice {
        CalendarLookup.Choice(start: now.addingTimeInterval(start * 60), score: 3, yours: false, title: title,
                              end: now.addingTimeInterval(end * 60), meetCodes: codes)
    }

    @Test func calendarEventByMeetCode() {
        let code = "abc-defg-hij"
        let choices = [
            event("Other, closer", start: -1, end: 30, codes: ["zzz-zzzz-zzz"]),
            event("Upcoming", start: 20, end: 50, codes: [code]),
            event("Running", start: -30, end: 15, codes: [code]),
        ]
        #expect(CalendarLookup.pickByMeetCode(choices, code: code, at: now) == 2)  // in progress first
        #expect(CalendarLookup.pickByMeetCode(Array(choices.prefix(2)), code: code, at: now) == 1)  // else upcoming within the hour
        let overran = [event("Ended 20 min ago", start: -80, end: -20, codes: [code])]
        #expect(CalendarLookup.pickByMeetCode(overran, code: code, at: now) == 0)
        let tooOld = [event("Ended 2 h ago", start: -180, end: -120, codes: [code])]
        #expect(CalendarLookup.pickByMeetCode(tooOld, code: code, at: now) == nil)
        #expect(CalendarLookup.pickByMeetCode(choices, code: "nop-nopq-nop", at: now) == nil)  // no match: the usual choice
    }
}
