import Foundation
import Testing
@testable import Wingman

@MainActor
@Suite struct VoiceLibraryTests {
    private let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("wingman-test-voices-\(UUID().uuidString).json")

    private func voice(_ seed: Int) -> [Float] {
        (0..<256).map { Float(sin(Double($0 * (seed + 1)))) }
    }

    @Test func knownVoiceIsRecognizedWithoutInvitees() {
        let library = VoiceLibrary(file: file)
        library.learn("Ana", voiceprint: voice(1))
        let match = library.match(["Them 1": voice(1)], invitees: [])["Them 1"]
        #expect(match?.name == "Ana")
        #expect(match?.confident == true)
    }

    @Test func uninvitedPersonIsOnlySuggested() {
        // The meeting has invitees, none of them known: Ana wasn't invited.
        let library = VoiceLibrary(file: file)
        library.learn("Ana", voiceprint: voice(1))
        let match = library.match(["Them 1": voice(1)], invitees: ["Bruno Díaz"])["Them 1"]
        #expect(match?.name == "Ana")
        #expect(match?.confident == false)
    }

    @Test func invitedPersonIsLabeled() {
        let library = VoiceLibrary(file: file)
        library.learn("Ana López", voiceprint: voice(1))
        let match = library.match(["Them 1": voice(1)], invitees: ["ana lópez (Marketing)"])["Them 1"]
        #expect(match?.confident == true)
    }

    @Test func undoForgetsANewPerson() throws {
        let library = VoiceLibrary(file: file)
        let undo = try #require(library.learn("Wrong Name", voiceprint: voice(1)))
        library.undo(undo)
        #expect(library.people.isEmpty)
    }

    @Test func undoTakesBackOnlyThatVoice() throws {
        let library = VoiceLibrary(file: file)
        library.learn("Ana", voiceprint: voice(1))
        let before = library.people[0]
        let undo = try #require(library.learn("Ana", voiceprint: voice(2)))
        #expect(library.people[0].meetings == 2)
        library.undo(undo)
        #expect(library.people[0].meetings == 1)
        #expect(VoiceLibrary.similarity(library.people[0].voiceprint, before.voiceprint) > 0.99)
    }

    @Test func correctingOneOfTwoLabelsKeepsThePerson() throws {
        // One person split into two voices, both named Ana; then the first is corrected.
        let library = VoiceLibrary(file: file)
        let first = try #require(library.learn("Ana", voiceprint: voice(1)))
        library.learn("Ana", voiceprint: voice(2))
        library.undo(first)
        #expect(library.people.count == 1)
        #expect(library.people[0].meetings == 1)
        #expect(VoiceLibrary.similarity(library.people[0].voiceprint, voice(2)) > 0.99)
    }
}

@Suite struct CalendarLookupTests {
    @Test func cancelledTitles() {
        #expect(CalendarLookup.isCancelledTitle("Canceled: Weekly sync"))
        #expect(CalendarLookup.isCancelledTitle("  Cancelado: Revisión"))
        #expect(!CalendarLookup.isCancelledTitle("Weekly sync"))
        #expect(!CalendarLookup.isCancelledTitle(nil))
    }

    @Test func callLinksOnlyOnTheServicesOwnDomains() {
        #expect(CalendarLookup.isCallLink(URL(string: "https://acme.zoom.us/j/123")!))
        #expect(CalendarLookup.isCallLink(URL(string: "https://teams.microsoft.com/l/meetup-join/x")!))
        // Typed without a scheme, links come out of the text detector as http.
        #expect(CalendarLookup.isCallLink(URL(string: "http://meet.google.com/abc-defg-hij")!))
        #expect(!CalendarLookup.isCallLink(URL(string: "https://evilzoom.us/j/123")!))
        #expect(!CalendarLookup.isCallLink(URL(string: "https://zoom.us.example.com/j/123")!))
        #expect(!CalendarLookup.isCallLink(URL(string: "zoommtg://zoom.us/join")!))
    }

    private let ten = Date(timeIntervalSince1970: 1_790_000_000)
    private func choice(_ title: String, at start: Date, score: Int = 3, yours: Bool = false) -> CalendarLookup.Choice {
        CalendarLookup.Choice(start: start, score: score, yours: yours, title: title)
    }

    @Test func sameStartPrefersTheMeetingYouOrganized() {
        let choices = [choice("Budget review", at: ten), choice("Team sync", at: ten, score: 2, yours: true)]
        // Yours wins even with no call link, over a more meeting-like one at the same time.
        #expect(CalendarLookup.pick(choices, at: ten) == 1)
    }

    @Test func sameStartWithNoneOfYoursGoesByTitle() {
        let choices = [choice("zeta planning", at: ten), choice("Alpha 10", at: ten), choice("alpha 9", at: ten)]
        #expect(CalendarLookup.pick(choices, at: ten) == 2)  // "alpha 9" before "Alpha 10"
    }

    @Test func differentStartsKeepTheClosestMeeting() {
        let choices = [choice("Earlier, yours", at: ten.addingTimeInterval(-3600), yours: true),
                       choice("Now", at: ten.addingTimeInterval(120))]
        #expect(CalendarLookup.pick(choices, at: ten) == 1)
        #expect(CalendarLookup.pick([], at: ten) == nil)
    }
}

#if !APP_STORE
@Suite struct MuteLabelsTests {
    @Test func teamsLabels() {
        #expect(MuteLabels.isMuted("Unmute (⌘ ⇧ M)") == true)
        #expect(MuteLabels.isMuted("Mute (⌘ ⇧ M)") == false)
        #expect(MuteLabels.hasTeamsShortcut("Mute (⌘ ⇧ M)"))
        #expect(!MuteLabels.hasTeamsShortcut("Mute"))
    }

    @Test func spanishLabels() {
        #expect(MuteLabels.isMuted("Silenciar") == false)
        #expect(MuteLabels.isMuted("Dejar de silenciar") == true)
        #expect(MuteLabels.isMuted("Activar micrófono") == true)
    }

    @Test func portugueseZoomPolarity() {
        // "Ativar mudo" = turn mute on (you're unmuted); "Desativar mudo" = you're muted.
        #expect(MuteLabels.isMuted("Ativar mudo") == false)
        #expect(MuteLabels.isMuted("Desativar mudo") == true)
    }

    @Test func germanLabels() {
        #expect(MuteLabels.isMuted("Audio stummschalten") == false)
        #expect(MuteLabels.isMuted("Stummschaltung aufheben") == true)
    }

    @Test func otherControlsAreIgnored() {
        #expect(MuteLabels.isMuted("Camera") == nil)
        #expect(MuteLabels.isMuted("Leave") == nil)
    }

    @Test func fallbackNeedsAMicrophoneLabel() {
        #expect(MuteLabels.isAboutMicrophone("Unmute"))
        #expect(MuteLabels.isAboutMicrophone("Activar micrófono"))
        #expect(!MuteLabels.isAboutMicrophone("Activar"))  // a bare "turn on" could be anything
        #expect(!MuteLabels.isAboutMicrophone("Activar cámara"))
        #expect(!MuteLabels.isAboutMicrophone("Activar personas"))
    }
}
#endif

@Suite struct FeedbackTests {
    @Test func formLinkPrefillsVersionAndSystem() throws {
        let url = Feedback.url(.problem)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(url.absoluteString.hasPrefix("https://github.com/daniel-wing/wingman-beta/issues/new?"))
        #expect(items.first { $0.name == "template" }?.value == "problem.yml")
        #expect(items.first { $0.name == "system" }?.value?.hasPrefix("macOS ") == true)
        #expect(items.contains { $0.name == "version" })
    }
}

@Suite struct LogRedactionTests {
    @Test func homeFolderAndMeetingNamesAreLeftOut() {
        let home = NSHomeDirectory()
        let message = "couldn't keep the me track: Error Domain=NSCocoaErrorDomain Code=516 \"“wingman-1.wav” couldn’t be moved\" UserInfo={NSFilePath=\(home)/Meeting Notes/2026-10-06/08-01 Acme Q3 pricing review-me.wav, NSUnderlyingError=...}"
        let redacted = Log.redacted(message)
        #expect(!redacted.contains(home))
        #expect(!redacted.contains("Acme"))
        #expect(redacted.contains("~/Meeting Notes/…"))
        #expect(redacted.contains("Code=516"))
    }

    @Test func encodedPathsAndQuotedFileNamesAreLeftOut() {
        let message = "couldn't write the note: Error Domain=NSCocoaErrorDomain Code=640 \"You can’t save the file “08-00 Acme Corp pricing review.md” because the volume is full.\" UserInfo={NSURL=file:///Users/x/Meeting%20Notes/2026-10-06/08-00%20Acme%20Corp%20pricing%20review.md}"
        let redacted = Log.redacted(message)
        #expect(!redacted.contains("Acme"))
        #expect(redacted.contains("Code=640"))
    }
}
