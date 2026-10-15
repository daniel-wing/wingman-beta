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

    @Test func forgettingOnlyShowsAsDoneOnceItsOnDisk() throws {
        // The review's reproduction: a folder Wingman can't write to.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wingman-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let file = folder.appendingPathComponent("voices.json")
        let library = VoiceLibrary(file: file)
        learn(library, "Ana", voice(1))
        learn(library, "Bruno", voice(2))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)

        library.forget(library.people[0])
        #expect(library.people.count == 2)  // still listed: forgetting again retries
        #expect(library.problem != nil)
        library.forgetEveryone()
        #expect(library.people.count == 2)
        #expect(library.problem != nil)
        #expect(VoiceLibrary(file: file).people.count == 2)  // what's on disk, as shown

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        library.forgetEveryone()
        #expect(library.people.isEmpty)
        #expect(library.problem == nil)
        #expect(VoiceLibrary(file: file).people.isEmpty)
    }

    @Test func knownVoiceIsRecognizedWithoutInvitees() {
        let library = VoiceLibrary(file: file)
        learn(library, "Ana", voice(1))
        let match = library.match(["Them 1": voice(1)], invitees: [])["Them 1"]
        #expect(match?.name == "Ana")
        #expect(match?.confident == true)
    }

    @Test func uninvitedPersonIsOnlySuggested() {
        // The meeting has invitees, none of them known: Ana wasn't invited.
        let library = VoiceLibrary(file: file)
        learn(library, "Ana", voice(1))
        let match = library.match(["Them 1": voice(1)], invitees: ["Bruno Díaz"])["Them 1"]
        #expect(match?.name == "Ana")
        #expect(match?.confident == false)
    }

    @Test func invitedPersonIsLabeled() {
        let library = VoiceLibrary(file: file)
        learn(library, "Ana López", voice(1))
        let match = library.match(["Them 1": voice(1)], invitees: ["ana lópez (Marketing)"])["Them 1"]
        #expect(match?.confident == true)
    }

    /// A slightly different take of the same voice (another meeting).
    private func near(_ seed: Int, _ amount: Float = 0.3) -> [Float] {
        zip(voice(seed), voice(seed + 40)).map { $0 + amount * $1 }
    }

    @discardableResult
    private func learn(_ library: VoiceLibrary, _ name: String, _ print: [Float], meeting: UUID = UUID(),
                       speaker: UUID = UUID(), asNewPerson: Bool = false) -> VoiceLibrary.LearnOutcome {
        library.learn(name, voiceprint: print, meeting: meeting, speaker: speaker, asNewPerson: asNewPerson)
    }

    @Test func undoForgetsANewPerson() throws {
        let library = VoiceLibrary(file: file)
        let id = try #require(learn(library, "Wrong Name", voice(1)).contribution)
        library.undo(contribution: id)
        #expect(library.people.isEmpty)
    }

    @Test func undoTakesBackOnlyThatVoice() throws {
        let library = VoiceLibrary(file: file)
        learn(library, "Ana", voice(1))
        let before = library.people[0]
        let id = try #require(learn(library, "Ana", near(1)).contribution)
        #expect(library.people[0].meetings == 2)
        // Learning more after it doesn't stop it being taken back on its own.
        learn(library, "Ana", near(1, 0.2))
        library.undo(contribution: id)
        #expect(library.people[0].meetings == 2)
        #expect(library.people[0].contributions?.contains { $0.id == id } == false)
        #expect(VoiceLibrary.similarity(library.people[0].voiceprint, before.voiceprint) > 0.9)
    }

    @Test func sameSpeakerIsNeverLearnedTwice() throws {
        let library = VoiceLibrary(file: file)
        let meeting = UUID(), speaker = UUID()
        let first = learn(library, "Ana", voice(1), meeting: meeting, speaker: speaker)
        let again = learn(library, "Ana", voice(1), meeting: meeting, speaker: speaker)
        #expect(again == .alreadyLearned(person: library.people[0].id, contribution: try #require(first.contribution)))
        #expect(library.people[0].meetings == 1)
    }

    @Test func aDifferentVoiceWithAKnownNameIsntLearned() {
        // Two people called Ana: the second voice doesn't sound like the first.
        let library = VoiceLibrary(file: file)
        learn(library, "Ana", voice(1))
        guard case .soundsDifferent = learn(library, "ana", voice(2)) else {
            Issue.record("expected soundsDifferent")
            return
        }
        #expect(library.people.count == 1)
        #expect(library.people[0].meetings == 1)
        // Asked to, it becomes a second person with the same name.
        guard case .learned = learn(library, "Ana", voice(2), asNewPerson: true) else {
            Issue.record("expected learned")
            return
        }
        #expect(library.people.count == 2)
    }

    @Test func removingAMeetingsVoicesRecalculatesAndForgets() {
        let library = VoiceLibrary(file: file)
        let meeting = UUID()
        learn(library, "Ana", voice(1))
        learn(library, "Ana", near(1), meeting: meeting)
        learn(library, "Carlos", voice(3), meeting: meeting)
        let effect = library.effectOfRemoving(meetings: [meeting])
        #expect(effect.recalculated == ["Ana"])
        #expect(effect.forgotten == ["Carlos"])
        #expect(library.removeVoices(fromMeetings: [meeting]))
        #expect(library.people.map(\.name) == ["Ana"])
        #expect(library.people[0].meetings == 1)
        #expect(VoiceLibrary.similarity(library.people[0].voiceprint, voice(1)) > 0.99)
    }

    @Test func voicesFrom08BecomeOneLegacyContribution() throws {
        // A file 0.8 wrote: a person averaged over two meetings, no contributions.
        let sum = zip(voice(1), near(1)).map { a, b in a / 1 + b / 1 }
        let old = [VoiceLibrary.Person(id: UUID(), name: "Ana", voiceprint: VoiceLibrary.normalized(sum), meetings: 2,
                                       lastHeard: Date(), sum: sum)]
        try JSONEncoder().encode(old).write(to: file)
        let library = VoiceLibrary(file: file)
        let person = try #require(library.people.first)
        #expect(person.contributions?.count == 1)
        #expect(person.contributions?.first?.isLegacy == true)
        #expect(person.meetings == 2)
        #expect(VoiceLibrary.similarity(person.voiceprint, old[0].voiceprint) > 0.999)
        // New learning adds to it; taking that back leaves 0.8's voice.
        let id = try #require(learn(library, "Ana", near(1, 0.25)).contribution)
        #expect(library.people[0].meetings == 3)
        library.undo(contribution: id)
        #expect(library.people[0].meetings == 2)
        #expect(VoiceLibrary.similarity(library.people[0].voiceprint, old[0].voiceprint) > 0.999)
    }

    /// 0.9 → 0.8.2 (which rewrites voices.json without contributions, and may
    /// learn more) → 0.9: Delete Voices still removes exactly one meeting.
    @Test func aRoundTripThrough08KeepsWhichMeetingTaughtWhat() throws {
        struct OldPerson: Codable { let id: UUID; var name: String; var voiceprint: [Float]; var meetings: Int; var lastHeard: Date; var sum: [Float]? }
        let (m1, m2, m3) = (UUID(), UUID(), UUID())
        let library = VoiceLibrary(file: file)
        let first = try #require(learn(library, "Ana", voice(1), meeting: m1).contribution)
        learn(library, "Ana", near(1, 0.2), meeting: m2)
        learn(library, "Bo", voice(2), meeting: m3)
        // 0.8.2 opens and saves the file, learning Ana once more.
        var old = try JSONDecoder().decode([OldPerson].self, from: Data(contentsOf: file))
        let extra = VoiceLibrary.normalized(near(1, 0.25))
        old[0].sum = zip(old[0].sum!, extra).map(+)
        old[0].voiceprint = VoiceLibrary.normalized(old[0].sum!)
        old[0].meetings += 1
        try JSONEncoder().encode(old).write(to: file)

        let back = VoiceLibrary(file: file)
        let ana = try #require(back.people.first { $0.name == "Ana" })
        #expect(ana.meetings == 3)
        #expect(ana.contributions?.filter(\.isLegacy).count == 1)
        #expect(Set(ana.contributions?.compactMap(\.meeting) ?? []) == [m1, m2])
        #expect(back.untraceable([first]).isEmpty)
        #expect(back.removeVoices(fromMeetings: [m1]))
        let after = try #require(back.people.first { $0.name == "Ana" })
        #expect(after.meetings == 2)
        #expect(after.contributions?.contains { $0.meeting == m1 } == false)
        #expect(back.people.first { $0.name == "Bo" }?.meetings == 1)

        // Without the history file (deleted by hand), that link is gone, and
        // Wingman says so instead of claiming it removed it.
        try FileManager.default.removeItem(at: VoiceLibrary.historyFile(for: file))
        try JSONEncoder().encode(old).write(to: file)
        let lost = VoiceLibrary(file: file)
        #expect(lost.untraceable([first]) == [first])
    }

    @Test func forgettingEveryoneDeletesTheHistoryToo() throws {
        let library = VoiceLibrary(file: file)
        learn(library, "Ana", voice(1))
        let history = VoiceLibrary.historyFile(for: file)
        #expect(FileManager.default.fileExists(atPath: history.path))
        library.forgetEveryone()
        #expect(!FileManager.default.fileExists(atPath: history.path))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aFileFrom09StillReadsIn08() throws {
        // 0.8's Person, as it was: extra keys are ignored.
        struct OldPerson: Codable { let id: UUID; var name: String; var voiceprint: [Float]; var meetings: Int; var lastHeard: Date; var sum: [Float]? }
        let library = VoiceLibrary(file: file)
        learn(library, "Ana", voice(1))
        let old = try JSONDecoder().decode([OldPerson].self, from: Data(contentsOf: file))
        #expect(old.map(\.name) == ["Ana"])
        #expect(old[0].meetings == 1)
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

    @Test func punctuationInMeetingNamesDoesntLeakThem() {
        // The review's reproduction, and names with brackets, apostrophes and "(2)".
        for name in ["14-30 Acquisition, SecretTarget", "14-30 (2) Project Falcon", "09-00 [External] Acme buyout",
                     "10-00 Bob's exit talk", "11-00 Plan; Phase 2"] {
            let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
            let message = "Error Domain=NSCocoaErrorDomain Code=513 UserInfo={NSFilePath=/x/Meeting Notes/2026-10-07/\(name).md, NSURL=file:///x/Meeting%20Notes/2026-10-07/\(encoded)-me.wav}"
            let redacted = Log.redacted(message)
            for secret in ["SecretTarget", "Falcon", "Acme", "exit talk", "Phase"] {
                #expect(!redacted.contains(secret), "\(name): \(redacted)")
            }
            #expect(redacted.contains("Code=513"))
        }
    }

    @Test func errorsAreLoggedByDomainAndCode() {
        let error = NSError(domain: NSCocoaErrorDomain, code: 513, userInfo: [
            NSFilePathErrorKey: "/x/Meeting Notes/2026-10-07/14-30 Secret.md",
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 13),
        ])
        #expect(Log.describe(error) == "NSCocoaErrorDomain 513 (NSPOSIXErrorDomain 13)")
    }
}

@MainActor
@Suite struct FileNameTests {
    @Test func namesFitTheFileNameLimitInBytes() {
        let prefix = "17-07 (2) "
        for name in [String(repeating: "会", count: 80), String(repeating: "👨‍👩‍👧‍👦", count: 80),
                     String(repeating: "e\u{301}", count: 80), String(repeating: "a", count: 200)] {
            let safe = Recorder.fileSafe(name)
            #expect(!safe.isEmpty)
            #expect((prefix + safe + "-them.wav").utf8.count <= 255, "\(safe.utf8.count) bytes")
        }
        #expect(Recorder.fileSafe("Weekly: sync/review") == "Weekly  sync review")
        #expect(Recorder.fileSafe("  .Plan.  ") == "Plan")
    }
}
