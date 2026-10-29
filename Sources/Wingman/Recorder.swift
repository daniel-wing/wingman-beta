import AppKit
import AVFoundation
import FluidAudio
import Foundation
import Observation

struct TranscriptLine: Identifiable, Equatable {
    let id: UUID
    var speaker: Speaker
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var isFinal: Bool
    /// Which remote voice said this, once speakers have been separated.
    var voice: Int? = nil
    var confidence: Float = 1

    /// Below this the model is often guessing: on real calls clear lines score
    /// 0.85–0.95, while misheard ones (wrong language, garbled) score 0.4–0.75.
    static let unclearBelow: Float = 0.75
    /// Single-word lines ("Oh", "Hmm") often score low but rarely matter, so they aren't flagged.
    /// Re-transcribed after the meeting because it came out in a disabled language.
    var rechecked = false
    /// The speech engine failed on the final pass: the text is what was heard so far.
    var incomplete = false
    /// Your line looks like the call's audio coming back through the speakers,
    /// but not clearly enough to drop it.
    var possibleEcho = false

    var isUnclear: Bool {
        isFinal && !rechecked && confidence < Self.unclearBelow && text.split(whereSeparator: \.isWhitespace).count > 1
    }

    var label: String {
        if speaker == .them, let voice { return "Them \(voice)" }
        return speaker.rawValue
    }
}

@MainActor
@Observable
final class Recorder {
    enum Phase: Equatable {
        case idle
        case preparing(String)
        case recording
        case finishing(String)
    }

    private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { onPhaseChange?(oldValue, phase) } }
    }
    /// Told about every phase change (set by the call watcher).
    var onPhaseChange: ((_ old: Phase, _ new: Phase) -> Void)?
    /// Wingman is quitting: finish what's running, start nothing new.
    private(set) var quitting = false
    /// A one-time model download in progress, e.g. "Downloading the speech
    /// model (one time, ~0.6 GB)…"; nil when there's none.
    private(set) var modelStatus: String?
    private var preparingModels = false
    #if !NO_DIAGNOSTICS
    var stressLines: [TranscriptLine] {
        get { focus?.lines ?? [] }
        set { focus?.replaceLines(newValue) }
    }
    var stressLineCount: Int { focus?.lines.count ?? 0 }
    private static let stressLiveID = UUID()
    /// A throwaway meeting in the scratch folder, shown as if recording.
    func stressMeeting() -> Meeting {
        let base = Self.scratchFile("stress-\(UUID().uuidString)")
        let meeting = Meeting(recorder: self, stage: .recording, origin: 0, started: Date(), name: "Stress test", event: nil,
                              nameFromCalendar: false, base: base, prefix: "stress", tracksKept: false, meAudio: nil, themAudio: nil,
                              sourceFile: "stress")
        meetings.append(meeting)
        current = meeting
        return meeting
    }
    func stressLiveLine(_ text: String, at start: TimeInterval) {
        guard let meeting = focus else { return }
        var lines = meeting.lines
        let line = TranscriptLine(id: Self.stressLiveID, speaker: .them, start: start, end: start + 3, text: text, isFinal: false)
        if let i = lines.firstIndex(where: { $0.id == Self.stressLiveID }) { lines[i] = line } else { lines.append(line) }
        meeting.replaceLines(lines)
    }
    #endif
    private(set) var warning: String?
    /// Ignore the microphone, e.g. while playing back a recorded call through
    /// the speakers. Lasts until unmuted, across recordings.
    var micMuted = false {
        didSet {
            if micMuted != oldValue { Log.write("Wingman mute \(micMuted ? "on" : "off")") }
            applyMute()
        }
    }
    /// The call app the user is muted in (Teams/Zoom), when Wingman follows it.
    private(set) var callMuted: CallApp?
    /// "Transcribe anyway": ignore the call app's mute until it next changes.
    private(set) var callMuteIgnored = false
    /// Why Wingman can't follow the call app's mute right now, if it's trying.
    var callMuteProblem: String?
    /// A calm note instead of a problem: following the mute isn't available for
    /// this kind of call (Google Meet, other browser calls), so there's nothing to fix.
    var callMuteNote: String?

    /// Muted by the user in Wingman, or in the call app Wingman is following.
    var effectiveMuted: Bool { micMuted || (callMuted != nil && !callMuteIgnored) }

    private func applyMute() {
        muteFlag.set(effectiveMuted)
        if effectiveMuted { micSilent = false }
    }

    /// Called by the call-mute monitor with the app the user is muted in, or nil
    /// when they're unmuted there.
    func followCallMute(_ app: CallApp?) {
        // A real unmute ends "Transcribe anyway"; the next mute is followed again.
        if app == nil { callMuteIgnored = false }
        guard app != callMuted else { return }
        let wasMuted = callMuted != nil
        callMuted = app
        if let app {
            Log.write("\(app.shortName.capitalized) mute on — Wingman following")
            // Detection lags slightly behind the click: erase what was said just before.
            // The erase travels with the audio, so it lands exactly where the mute was noticed.
            if !wasMuted, !callMuteIgnored {
                slots[.me]?.redact(seconds: 0.5)
                feeds[.me]?.yield(.redact(seconds: 0.5))
            }
        } else {
            Log.write("call mute off — Wingman following")
        }
        applyMute()
    }

    /// The monitor isn't following right now (control not found, no permission,
    /// call over, following off): never stay muted on a stale reading.
    /// `keepOverride` is for a read failure in the middle of a call: "Transcribe
    /// anyway" then still holds once the mute can be read again. Anything else
    /// (the call ended, following turned off) ends it.
    func stopFollowingCallMute(keepOverride: Bool) {
        if !keepOverride { callMuteIgnored = false }
        guard callMuted != nil else { return }
        callMuted = nil
        Log.write("call mute unknown — Wingman not following")
        applyMute()
    }

    func transcribeDespiteCallMute() {
        callMuteIgnored = true
        Log.write("transcribing despite call mute (user choice)")
        applyMute()
    }

    /// Ends "Transcribe me anyway": follow the call app's mute again.
    func followCallMuteAgain() {
        guard callMuteIgnored else { return }
        callMuteIgnored = false
        Log.write("following call mute again (user choice)")
        applyMute()
    }
    private let muteFlag = LockedFlag()
    /// macOS muted Wingman's microphone itself (e.g. an AirPods press).
    private(set) var systemMuted = false
    /// The microphone has sent only silence for a while although Wingman isn't muted.
    private(set) var micSilent = false
    /// No call audio has arrived for a minute although something is playing —
    /// usually the System Audio Recording permission. Cleared as soon as it arrives.
    private(set) var callAudioMissing = false
    /// When the microphone last delivered any non-zero sample.
    private let micSound = LockedTime()
    /// How loud the microphone is, logged now and then (a quiet "Me" track
    /// is otherwise only noticed after the meeting).
    private let micLevel = LockedLevel()
    private var muteObserver: NSObjectProtocol?
    /// Short status note, e.g. "Switched to AirPods Pro at 00:12:03".
    var notice: String?
    private(set) var lastError: String?

    /// People whose voices can be recognized in later meetings.
    let voices = VoiceLibrary()
    /// What Wingman keeps about each meeting's speakers: names, and for 180 days
    /// the voices of those not named yet, so they can be named later.
    let index = MeetingIndex()
    /// Remember the voices of people the user names, and recognize them later.
    var recognizeVoices: Bool {
        didSet {
            UserDefaults.standard.set(recognizeVoices, forKey: "recognizeVoices")
            // Off means no voices kept for later, and none looked for in older meetings.
            if oldValue, !recognizeVoices { index.deleteAllVoices(because: .notAllowed) }
        }
    }
    /// Look up the current calendar event for names and attendees.
    var useCalendar: Bool {
        didSet { UserDefaults.standard.set(useCalendar, forKey: "useCalendar") }
    }

    /// Save the meeting's audio: one combined, compressed file that plays anywhere.
    var keepAudio: Bool {
        didSet { UserDefaults.standard.set(keepAudio, forKey: "keepAudio") }
    }
    /// Also keep the separate mic and call-audio tracks (recorded as WAV, kept as .m4a).
    var keepSeparateTracks: Bool {
        didSet { UserDefaults.standard.set(keepSeparateTracks, forKey: "keepSeparateTracks") }
    }
    /// Move meetings' audio older than this many days to the Trash (0: never).
    var removeAudioAfterDays: Int {
        didSet {
            UserDefaults.standard.set(removeAudioAfterDays, forKey: "removeAudioAfterDays")
            cleanUpAudio()
        }
    }
    /// Keep all meeting audio under this many GB, the oldest going to the Trash first (0: no limit).
    var audioLimitGB: Int {
        didSet {
            if audioLimitGB < 0 { audioLimitGB = 0 }
            UserDefaults.standard.set(audioLimitGB, forKey: "audioLimitGB")
            cleanUpAudio()
        }
    }
    /// The latest cleanup, so runs happen one after another.
    private var cleanup: Task<Void, Never>?
    /// What to call the "Me" speaker in every meeting; empty means "Me".
    var myName: String {
        didSet {
            UserDefaults.standard.set(myName, forKey: "myName")
            // Only the live note follows; finished notes aren't rewritten from Settings.
            if isRecording { current?.writeNote() }
        }
    }
    /// Languages spoken in meetings. Lines that come out in any other language
    /// are re-checked after the meeting.
    var enabledLanguages: Set<SpokenLanguage> {
        didSet {
            if enabledLanguages.isEmpty { enabledLanguages = oldValue }
            UserDefaults.standard.set(enabledLanguages.map(\.rawValue), forKey: "enabledLanguages")
            if !enabledLanguages.contains(mainLanguage) { mainLanguage = SpokenLanguage.preferredMain(among: enabledLanguages) }
        }
    }
    /// The language most meetings are in. The after-meeting review uses it when
    /// it can't tell which enabled language a short or unclear line is in.
    var mainLanguage: SpokenLanguage {
        didSet { UserDefaults.standard.set(mainLanguage.rawValue, forKey: "mainLanguage") }
    }

    static let notesFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Meeting Notes", isDirectory: true)

    static func openNotesFolder() {
        try? createNotesFolder()
        NSWorkspace.shared.open(notesFolder)
    }

    /// Creates `~/Meeting Notes` readable only by you (also on a Mac with
    /// other user accounts). An existing folder is left as it is.
    static func createNotesFolder() throws {
        guard !FileManager.default.fileExists(atPath: notesFolder.path) else { return }
        try FileManager.default.createDirectory(at: notesFolder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    private let engine = ParakeetEngine(version: .ultra)
    let separation = SpeakerSeparation()
    private var vad: VadManager?
    private var mic: MicCapture?
    private var tap: SystemAudioTap?
    private var streams: [StreamTranscriber] = []
    private var feeders: [Task<Void, Never>] = []
    /// Each stream's input: audio, plus erase requests kept in order with it.
    private var feeds: [Speaker: AsyncStream<StreamTranscriber.Feed>.Continuation] = [:]
    private var events: AsyncStream<TranscriptEvent>.Continuation?
    private var eventConsumer: Task<Void, Never>?
    private var silenceCheck: Task<Void, Never>?
    private var micSilenceCheck: Task<Void, Never>?
    private var deviceMonitor: AudioDeviceMonitor?
    /// Where each stream's samples go; kept so capture can be rebuilt mid-meeting.
    private var meSink: (([Float]) -> Void)?
    private var themSink: (([Float]) -> Void)?
    private var reconnecting = false
    /// Recent capture restarts, to stop a restart loop (capture fighting
    /// another app over a device, e.g. after AirPods are taken out mid-call).
    private var recentRestarts: [Date] = []
    /// A reconnect requested while one was running (or holding off), to run next.
    private var reconnectAgain: ReconnectReason?
    private var retryScheduled = false
    /// Mic restarts that failed in a row after a device change.
    private var micRetries = 0
    private static let micStopped = "The microphone stopped after an audio device change"
    /// Counts recordings, so a delayed retry can't touch a later one.
    private var session = 0

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["keepAudio": true, "keepSeparateTracks": true,
                                     "useCalendar": true])
        keepAudio = defaults.bool(forKey: "keepAudio")
        keepSeparateTracks = defaults.bool(forKey: "keepSeparateTracks")
        removeAudioAfterDays = defaults.integer(forKey: "removeAudioAfterDays")
        audioLimitGB = defaults.integer(forKey: "audioLimitGB")
        useCalendar = defaults.bool(forKey: "useCalendar")
        recognizeVoices = defaults.bool(forKey: "recognizeVoices")
        myName = defaults.string(forKey: "myName") ?? ""
        let saved = (defaults.stringArray(forKey: "enabledLanguages") ?? []).compactMap(SpokenLanguage.init(rawValue:))
        let enabled = saved.isEmpty ? SpokenLanguage.defaults : Set(saved)
        enabledLanguages = enabled
        let savedMain = defaults.string(forKey: "mainLanguage").flatMap(SpokenLanguage.init(rawValue:))
        mainLanguage = savedMain.flatMap { enabled.contains($0) ? $0 : nil } ?? SpokenLanguage.preferredMain(among: enabled)
        // Mutes that macOS applies to Wingman's microphone (AirPods press, system controls).
        muteObserver = NotificationCenter.default.addObserver(
            forName: AVAudioApplication.inputMuteStateChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let muted = (note.userInfo?[AVAudioApplication.muteStateKey] as? NSNumber)?.boolValue ?? false
            Log.write("macOS input mute for Wingman: \(muted ? "on" : "off")")
            MainActor.assumeIsolated { self?.systemMuted = muted }
        }
    }

    var isRecording: Bool { phase == .recording }

    /// Recording, or a meeting still finishing in the background: quitting or
    /// installing an update waits for it.
    var busy: Bool { phase != .idle || pendingJoins > 0 || meetings.contains { $0.stage.isFinishing } }

    // MARK: - Start / stop

    func start(for session: CallSession) async {
        await start(meetCode: session.meetingCode)
        if isRecording, let current {
            current.callApp = session.app
            current.callSessionID = session.id
            current.callMeetingCode = session.meetingCode
        }
    }

    func start(meetCode: String? = nil) async {
        guard phase == .idle, !quitting else { return }
        // Claim the phase before the first wait, so a second start can't run alongside.
        phase = .preparing("Checking microphone access…")
        lastError = nil
        warning = nil
        notice = nil
        recentRestarts = []
        reconnectAgain = nil
        retryScheduled = false
        micRetries = 0
        session += 1

        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            lastError = "Microphone access is off. Turn it on in System Settings → Privacy & Security → Microphone."
            phase = .idle
            return
        }
        // Quitting while this waited: don't start a recording only to stop it.
        guard !quitting else {
            phase = .idle
            return
        }

        var created: Meeting?
        do {
            phase = .preparing("Loading speech model (the first time downloads ~0.6 GB)…")
            try await engine.load()
            if vad == nil { vad = try await VadManager() }
            guard let vad else { throw StartError("The voice detector couldn't load.") }
            if !preparingModels { modelStatus = nil }  // a failed download notice no longer applies
            guard !quitting else {
                phase = .idle
                return
            }

            let meeting = try makeMeeting(started: Date(), origin: 0, meetCode: meetCode)
            created = meeting
            capturing = [meeting]
            current = meeting
            meetings.append(meeting)
            slots = [.me: WriterSlot(), .them: WriterSlot()]
            installWriters(for: meeting)
            meSink = makeStream(.me, vad: vad, mutedBy: muteFlag)
            themSink = makeStream(.them, vad: vad)
            do {
                try startMic()
            } catch {
                throw StartError("The microphone couldn't start: \(error.localizedDescription)")
            }
            startTap()

            phase = .recording
            showMeeting?(meeting)
            watchForSilentSystemAudio()
            watchForSilentMicrophone()
            deviceMonitor = AudioDeviceMonitor { [weak self] in
                Task { await self?.reconnect(reason: .deviceChanged) }
            }
        } catch {
            await teardown()
            // Only this attempt's files: a recording that never started leaves nothing behind.
            if let created {
                created.trashFiles()
                forget(created)
            }
            current = nil
            capturing = []
            lastError = error.localizedDescription
            phase = .idle
        }
    }

    // MARK: - Transcribing a file

    /// Transcribes a recording or video file instead of listening live: much
    /// faster than playing it back, and the microphone isn't involved. Every
    /// voice in the file counts as "Them", then goes through the same
    /// language check, speaker separation and recognition as a live meeting,
    /// in its own window.
    func transcribeFile(_ url: URL) async {
        guard phase == .idle, !quitting else { return }
        lastError = nil
        warning = nil
        notice = nil
        let scratch = Self.scratchFile("wingman-import-\(UUID().uuidString).wav")
        var meeting: Meeting?
        do {
            phase = .preparing("Loading speech model…")
            try await engine.load()
            if vad == nil { vad = try await VadManager() }
            guard let vad else { throw StartError("The voice detector couldn't load.") }

            phase = .finishing("Reading \(url.lastPathComponent)…")
            let samples = try await AudioExtractor.samples(from: url)
            guard !samples.isEmpty else { throw AudioExtractorError("\(url.lastPathComponent) has no audio.") }
            try await Task.detached { try AudioExtractor.write(samples, to: scratch) }.value

            // A note like a live meeting's, named after the file.
            let started = Date()
            let name = url.deletingPathExtension().lastPathComponent
            let reserved = try Self.reserveNote(for: started, name: name)
            let created = Meeting(recorder: self, stage: .finishing("Finding speech…"), origin: 0, started: started, name: name,
                                  event: nil, nameFromCalendar: false, base: reserved.base, prefix: reserved.prefix,
                                  tracksKept: false, meAudio: nil, themAudio: scratch, sourceFile: url.lastPathComponent)
            meeting = created
            meetings.append(created)
            showMeeting?(created)

            var config = VadSegmentationConfig.default
            config.minSilenceDuration = 0.5
            let segments = try await vad.segmentSpeech(samples, config: config)
            let rate = Int(Resampler.sampleRate)
            var lines: [TranscriptLine] = []
            for (i, segment) in segments.enumerated() {
                let percent = Int(Double(i) / Double(max(segments.count, 1)) * 100)
                created.setStage(.finishing("Transcribing \(url.lastPathComponent)… \(percent)%"))
                phase = .finishing("Transcribing \(url.lastPathComponent)… \(percent)%")
                let from = max(0, segment.startSample(sampleRate: rate))
                let to = min(samples.count, segment.endSample(sampleRate: rate))
                guard to > from else { continue }
                let (text, confidence) = try await engine.transcribeScored(Array(samples[from..<to]))
                guard !text.isEmpty else { continue }
                lines.append(TranscriptLine(id: UUID(), speaker: .them, start: segment.startTime, end: segment.endTime,
                                            text: text, isFinal: true, confidence: confidence))
            }
            created.setFileLines(lines)
            created.finish(transcribedFrom: (samples.count, scratch))
        } catch {
            let message = "Couldn't transcribe \(url.lastPathComponent): \(error.localizedDescription)"
            lastError = message
            meeting?.lastError = message
            meeting?.setStage(.done)
            try? FileManager.default.removeItem(at: scratch)
        }
        phase = .idle
    }

    // MARK: - Meetings

    /// The recording's call, app, id and start (nil when not recording).
    var callSessionID: UUID? { current?.callSessionID }
    var callApp: CallApp? { current?.callApp }
    var recordingID: UUID? { current?.recordingID }
    var startedAt: Date? { current?.startedAt }

    /// The meeting with a window whose note is `url`, if any.
    func openMeeting(note url: URL) -> Meeting? {
        meetings.first { $0.currentNote?.standardizedFileURL == url.standardizedFileURL }
    }

    /// Meetings with a window: recording, finishing, or done and still open.
    private(set) var meetings: [Meeting] = []
    /// The meeting being recorded.
    private(set) var current: Meeting?
    /// What the menu bar, notifications and reports mean: the meeting being
    /// recorded, else the latest one.
    var focus: Meeting? { current ?? meetings.last }
    /// Meetings that still take transcript lines, in recording order: the one
    /// being recorded and, for a minute after a split, the one before it.
    private var capturing: [Meeting] = []
    /// Opens a meeting's window (set by the app).
    var showMeeting: ((Meeting) -> Void)?
    /// Closes a meeting's window (set by the app).
    var closeMeeting: ((Meeting) -> Void)?
    /// A new call was split off a running recording (for the notification).
    var onSplit: ((Meeting) -> Void)?

    func meeting(id: UUID) -> Meeting? { meetings.first { $0.id == id } }

    /// A meeting's window was closed: once it's done it needn't stay in memory
    /// (Meetings has it from its note).
    func windowClosed(_ meeting: Meeting) {
        guard meeting.stage == .done, meeting !== current else { return }
        forget(meeting)
    }

    private func forget(_ meeting: Meeting) {
        meetings.removeAll { $0 === meeting }
        capturing.removeAll { $0 === meeting }
    }

    /// A meeting finished everything after its recording.
    func meetingFinished(_ meeting: Meeting) {
        cleanUpAudio()
        onMeetingDone?(meeting)
    }

    /// Told when a meeting is done (for the saved notification).
    var onMeetingDone: ((Meeting) -> Void)?
    /// A meeting was deleted (from its window or from Meetings): the message to show.
    var onDeleted: ((String) -> Void)?

    /// The meeting's files were renamed: open track files follow renames, so
    /// only the recovery record needs to know (the meeting saves it).
    func tracksMoved(for meeting: Meeting) {}

    /// A new meeting with its note created (numbered for the day) and, when it
    /// will be recorded, its tracks' locations.
    private func makeMeeting(started: Date, origin: TimeInterval, meetCode: String?) throws -> Meeting {
        let event = useCalendar ? CalendarLookup.currentMeeting(at: started, meetCode: meetCode) : nil
        let name = event?.title ?? ""
        let reserved = try Self.reserveNote(for: started, name: name)
        Log.write("calendar event: \(event == nil ? "none" : "matched")")
        let recordingID = UUID()
        let kept = keepAudio && keepSeparateTracks
        let me = kept ? Self.audioURL(reserved.base, "me") : Self.scratchFile("wingman-\(recordingID.uuidString)-me.wav")
        let them = kept ? Self.audioURL(reserved.base, "them") : Self.scratchFile("wingman-\(recordingID.uuidString)-them.wav")
        let meeting = Meeting(recorder: self, stage: .recording, origin: origin, started: started, name: name, event: event,
                              nameFromCalendar: !name.isEmpty, base: reserved.base, prefix: reserved.prefix,
                              tracksKept: kept, meAudio: me, themAudio: them)
        meeting.speakersUsed = !AudioDeviceMonitor.outputIsHeadphones()
        return meeting
    }

    /// Points each track's slot at a new writer for the meeting's file; returns
    /// the writers it replaced.
    @discardableResult
    private func installWriters(for meeting: Meeting) -> [Speaker: TrackWriter] {
        var old: [Speaker: TrackWriter] = [:]
        for (speaker, url) in [(Speaker.me, meeting.meAudio), (.them, meeting.themAudio)] {
            var writer: TrackWriter?
            if let url {
                do {
                    writer = try TrackWriter(url: url) { [weak meeting] problem in
                        Task { @MainActor in meeting?.streamProblem(speaker, .audioFile(problem)) }
                    }
                } catch {
                    meeting.streamProblem(speaker, .audioFile("couldn't create the file: \(Log.describe(error))"))
                }
            }
            if let previous = slots[speaker]?.swap(writer) { old[speaker] = previous }
        }
        return old
    }

    /// Before quitting: stops a recording, then waits for everything after it
    /// (speakers, combined audio, a file being transcribed) to finish.
    func finishForQuit() async {
        quitting = true
        while phase != .idle {
            if isRecording {
                await stop()
            } else {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        for meeting in meetings { await meeting.waitUntilDone() }
        while pendingJoins > 0 { try? await Task.sleep(for: .milliseconds(100)) }
    }

    // MARK: - Stopping, splitting, joining

    /// Stops recording. The meeting finishes in the background (its window shows
    /// how far it got); `waitUntilDone` on the returned meeting waits for it.
    @discardableResult
    func stop() async -> Meeting? {
        guard phase == .recording, let meeting = current else { return nil }
        phase = .preparing("Finishing transcript…")
        // The meeting ends now, not when the streams have drained.
        let ended = Date()
        for each in capturing where each.stage == .recording && each.endedAt == nil { each.setEnded(ended) }
        await teardown()
        current = nil
        let ending = capturing
        capturing = []
        finishPendingWriters()
        phase = .idle
        for each in ending where each.stage == .recording { each.finish() }
        return meeting
    }

    /// Stops recording and moves everything it saved to the Trash.
    func discard() async {
        guard phase == .recording, let meeting = current else { return }
        phase = .preparing("Discarding…")
        await teardown()
        current = nil
        capturing.removeAll { $0 === meeting }
        let previous = capturing
        capturing = []
        finishPendingWriters()
        for each in previous where each.stage == .recording { each.finish() }
        let notTrashed = meeting.trashFiles()
        forget(meeting)
        closeMeeting?(meeting)
        notice = notTrashed == 0
            ? "Recording discarded — its files are in the Trash."
            : "Recording discarded, but \(notTrashed == 1 ? "one of its files" : "\(notTrashed) of its files") couldn't be moved to the Trash: \(notTrashed == 1 ? "it's" : "they're") still in the meeting's folder."
        phase = .idle
    }

    /// Delete Meeting… after a meeting is done: its files go to the Trash, and
    /// nothing of it stays in Wingman. Returns what to tell the user.
    func delete(_ meeting: Meeting) -> String {
        guard meeting.stage == .done else { return "This meeting is still being finished." }
        let notTrashed = meeting.trashFiles()
        forget(meeting)
        closeMeeting?(meeting)
        Log.write("meeting deleted by user (files to the Trash)")
        let message = Self.deletedMessage(notTrashed: notTrashed)
        onDeleted?(message)
        return message
    }

    /// What Delete Meeting tells the user.
    static func deletedMessage(notTrashed: Int) -> String {
        notTrashed == 0
            ? "Its note, audio and subtitles are in the Trash."
            : "\(notTrashed == 1 ? "One of its files" : "\(notTrashed) of its files") couldn't be moved to the Trash and \(notTrashed == 1 ? "is" : "are") still in the meeting's folder."
    }

    enum SplitReason: String {
        /// Teams' call timer jumped: a different call in the same app (`CallTimer`).
        case newCall = "call timer jumped"
        /// The user asked for a new note (New Note).
        case user = "asked"
    }

    /// After a split: the previous meeting keeps its tracks open for a minute,
    /// so "Join with previous" can undo it; then it finishes.
    private struct PendingSplit {
        let previous: Meeting
        let next: Meeting
        let writers: [Speaker: TrackWriter]
        let timer: Task<Void, Never>
    }
    private var pendingSplit: PendingSplit?
    static let joinWindow: Duration = .seconds(60)

    /// Starts a new meeting at this moment without stopping the recording: no
    /// gap in the audio. The previous meeting finishes in the background.
    func split(reason: SplitReason, force: Bool = false) {
        guard phase == .recording, let previous = current, previous.stage == .recording, let started = previous.startedAt else { return }
        // Within the first seconds the call window is still settling. (Teams'
        // pre-join screen turns into the call in the same window, so joining
        // isn't a new window — measured 2026-10-14.)
        guard force || Date().timeIntervalSince(started) > 3 else {
            Log.write("ignored a possible new call (\(reason.rawValue)) right after the recording started")
            return
        }
        closePendingSplit()
        let origin = Double(slots[.me]?.appended ?? 0) / Resampler.sampleRate
        let next: Meeting
        do {
            next = try makeMeeting(started: Date(), origin: origin, meetCode: previous.callMeetingCode)
        } catch {
            Log.write("couldn't start a new note for a new call: \(Log.describe(error))")
            return
        }
        next.callApp = previous.callApp
        next.callSessionID = previous.callSessionID
        next.callMeetingCode = previous.callMeetingCode
        next.joinable = reason == .newCall
        previous.setEnded(Date())
        let writers = installWriters(for: next)
        current = next
        capturing.append(next)
        meetings.append(next)
        Log.write("new call (\(reason.rawValue)) — started a new note \(Int(origin)) s into the recording")
        let timer = Task { [weak self] in
            try? await Task.sleep(for: Self.joinWindow)
            guard !Task.isCancelled else { return }
            self?.closePendingSplit()
        }
        pendingSplit = PendingSplit(previous: previous, next: next, writers: writers, timer: timer)
        showMeeting?(next)
        onSplit?(next)
    }

    /// The recording ends during the minute after a split: the previous
    /// meeting's tracks are closed now.
    private func finishPendingWriters() {
        guard let pending = pendingSplit else { return }
        pendingSplit = nil
        pending.timer.cancel()
        pending.next.joinable = false
        for writer in pending.writers.values { writer.finish() }
    }

    #if !NO_DIAGNOSTICS
    /// Development (recordtest --split): splits now, even right after the start,
    /// and finishes the previous meeting at once.
    func splitNow() {
        split(reason: .user, force: true)
        closePendingSplit()
    }

    /// Development: a split as a new call window makes it (Join with Previous
    /// stays possible for a minute), for `recordtest --join`.
    func splitAsNewCall() {
        split(reason: .newCall, force: true)
    }
    #endif

    /// The minute after a split is over: the previous meeting stops taking lines
    /// and finishes.
    private func closePendingSplit() {
        guard let pending = pendingSplit else { return }
        pendingSplit = nil
        pending.timer.cancel()
        pending.next.joinable = false
        capturing.removeAll { $0 === pending.previous }
        Task {
            for writer in pending.writers.values { _ = await Task.detached { writer.finish() }.value }
            pending.previous.finish()
        }
    }

    /// "Join with previous": the split was wrong. The new meeting's audio and
    /// lines go back onto the previous one, which records on; the new note goes.
    func join(_ next: Meeting) {
        guard let pending = pendingSplit, pending.next === next, next === current, next.stage == .recording else { return }
        pendingSplit = nil
        pending.timer.cancel()
        let previous = pending.previous
        // Audio: what the new tracks hold goes onto the old ones, in order, then
        // live audio follows. The new meeting's files go only once that's
        // confirmed; a track that couldn't be appended is kept next to the note.
        var appends: [Task<(Speaker, Bool, URL?), Never>] = []
        for (speaker, oldWriter) in pending.writers {
            guard let slot = slots[speaker] else { continue }
            appends.append(Task {
                await withCheckedContinuation { continuation in
                    slot.rejoin(oldWriter, read: joinRead) { ok, url in continuation.resume(returning: (speaker, ok, url)) }
                }
            })
        }
        let shift = next.origin - previous.origin
        let moved = next.lines.map { line -> TranscriptLine in
            var line = line
            line.start += shift
            line.end += shift
            return line
        }
        previous.adopt(moved)
        previous.setEnded(nil)
        next.replaceLines([])
        current = previous
        capturing.removeAll { $0 === next }
        forget(next)
        closeMeeting?(next)
        showMeeting?(previous)
        Log.write("new note joined back with the previous one (user)")
        pendingJoins += 1
        Task {
            var kept: [String] = []
            for append in appends {
                let (speaker, ok, url) = await append.value
                guard !ok, let url else { continue }
                if let moved = Self.keepJoinLeftover(url, speaker: speaker, beside: previous.currentNote) { kept.append(moved) }
            }
            next.trashFiles()
            if !kept.isEmpty {
                Log.write("joined, but some audio couldn't be moved onto the previous meeting's tracks; kept beside the note")
                previous.setWarning("Joined, but some audio couldn't be added to this meeting's recording. It’s kept next to the note (\(kept.joined(separator: ", "))).")
            }
            pendingJoins -= 1
        }
    }

    /// Joins whose audio is still being moved (quitting and updates wait).
    private(set) var pendingJoins = 0
    /// Reads a track for a join (tests replace it to force failures).
    var joinRead: @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }

    /// A track a join couldn't append: moved next to `note` as
    /// "<note>-joined-me.wav" (never into the Trash). Returns its file name.
    nonisolated static func keepJoinLeftover(_ url: URL, speaker: Speaker, beside note: URL?) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let folder = note?.deletingLastPathComponent() ?? url.deletingLastPathComponent()
        let base = note?.deletingPathExtension().lastPathComponent ?? url.deletingPathExtension().lastPathComponent
        var target = folder.appendingPathComponent("\(base)-joined-\(speaker == .me ? "me" : "them").wav")
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(base)-joined-\(speaker == .me ? "me" : "them") \(n).wav")
            n += 1
        }
        do {
            try fm.moveItem(at: url, to: target)
            return target.lastPathComponent
        } catch {
            return url.lastPathComponent
        }
    }

    /// Where transcript lines go: the latest meeting (still taking lines) that
    /// started at or before the line; times become the meeting's own.
    private func route(_ event: TranscriptEvent) {
        guard let target = capturing.last(where: { $0.origin <= event.start + 0.01 }) ?? capturing.first else { return }
        // A line that started before a split stays with the meeting it started in.
        let owner = capturing.first { $0.lines.contains { $0.id == event.utteranceID } } ?? target
        let shifted = TranscriptEvent(utteranceID: event.utteranceID, speaker: event.speaker,
                                      start: max(0, event.start - owner.origin), end: max(0, event.end - owner.origin),
                                      text: event.text, isFinal: event.isFinal, confidence: event.confidence, failed: event.failed)
        owner.handle(shifted)
    }

    /// Each track's current writer, swapped at a split (see `WriterSlot`).
    private var slots: [Speaker: WriterSlot] = [:]

    /// Downloads what the first recording and the first language review need,
    /// right after setup, so a first real call doesn't wait for ~2 GB of
    /// downloads (and lose its opening minutes). Skips what's already here; a
    /// recording or review that starts meanwhile shares the same download.
    func prepareModels() async {
        guard !preparingModels else { return }
        preparingModels = true
        defer { preparingModels = false }
        do {
            if !engine.isDownloaded {
                modelStatus = "Downloading the speech model (one time, ~0.6 GB)…"
                Log.write("downloading the speech model")
                try await engine.download()
            }
            // The small ones too, so Wingman really works offline from here on.
            if vad == nil { vad = try await VadManager() }
            if !WhisperModel.isDownloaded || !WhisperModel.hasTokenizer {
                modelStatus = "Downloading the language-review model (one time, ~1.5 GB)…"
                Log.write("downloading the review model")
                try await WhisperDownload.shared.ensure()
                // Its word list comes with the first load.
                if !WhisperModel.hasTokenizer { _ = try await WhisperModel.load() }
            }
            try await separation.load()
            modelStatus = nil
        } catch {
            Log.write("model download failed (will try again when recording): \(Log.describe(error))")
            modelStatus = "Couldn't download Wingman's speech models. Check your internet connection — Wingman tries again when you record."
        }
    }


    private func startMic() throws {
        guard let meSink else { return }
        let mic = MicCapture()
        // Never with Apple's voice processing (echo cancellation): switching it on
        // reconfigures the built-in mic, and the call app (Teams) then sends
        // silence until it's switched off — people stop hearing you (seen
        // 2026-10-04/05 in the system log). With speakers, the transcript's
        // repeated-line filter handles the call echoing into the mic.
        try mic.start(echoCancellation: false, onSamples: meSink)
        mic.onInterrupted = { [weak self] in
            Task { await self?.reconnect(reason: .micInterrupted) }
        }
        self.mic = mic
    }

    private func startTap() {
        guard let themSink else { return }
        let tap = SystemAudioTap()
        do {
            try tap.start(onSamples: themSink)
            self.tap = tap
        } catch {
            warning = "Call audio can't be captured (\(error.localizedDescription)). Only your microphone is being transcribed."
        }
    }

    /// Set by `resumeAfterHang` for the reconnect's notice.
    private var resumedAfterHang: String?

    private enum ReconnectReason {
        case deviceChanged, micInterrupted

        /// A device change rebuilds everything, so it wins over a mic hiccup.
        func merged(with other: ReconnectReason?) -> ReconnectReason {
            self == .deviceChanged || other == .deviceChanged ? .deviceChanged : .micInterrupted
        }
    }

    /// The main thread was stuck long enough for the watchdog to release the
    /// microphone and call audio (`AudioEmergencyStop`): capture comes back on
    /// the current devices, and the note's window says what's missing.
    func resumeAfterHang(seconds: Double) {
        guard phase == .recording else { return }
        let gap = seconds < 90 ? "\(Int(seconds.rounded())) seconds" : "\(Int((seconds / 60).rounded())) minutes"
        resumedAfterHang = "Wingman stopped responding for about \(gap) and let go of the audio so your call wasn't disturbed. "
            + "It's listening again; that stretch is missing from the audio and the transcript."
        Log.write(String(format: "rebuilding capture after the main thread was blocked for %.0f s", seconds))
        Task { await reconnect(reason: .deviceChanged) }
    }

    /// Rebuilds capture on the current devices after AirPods connect, headphones
    /// are unplugged, or the output is switched mid-meeting. The transcript and
    /// files carry on; the moment of switching is filled with silence.
    private func reconnect(reason: ReconnectReason) async {
        guard phase == .recording else { return }
        if reconnecting || retryScheduled {
            reconnectAgain = reason.merged(with: reconnectAgain)
            return
        }
        reconnecting = true
        defer {
            reconnecting = false
            if let again = reconnectAgain, !retryScheduled {
                reconnectAgain = nil
                Task { await reconnect(reason: again) }
            }
        }
        // Let macOS finish switching both directions before reattaching.
        try? await Task.sleep(for: .milliseconds(300))
        guard phase == .recording else { return }

        // Circuit breaker: more than 6 restarts in 20 s means capture is fighting
        // another app; wait it out, then reconnect once, so capture isn't left
        // dead for the rest of the meeting.
        let now = Date()
        recentRestarts = recentRestarts.filter { now.timeIntervalSince($0) < 20 } + [now]
        if recentRestarts.count > 6 {
            Log.write("capture keeps restarting; holding off for 20 s")
            reconnectAgain = reason.merged(with: reconnectAgain)
            retryScheduled = true
            let current = session
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard let self, self.session == current else { return }
                self.retryScheduled = false
                guard let again = self.reconnectAgain else { return }
                self.reconnectAgain = nil
                self.recentRestarts = []
                Log.write("retrying capture after holding off")
                await self.reconnect(reason: again)
            }
            return
        }

        mic?.stop()
        mic = nil
        do {
            try startMic()
            micRetries = 0
            if warning?.hasPrefix(Self.micStopped) == true { warning = nil }
        } catch {
            // Often the device is still switching (e.g. AirPods changing mode):
            // try again shortly rather than leave the mic off for the meeting.
            Log.write("mic restart failed: \(Log.describe(error))")
            if micRetries < 3 {
                micRetries += 1
                warning = "\(Self.micStopped) — trying again…"
                let current = session
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard let self, self.session == current else { return }
                    await self.reconnect(reason: .micInterrupted)
                }
            } else {
                warning = "\(Self.micStopped) (\(error.localizedDescription)). Stop and start a new recording."
            }
        }
        // A mic hiccup only needs the mic restarted; rebuilding call-audio
        // capture creates and removes a device, which can feed the loop.
        if reason == .deviceChanged {
            tap?.stop()
            tap = nil
            startTap()
        }

        let elapsed = current?.startedAt.map { Self.timestamp(Date().timeIntervalSince($0)) } ?? ""
        if !AudioDeviceMonitor.outputIsHeadphones() { current?.speakersUsed = true }
        let output = AudioDeviceMonitor.defaultOutputName() ?? "new output"
        let input = AudioDeviceMonitor.defaultInputName() ?? "new microphone"
        if let resumed = resumedAfterHang {
            current?.notice = resumed
            resumedAfterHang = nil
        } else {
            current?.notice = "Audio devices changed at \(elapsed) — now listening on \(input), call audio from \(output)."
        }
        Log.write("reconnected capture (\(reason)) — input \(input), output \(output)")
    }

    private struct StartError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    // MARK: - Transcribing a file

    /// When this launch followed a run that ended mid-recording (a crash, or a
    /// force quit of a hung Wingman). Calls found soon after are asked about
    /// rather than recorded automatically (`CallWatcher.asksAfterRestart`).
    private(set) var restartedDuringRecording: Date?

    /// At launch, before anything can start recording: finishes the audio of
    /// recordings Wingman didn't get to finish, then clears old scratch audio.
    func recoverInterruptedRecordings() {
        // Only what an earlier session left is ever cleaned up: anything this
        // session writes is newer than this.
        let launched = Date()
        let records = RecordingRecovery.leftovers(in: Self.scratchFolder)
        // A recovery record means the last run ended while recording.
        if !records.isEmpty { restartedDuringRecording = launched }
        // Tracks a record covers are its own, not orphans.
        let covered = Set(records.flatMap(\.record.tracks).map(\.standardizedFileURL))
        let orphans = RecordingRecovery.orphanedTracks(in: Self.notesFolder).compactMap { orphan -> RecordingRecovery.Record? in
            var orphan = orphan
            orphan.tracks.removeAll { covered.contains($0.standardizedFileURL) }
            return orphan.tracks.isEmpty ? nil : orphan
        }
        guard !records.isEmpty || !orphans.isEmpty else {
            removeLeftoverScratch(olderThan: launched)
            return
        }
        Log.write("finishing the audio of \(records.count + orphans.count) interrupted recording(s)")
        let all = records.map(\.record) + orphans
        let keys = Set(all.map { AudioCleanup.key(for: $0.note) })
        audioInUse.formUnion(keys)
        Task {
            var recovered = 0
            for (i, record) in all.enumerated() {
                let outcome = await Task.detached(priority: .utility) { RecordingRecovery.finish(record) }.value
                if i < records.count { try? FileManager.default.removeItem(at: records[i].url) }
                Log.write(String(format: "finished an interrupted recording: %.0f s of audio, combined audio %@",
                                 outcome.seconds, outcome.combinedSaved ? "saved" : "not saved"))
                if outcome.seconds > 0 { recovered += 1 }
            }
            audioInUse.subtract(keys)
            removeLeftoverScratch(olderThan: launched)
            if recovered > 0, notice == nil {
                notice = recovered == 1
                    ? "Wingman stopped during a meeting before it could finish. Its audio was recovered and saved next to its note."
                    : "Wingman stopped during \(recovered) meetings before it could finish them. Their audio was recovered and saved next to their notes."
            }
        }
    }

    /// Applies the audio rules from Settings → Audio in the background. Never
    /// while a meeting is recording or finishing, and never to the meeting in
    /// the window.
    func cleanUpAudio() {
        guard phase == .idle, removeAudioAfterDays > 0 || audioLimitGB > 0 else { return }
        let keep = Set(meetings.compactMap { $0.currentNote.map(AudioCleanup.key(for:)) }).union(audioInUse)
        // The newest start per note: a number reused after a note was removed
        // in Finder mustn't make the new meeting look older.
        let known = Dictionary(index.meetings.compactMap { m in m.started.map { (m.key, $0) } }, uniquingKeysWith: max)
        let (days, limit, folder, previous) = (removeAudioAfterDays, audioLimitGB, Self.notesFolder, cleanup)
        cleanup = Task.detached(priority: .utility) {
            await previous?.value
            AudioCleanup.run(in: folder, maxAgeDays: days, limitGB: limit, keep: keep, known: known)
        }
    }

    func cleanupFinished() async { await cleanup?.value }

    /// Meetings (by key) whose audio something else is reading, such as a search
    /// for voices in an older meeting: the clean-up leaves them alone meanwhile.
    var audioInUse: Set<String> = []

    // MARK: - Export

    private func teardown() async {
        callMuted = nil
        callMuteIgnored = false
        callMuteProblem = nil
        callMuteNote = nil
        applyMute()
        silenceCheck?.cancel()
        micSilenceCheck?.cancel()
        micSilent = false
        callAudioMissing = false
        deviceMonitor?.stop()
        deviceMonitor = nil
        meSink = nil
        themSink = nil
        mic?.stop()
        tap?.stop()
        mic = nil
        tap = nil
        feeds.values.forEach { $0.finish() }
        for feeder in feeders { await feeder.value }
        for stream in streams { await stream.finish() }
        for slot in slots.values { slot.swap(nil)?.finish() }
        // Every line the streams produced is in its meeting before it's finished.
        events?.finish()
        await eventConsumer?.value
        events = nil
        eventConsumer = nil
        slots = [:]
        feeds = [:]
        feeders = []
        streams = []
    }

    /// Transcript events reach the window in order through one queue, without the
    /// streams ever waiting for the main thread: a busy window delays the
    /// transcript on screen, never the transcription or the audio.
    private func startEvents() {
        let (stream, continuation) = AsyncStream<TranscriptEvent>.makeStream(bufferingPolicy: .unbounded)
        events = continuation
        eventConsumer = Task { @MainActor [weak self] in
            for await event in stream { self?.route(event) }
        }
    }

    /// Creates the transcriber for one stream and returns the callback the
    /// audio thread uses to hand it samples (in order, without blocking).
    private func makeStream(_ speaker: Speaker, vad: VadManager, mutedBy flag: LockedFlag? = nil) -> ([Float]) -> Void {
        if events == nil { startEvents() }
        let events = events
        let stream = StreamTranscriber(speaker: speaker, engine: engine, vad: vad, onProblem: { [weak self] problem in
            Task { @MainActor in self?.current?.streamProblem(speaker, problem) }
        }) { event in
            events?.yield(event)
        }
        // The track is written from the capture thread's side, ahead of transcription,
        // into whichever meeting's file the slot points at.
        let slot = slots[speaker]
        let (input, continuation) = AsyncStream<StreamTranscriber.Feed>.makeStream(bufferingPolicy: .unbounded)
        feeders.append(Task.detached(priority: .userInitiated) {
            for await item in input { await stream.take(item) }
        })
        streams.append(stream)
        feeds[speaker] = continuation
        let aligner = ClockAligner { samples in
            slot?.append(samples)
            continuation.yield(.samples(samples))
        }
        // Muted audio becomes silence rather than a gap, so the tracks stay aligned.
        let sound = speaker == .me ? micSound : nil
        let level = speaker == .me ? micLevel : nil
        return { samples in
            if let sound, samples.contains(where: { $0 != 0 }) { sound.touch() }
            level?.add(samples)
            aligner.push(flag?.value == true ? [Float](repeating: 0, count: samples.count) : samples)
        }
    }

    /// Undoes a mute macOS applied to Wingman's microphone.
    func clearSystemMute() {
        try? AVAudioApplication.shared.setInputMuted(false)
        systemMuted = false
        Log.write("macOS input mute cleared from Wingman")
    }

    /// Warns when the microphone sends nothing but silence for 30 seconds while
    /// Wingman itself isn't muted — muted elsewhere, or not delivering audio.
    private func watchForSilentMicrophone() {
        micSound.touch()
        micSilent = false
        systemMuted = AVAudioApplication.shared.isInputMuted
        Log.write("recording started — Wingman mute \(micMuted ? "on" : "off"), macOS input mute \(systemMuted ? "on" : "off"), input \(AudioDeviceMonitor.defaultInputName() ?? "?"), output \(AudioDeviceMonitor.defaultOutputName() ?? "?")")
        micSilenceCheck?.cancel()
        _ = micLevel.take()
        micSilenceCheck = Task { [weak self] in
            var checks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.phase == .recording else { return }
                checks += 1
                // After 10 s, then every minute.
                if checks == 2 || checks % 12 == 0, let (rms, peak) = self.micLevel.take() {
                    Log.write(String(format: "mic level: rms %.0f dBFS, peak %.0f dBFS", rms, peak))
                }
                let silentFor = Date().timeIntervalSince(self.micSound.value)
                let silent = !self.effectiveMuted && silentFor > 30
                if silent != self.micSilent {
                    self.micSilent = silent
                    Log.write(silent ? "microphone silent for \(Int(silentFor)) s while not muted" : "microphone sound again")
                }
            }
        }
    }

    private func watchForSilentSystemAudio() {
        guard let them = streams.first(where: { $0.speaker == .them }), tap != nil else { return }
        silenceCheck = Task { [weak self] in
            // A tap started while the permission prompt is open stays silent after
            // "Allow" until it's recreated, so restart it a few times early on.
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self, self.phase == .recording else { return }
                if let tap = self.tap, tap.callbacks > 0 { break }
                // With some outputs (AirPods) no audio arrives while nothing plays; that's not a dead tap.
                if CallDetector.processesPlayingAudio().isEmpty { continue }
                self.tap?.stop()
                self.tap = nil
                self.startTap()
            }
            // Then watch until the other side is first heard. A quiet start is
            // normal (people join, nobody talks yet), so it takes a minute of
            // nothing while something plays before it counts as missing.
            let started = Date()
            while !Task.isCancelled {
                let heard = await them.peak > 0
                guard let self, self.phase == .recording else { return }
                let missing = Self.callAudioMissing(heard: heard, waited: Date().timeIntervalSince(started),
                                                    somethingPlaying: !CallDetector.processesPlayingAudio().isEmpty)
                if missing != self.callAudioMissing {
                    self.callAudioMissing = missing
                    // The remembered "allowed" may be stale (revoked in System Settings).
                    if missing { UserDefaults.standard.removeObject(forKey: "systemAudioConfirmed") }
                    Log.write(missing ? "no call audio for a minute while something plays" : "call audio arriving")
                }
                if heard { return }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// Whether to say call audio is missing: nothing heard for a minute while
    /// something is playing that should have been heard.
    nonisolated static func callAudioMissing(heard: Bool, waited: TimeInterval, somethingPlaying: Bool) -> Bool {
        !heard && waited >= 60 && somethingPlaying
    }

    // MARK: - Transcript

    /// Whether two lines said at about the same time are the same words. A
    /// short line counts only if it matches exactly: "Sí" is a real reply,
    /// not an echo, just because the other side also said "sí" in a sentence.
    enum EchoVerdict: Equatable {
        case none
        /// Similar, but maybe a real reply: kept, marked.
        case possible
        /// A clear repeat right after theirs: the call heard through the speakers.
        case echo
    }

    /// Whether my line is the call coming back through the speakers. Only a clear
    /// repeat goes: at least three words, nearly the same words in the same
    /// order, the same negations, starting with or just after theirs (`delay`
    /// seconds). A line that merely shares most of its words (the old test) is
    /// kept and marked: "I was right, you were wrong" isn't an echo of the reverse.
    ///
    /// An echo never adds a negation: my line saying theirs with a "not" more
    /// ("I cannot approve this" after "I can approve this") is a reply, and isn't
    /// even marked. A heuristic: speech recognition can also add a "not" to a real
    /// echo, which then stays unmarked. One "not" fewer (recognition can drop one)
    /// stays marked.
    static func echoVerdict(mine: String, theirs: String, delay: TimeInterval) -> EchoVerdict {
        let a = expanded(words(mine)), b = expanded(words(theirs))
        guard !a.isEmpty, !b.isEmpty else { return .none }
        let lengthRatio = Double(min(a.count, b.count)) / Double(max(a.count, b.count))
        if (-0.5...1.5).contains(delay), a.count >= 3, lengthRatio >= 0.75,
           orderedSimilarity(a, b) >= 0.85, negations(a) == negations(b) {
            return .echo
        }
        let plainA = withoutNegations(a), plainB = withoutNegations(b)
        if negations(a).count > negations(b).count, !plainA.isEmpty, orderedSimilarity(plainA, plainB) >= 0.85 {
            return .none
        }
        let sa = Set(a), sb = Set(b)
        let shared = min(sa.count, sb.count) < 3
            ? sa == sb
            : similarity(mine, theirs) >= 0.6
        return shared ? .possible : .none
    }

    /// Shared words over the shorter line's, regardless of order.
    static func similarity(_ a: String, _ b: String) -> Double {
        let wa = Set(words(a)), wb = Set(words(b))
        guard !wa.isEmpty, !wb.isEmpty else { return 0 }
        return Double(wa.intersection(wb).count) / Double(min(wa.count, wb.count))
    }

    /// 1 minus the word-level edit distance over the longer line's length.
    static func orderedSimilarity(_ a: [String], _ b: [String]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1]
                    ? previous[j - 1]
                    : 1 + min(previous[j - 1], previous[j], current[j - 1])
            }
            previous = current
        }
        return 1 - Double(previous[b.count]) / Double(max(a.count, b.count))
    }

    /// Words that flip a sentence's meaning, in the languages Wingman hears most.
    private static let negationWords: Set<String> = [
        "not", "no", "never", "nothing", "none", "nor", "cannot", "can't", "don't", "doesn't", "didn't", "won't",
        "isn't", "aren't", "wasn't", "weren't", "shouldn't", "wouldn't", "couldn't", "haven't", "hasn't", "hadn't",
        "nunca", "jamás", "tampoco", "ni", "nada", "ningún", "ninguna", "ninguno",
        "não", "nem", "nenhum", "nenhuma",
        "ne", "pas", "jamais", "rien", "nicht", "kein", "keine", "nie", "niemals", "non", "mai",
    ]

    private static func negations(_ words: [String]) -> [String] {
        words.filter(negationWords.contains)
    }

    /// The words without negations, nor the "do" that only carries one
    /// ("we don't ship" against "we ship").
    private static func withoutNegations(_ words: [String]) -> [String] {
        var kept: [String] = []
        for (i, word) in words.enumerated() where !negationWords.contains(word) {
            let carriesNot = ["do", "does", "did"].contains(word) && i + 1 < words.count && negationWords.contains(words[i + 1])
            if !carriesNot { kept.append(word) }
        }
        return kept
    }

    /// "can't" and "cannot" become "can not", "don't" becomes "do not", so every
    /// way of saying it counts as one "not" next to the same verb.
    static func expanded(_ words: [String]) -> [String] {
        words.flatMap { word -> [String] in
            switch word {
            case "cannot", "can't": return ["can", "not"]
            case "won't": return ["will", "not"]
            case "shan't": return ["shall", "not"]
            default:
                guard word.hasSuffix("n't"), word.count > 3 else { return [word] }
                return [String(word.dropLast(3)), "not"]
            }
        }
    }

    /// Lowercased words; apostrophes stay inside them ("don't" is one word).
    private static func words(_ s: String) -> [String] {
        s.lowercased().replacingOccurrences(of: "’", with: "'")
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Files

    /// Claims the next number in the day's folder for a new note named `name`
    /// (see `NoteNaming.reserve`) and returns the files' base and prefix.
    static func reserveNote(for date: Date, name: String) throws -> (base: URL, prefix: String) {
        let fm = FileManager.default
        try createNotesFolder()
        let folder = notesFolder.appendingPathComponent(dayFolderName(for: date), isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return try NoteNaming.reserve(in: folder, day: dayFolderName(for: date), name: fileSafe(name))
    }

    /// "2026-10-02". Both this and the time are in local time (DateFormatter's
    /// default time zone); the ISO 8601 format style would use UTC and file
    /// evening meetings under tomorrow.
    nonisolated static func dayFolderName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// "17-07".
    nonisolated static func timeOfDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH-mm"
        return formatter.string(from: date)
    }

    /// Wingman's own folder for audio it only needs while working — the tracks of
    /// a meeting whose audio isn't kept, file imports, compression — so a crash
    /// can't leave meeting audio lying around: whatever is here at launch goes.
    static let scratchFolder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Wingman/Recording", isDirectory: true)

    static func scratchFile(_ name: String) -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(at: scratchFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Also for a folder that already existed: only you can open meeting audio.
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scratchFolder.path)
        return scratchFolder.appendingPathComponent(name)
    }

    /// At launch nothing is being recorded, so scratch audio still here (and,
    /// from versions before 0.8.1, in the temporary folder) was left by a crash.
    /// Scratch audio and recovery records an earlier session left. Recovery
    /// runs in the background, so a meeting can be recorded and finishing
    /// meanwhile: only files last written before `launched` go, and never one
    /// a meeting in this session uses.
    func removeLeftoverScratch(olderThan launched: Date) {
        let inUse = Set(meetings.flatMap { [$0.meAudio, $0.themAudio] }.compactMap { $0?.standardizedFileURL })
            .union((pendingSplit?.writers.values.map(\.url) ?? []).map(\.standardizedFileURL))
        let leftovers = Self.leftoverScratch(in: Self.scratchFolder, temporary: FileManager.default.temporaryDirectory,
                                             olderThan: launched, inUse: inUse)
        let fm = FileManager.default
        var removed = 0
        for url in leftovers where (try? fm.removeItem(at: url)) != nil { removed += 1 }
        if removed > 0 { Log.write("removed \(removed) leftover scratch audio file\(removed == 1 ? "" : "s") from an earlier session") }
        if removed < leftovers.count { Log.write("couldn't remove \(leftovers.count - removed) leftover scratch audio file(s)") }
    }

    /// Files in the scratch folder, and Wingman's audio in the temporary folder,
    /// last modified before `date` and not in `inUse`.
    nonisolated static func leftoverScratch(in scratch: URL, temporary: URL, olderThan date: Date, inUse: Set<URL>) -> [URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        var candidates = (try? fm.contentsOfDirectory(at: scratch, includingPropertiesForKeys: keys)) ?? []
        candidates += ((try? fm.contentsOfDirectory(at: temporary, includingPropertiesForKeys: keys)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("wingman-") && ["wav", "m4a"].contains($0.pathExtension) }
        return candidates.filter { url in
            guard !inUse.contains(url.standardizedFileURL),
                  let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            else { return false }
            return modified < date
        }
    }

    /// A meeting name usable in a file name: no separators, and short enough —
    /// counted in bytes, which is what the 255-byte file-name limit measures — that
    /// the time prefix and the longest suffix ("-them.wav") always fit.
    static func fileSafe(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\\n\r\t")).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        var kept = ""
        var bytes = 0
        for character in cleaned.prefix(80) {
            let size = String(character).utf8.count
            guard bytes + size <= maxNameBytes else { break }
            kept.append(character)
            bytes += size
        }
        return kept.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    }

    /// 255 bytes minus the prefix ("2026-10-07_100_") and suffix, with room to spare.
    static let maxNameBytes = 200

    static let companionSuffixes = [".md", ".m4a", "-me.m4a", "-them.m4a", "-me.wav", "-them.wav", ".vtt", ".srt"]

    /// Whether two paths name the same file (e.g. only upper/lower case differs
    /// on a case-insensitive disk). False if either doesn't exist.
    static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        let key = URLResourceKey.fileResourceIdentifierKey
        // Fresh URL objects, so cached resource values can't answer for an old state.
        guard let idA = try? URL(fileURLWithPath: a.path).resourceValues(forKeys: [key]).fileResourceIdentifier,
              let idB = try? URL(fileURLWithPath: b.path).resourceValues(forKeys: [key]).fileResourceIdentifier
        else { return false }
        return idA.isEqual(idB)
    }

    // MARK: - Speaker names

    // MARK: - Calendar event

    // MARK: Deleting voices

    /// Who deleting these meetings' voices would change in People, for the confirmation.
    func effectOfDeletingVoices(of meetings: Set<UUID>) -> (recalculated: [String], forgotten: [String]) {
        voices.effectOfRemoving(meetings: meetings)
    }

    /// People who learned from these meetings but whose voice can't have that
    /// taken out exactly: an older Wingman (0.8) rewrote their voice without
    /// the record of which meeting each part came from. Forgetting them is
    /// the only complete removal.
    func untraceableLearning(in meetings: Set<UUID>) -> [String] {
        let speakers = index.meetings.filter { meetings.contains($0.id) }.flatMap(\.speakers)
        let lost = voices.untraceable(Set(speakers.compactMap(\.learned)))
        return Array(Set(speakers.filter { $0.learned.map(lost.contains) ?? false }.compactMap(\.name))).sorted()
    }

    /// Delete Voices: the meetings' kept voices, and everything learned from them
    /// (people are recalculated without them; someone learned only from them is
    /// forgotten). The meetings are never searched for voices again; names stay.
    @discardableResult
    func deleteVoices(of meetings: Set<UUID>) -> Bool {
        guard voices.removeVoices(fromMeetings: meetings) else { return false }
        var ok = true
        for id in meetings { ok = index.deleteVoices(of: id) && ok }
        for meeting in self.meetings where meetings.contains(meeting.id) { meeting.forgetLearned() }
        return ok
    }

    /// Delete All in Settings → People: every meeting's voices, as above, and
    /// none kept or looked for in meetings from before now.
    @discardableResult
    func deleteAllMeetingVoices() -> Bool {
        // Also what was learned from meetings no longer listed (their entry
        // went with a note removed outside Wingman).
        let learnedFrom = voices.people.flatMap { $0.contributions?.compactMap(\.meeting) ?? [] }
        let all = Set(index.meetings.map(\.id)).union(learnedFrom)
        guard voices.removeVoices(fromMeetings: all) else { return false }
        meetings.forEach { $0.forgetLearned() }
        return index.deleteAllVoices(because: .deleted)
    }

    /// Forget Everyone: all people, and all meetings' voices.
    func forgetEveryone() {
        voices.forgetEveryone()
        guard voices.people.isEmpty else { return }
        meetings.forEach { $0.forgetLearned() }
        index.deleteAllVoices(because: .deleted)
    }

    /// At launch and then hourly: meeting voices past their 180 days are deleted,
    /// old note backups go, and renames a quit interrupted are finished.
    func tidyMeetingData() {
        index.purgeExpired()
        Task.detached(priority: .utility) { NoteFile.prune() }
        let jobs = index.jobs
        if !jobs.isEmpty {
            Task {
                for job in jobs {
                    guard let key = index.meeting(id: job.meeting)?.key else {
                        index.finish(job)
                        continue
                    }
                    let url = Self.notesFolder.appendingPathComponent(key + ".md")
                    guard let meeting = try? await PastMeeting.open(url, index: index, voices: voices,
                                                                    recognize: { [weak self] in self?.recognizeVoices ?? false }) else { continue }
                    await meeting.resume(job)
                    Log.write("finished a speaker rename left by an earlier session")
                }
            }
        }
        guard tidyTimer == nil else { return }
        tidyTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
                self?.index.purgeExpired()
            }
        }
    }

    private var tidyTimer: Task<Void, Never>?

    static func audioURL(_ base: URL, _ suffix: String) -> URL {
        base.deletingLastPathComponent()
            .appendingPathComponent("\(base.lastPathComponent)-\(suffix).wav")
    }

    /// Read fresh each time (URL resource values are cached per URL instance).
    static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    nonisolated static func timestamp(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
}

/// A Bool readable from the audio thread.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ new: Bool) {
        lock.lock()
        stored = new
        lock.unlock()
    }
}

/// Loudness of the samples seen since the last `take`, writable from the audio thread.
final class LockedLevel: @unchecked Sendable {
    private let lock = NSLock()
    private var sumSquares: Double = 0
    private var count = 0
    private var peak: Float = 0

    func add(_ samples: [Float]) {
        var sum: Double = 0
        var top: Float = 0
        for s in samples {
            sum += Double(s * s)
            top = max(top, abs(s))
        }
        lock.lock()
        sumSquares += sum
        count += samples.count
        peak = max(peak, top)
        lock.unlock()
    }

    /// RMS and peak in dBFS since the last call, then starts over; nil if nothing arrived.
    func take() -> (rms: Double, peak: Double)? {
        lock.lock()
        defer {
            sumSquares = 0
            count = 0
            peak = 0
            lock.unlock()
        }
        guard count > 0 else { return nil }
        let rms = (sumSquares / Double(count)).squareRoot()
        return (20 * log10(max(rms, 1e-6)), 20 * log10(max(Double(peak), 1e-6)))
    }
}

/// A timestamp writable from the audio thread.
final class LockedTime: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Date()

    var value: Date {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func touch() {
        lock.lock()
        stored = Date()
        lock.unlock()
    }
}
