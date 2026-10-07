import Foundation
import Testing
@testable import Wingman

@Suite struct ProblemReportTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let start = Date(timeIntervalSince1970: 1_791_379_500)  // 13:25:00 UTC

    private var context: ProblemReport.Context {
        ProblemReport.Context(version: "0.8.0 (8)", system: "macOS 26.6.2, Apple M1 Pro",
                              settings: ["Google Meet: Record automatically", "Browser calls: Ask me first"],
                              permissions: ["Microphone allowed", "Accessibility not allowed yet"],
                              meetChecks: ["com.google.Chrome: Meet tab strong; browser in en"])
    }

    @Test func reportOfACall() {
        var call = CallReport(id: UUID(), app: .meet, started: start)
        call.add("Seen: Google Meet (sure it's Meet)", at: start)
        call.add("Recording started", at: start.addingTimeInterval(1))
        call.add("Call ended", at: start.addingTimeInterval(185))
        call.ended = start.addingTimeInterval(185)
        call.outcome = .recorded
        #expect(call.menuTitle(timeZone: utc) == "13:25 Google Meet call — recorded")
        #expect(ProblemReport.text(sentence: "  It didn't stop. ", call: call, context: context, timeZone: utc) == """
        What went wrong: It didn't stop.

        Wingman 0.8.0 (8) · macOS 26.6.2, Apple M1 Pro

        Call: Google Meet call, 13:25–13:28
          13:25:00  Seen: Google Meet (sure it's Meet)
          13:25:01  Recording started
          13:28:05  Call ended

        Settings: Google Meet: Record automatically · Browser calls: Ask me first
        Permissions: Microphone allowed · Accessibility not allowed yet
        Meet check: com.google.Chrome: Meet tab strong; browser in en
        """)
    }

    @Test func reportWithoutACallOrSentence() {
        let text = ProblemReport.text(sentence: "", call: nil, context: context, timeZone: utc)
        #expect(text.hasPrefix("What went wrong: (not described)\n\nWingman 0.8.0 (8)"))
        #expect(!text.contains("Call:"))
        var going = CallReport(id: UUID(), app: .teams, started: start)
        going.add("Seen: Microsoft Teams is using the microphone", at: start)
        #expect(ProblemReport.text(sentence: "x", call: going, context: context, timeZone: utc)
            .contains("Call: Teams call, 13:25 (still going)"))
    }

    @MainActor @Test func whatWingmanDidAndWhy() {
        let meet = CallSession(id: UUID(), app: .meet, evidence: .strong, meetingCode: "abc-defg-hij", browser: "c|1")
        var unsure = meet
        unsure.evidence = .weak
        let teams = CallSession(id: UUID(), app: .teams, evidence: .strong, meetingCode: nil, browser: nil)
        #expect(CallWatcher.offerStep(meet, policy: .automatic, meet: .automatic, browser: .ask)
            == "Recording automatically: Google Meet is set to Record automatically")
        #expect(CallWatcher.offerStep(unsure, policy: .ask, meet: .automatic, browser: .ask)
            == "Asked whether to record: not sure it's Google Meet, so it does at most Ask me first (Google Meet: Record automatically, Browser calls: Ask me first)")
        #expect(CallWatcher.offerStep(teams, policy: .off, meet: .ask, browser: .ask)
            == "Not recorded: Microsoft Teams is set to Off")
        #expect(CallWatcher.seen(meet) == "Google Meet (sure it's Meet)")
        #expect(CallWatcher.seen(teams) == "Microsoft Teams is using the microphone")
        // Reports never carry the meeting code.
        #expect(!CallWatcher.seen(meet).contains("abc-defg-hij"))
        #expect(!CallWatcher.offerStep(meet, policy: .ask, meet: .ask, browser: .ask).contains("abc-defg-hij"))
    }

    @Test func githubFormAddress() {
        let url = Feedback.problemURL(sentence: "It didn't stop", report: "Call: Google Meet call")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "template" }?.value == "problem.yml")
        #expect(items.first { $0.name == "what" }?.value == "It didn't stop")
        #expect(items.first { $0.name == "log" }?.value?.contains("Call: Google Meet call") == true)
        let long = Feedback.problemURL(sentence: "", report: String(repeating: "x", count: 20_000))
        #expect(long.absoluteString.count < 8_000)
    }
}
