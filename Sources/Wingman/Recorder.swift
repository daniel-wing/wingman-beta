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
    private(set) var lines: [TranscriptLine] = []
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
            if !wasMuted, !callMuteIgnored { feeds[.me]?.yield(.redact(seconds: 0.5)) }
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
    private(set) var notice: String?
    private(set) var lastError: String?
    /// The note on disk has everything up to the last write (false before the
    /// first write and after a failed one, so nothing claims "saved" untrue).
    private(set) var noteSaved = false
    /// Why the note couldn't be saved: shown in the window with Save Note As….
    private(set) var noteSaveError: String?
    /// Identifies this recording, so an action from an older notification
    /// (Stop, Discard) can't apply to a newer one.
    private(set) var recordingID = UUID()
    /// Stream problems already shown in this recording (one warning each).
    private var reportedProblems: Set<String> = []
    /// The call played through speakers at some point in this recording, so the
    /// microphone may have heard it (no echo filtering when it's headphones only).
    private var speakersUsed = true
    private(set) var currentNote: URL?
    private(set) var startedAt: Date?
    private var endedAt: Date?

    /// What the user calls this meeting; it becomes part of every file name.
    var meetingName = ""
    /// The name the current note's files carry, to tell an edit from a leftover.
    private var appliedName = ""
    /// "17-07" (or "17-07 (2)"), the part of the file name that never changes.
    private var timePrefix = ""
    /// Real names for speaker labels, e.g. "Them 1" → "Ana". Set after a meeting.
    private(set) var speakerNames: [String: String] = [:]
    /// Voiceprints of this meeting's other voices, by label ("Them 1", or "Them" if one).
    private var voiceprints: [String: [Float]] = [:]
    /// Tentative recognitions waiting for confirmation, by label: "Them 2" → "Ana".
    private(set) var voiceGuesses: [String: String] = [:]
    /// Labels named automatically because their voice matched someone known.
    private(set) var recognized: Set<String> = []
    /// People whose voices can be recognized in later meetings.
    let voices = VoiceLibrary()
    /// Remember the voices of people the user names, and recognize them later.
    var recognizeVoices: Bool {
        didSet { UserDefaults.standard.set(recognizeVoices, forKey: "recognizeVoices") }
    }
    /// The file this transcript came from, for meetings transcribed from a recording.
    private(set) var sourceFile: String?
    /// The calendar event this recording belongs to, when there is one.
    private(set) var meeting: MeetingInfo?
    /// A choice made in the calendar menu before recording started: an event,
    /// or explicitly none. Used instead of looking one up.
    private var preselection: Preselection = .unset
    private enum Preselection { case unset, event(MeetingInfo), noEvent }
    /// The meeting name came from the calendar (so picking another event may replace it).
    private var nameFromCalendar = false
    /// The call app this recording was started for; it stops when that call ends.
    private(set) var callApp: CallApp?
    /// The call session this recording was started for (`CallTracker`): only that
    /// call ending stops it.
    private(set) var callSessionID: UUID?
    /// That call's Google Meet code, which puts the calendar event with the same
    /// Meet link first in the calendar menu.
    private(set) var callMeetingCode: String?
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
    /// Whether this meeting's WAV tracks live next to the note (vs. temporary files).
    private var tracksKept = false
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
            if isRecording { writeNote() }
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
    private let separation = SpeakerSeparation()
    /// Call audio for speaker separation; a temporary copy when audio isn't kept.
    private var themAudio: URL?
    /// Mic audio for the language check; a temporary copy when audio isn't kept.
    private var meAudio: URL?
    private var vad: VadManager?
    private var mic: MicCapture?
    private var tap: SystemAudioTap?
    private var streams: [StreamTranscriber] = []
    private var feeders: [Task<Void, Never>] = []
    /// Each stream's input: audio, plus erase requests kept in order with it.
    private var feeds: [Speaker: AsyncStream<StreamTranscriber.Feed>.Continuation] = [:]
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
    /// Undo records for voices learned in this meeting, by label, so correcting
    /// a name doesn't leave the voice remembered under the wrong one.
    private var learned: [String: VoiceLibrary.LearnUndo] = [:]
    /// When Wingman last wrote the note, to notice edits made outside Wingman.
    private var noteWrittenAt: Date?

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

    // MARK: - Start / stop

    /// Starts recording because a call started. A Google Meet call's meeting code
    /// picks the calendar event with the same Meet link.
    func start(for session: CallSession) async {
        await start(meetCode: session.meetingCode)
        if isRecording {
            callApp = session.app
            callSessionID = session.id
            callMeetingCode = session.meetingCode
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

        var createdNote: URL?
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

            let started = Date()
            // A name still showing from the previous meeting belongs to that one.
            var name = meetingName
            var fromCalendar = nameFromCalendar
            if currentNote != nil && meetingName == appliedName {
                name = ""
                fromCalendar = false
            }
            let event: MeetingInfo?
            switch preselection {
            case .event(let picked): event = picked
            case .noEvent: event = nil
            case .unset: event = useCalendar ? CalendarLookup.currentMeeting(at: started, meetCode: meetCode) : nil
            }
            if let event, name.trimmingCharacters(in: .whitespaces).isEmpty, !event.title.isEmpty {
                name = event.title
                fromCalendar = true
            }
            // The previous meeting stays as it is until the new note's folder exists.
            let base = try makeNoteBase(for: started, name: name)
            meetingName = name
            nameFromCalendar = fromCalendar
            meeting = event
            preselection = .unset
            Log.write("calendar event: \(event == nil ? "none" : "matched")")
            speakerNames = [:]
            sourceFile = nil
            voiceprints = [:]
            voiceGuesses = [:]
            recognized = []
            learned = [:]
            callApp = nil
            callSessionID = nil
            callMeetingCode = nil
            appliedName = meetingName
            lines = []
            startedAt = started
            endedAt = nil
            recordingID = UUID()
            currentNote = base.appendingPathExtension("md")
            noteWrittenAt = nil
            noteSaved = false
            noteSaveError = nil
            reportedProblems = []
            createdNote = currentNote
            writeNote()

            tracksKept = keepAudio && keepSeparateTracks
            let meURL = tracksKept
                ? audioURL(base, "me")
                : Self.scratchFile("wingman-\(UUID().uuidString).wav")
            meAudio = meURL
            let me = makeStream(.me, vad: vad, audio: meURL, mutedBy: muteFlag)
            let themURL = tracksKept
                ? audioURL(base, "them")
                : Self.scratchFile("wingman-\(UUID().uuidString).wav")
            themAudio = themURL
            let them = makeStream(.them, vad: vad, audio: themURL)

            meSink = me
            themSink = them
            speakersUsed = !AudioDeviceMonitor.outputIsHeadphones()
            do {
                try startMic()
            } catch {
                throw StartError("The microphone couldn't start: \(error.localizedDescription)")
            }
            startTap()

            phase = .recording
            watchForSilentSystemAudio()
            watchForSilentMicrophone()
            deviceMonitor = AudioDeviceMonitor { [weak self] in
                Task { await self?.reconnect(reason: .deviceChanged) }
            }
        } catch {
            await teardown()
            // Only this attempt's files: until the new note exists, `currentNote`
            // is still the previous meeting's, which must never be deleted.
            if let createdNote, currentNote == createdNote { discardEmptyNote() }
            lastError = error.localizedDescription
            phase = .idle
        }
    }

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

    private enum ReconnectReason {
        case deviceChanged, micInterrupted

        /// A device change rebuilds everything, so it wins over a mic hiccup.
        func merged(with other: ReconnectReason?) -> ReconnectReason {
            self == .deviceChanged || other == .deviceChanged ? .deviceChanged : .micInterrupted
        }
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

        let elapsed = startedAt.map { Self.timestamp(Date().timeIntervalSince($0)) } ?? ""
        if !AudioDeviceMonitor.outputIsHeadphones() { speakersUsed = true }
        let output = AudioDeviceMonitor.defaultOutputName() ?? "new output"
        let input = AudioDeviceMonitor.defaultInputName() ?? "new microphone"
        notice = "Audio devices changed at \(elapsed) — now listening on \(input), call audio from \(output)."
        Log.write("reconnected capture (\(reason)) — input \(input), output \(output)")
    }

    private struct StartError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// A recording that never started leaves no files behind.
    private func discardEmptyNote() {
        guard let note = currentNote else { return }
        let base = note.deletingPathExtension()
        for url in [note, audioURL(base, "me"), audioURL(base, "them")] {
            try? FileManager.default.removeItem(at: url)
        }
        for url in [themAudio, meAudio].compactMap({ $0 }) { try? FileManager.default.removeItem(at: url) }
        themAudio = nil
        meAudio = nil
        currentNote = nil
        startedAt = nil
    }

    // MARK: - Transcribing a file

    /// Transcribes a recording or video file instead of listening live: much
    /// faster than playing it back, and the microphone isn't involved. Every
    /// voice in the file counts as "Them", then goes through the same
    /// language check, speaker separation and recognition as a live meeting.
    func transcribeFile(_ url: URL) async {
        guard phase == .idle, !quitting else { return }
        lastError = nil
        warning = nil
        notice = nil
        let scratch = Self.scratchFile("wingman-import-\(UUID().uuidString).wav")
        do {
            phase = .preparing("Loading speech model…")
            try await engine.load()
            if vad == nil { vad = try await VadManager() }
            guard let vad else { throw StartError("The voice detector couldn't load.") }

            phase = .finishing("Reading \(url.lastPathComponent)…")
            let samples = try await AudioExtractor.samples(from: url)
            guard !samples.isEmpty else { throw AudioExtractorError("\(url.lastPathComponent) has no audio.") }
            try await Task.detached { try AudioExtractor.write(samples, to: scratch) }.value

            // Set up a note like a live meeting, named after the file.
            let started = Date()
            let name = url.deletingPathExtension().lastPathComponent
            let base = try makeNoteBase(for: started, name: name)
            meetingName = name
            nameFromCalendar = false
            preselection = .unset
            speakerNames = [:]
            voiceprints = [:]
            voiceGuesses = [:]
            recognized = []
            learned = [:]
            callApp = nil
            callSessionID = nil
            callMeetingCode = nil
            meeting = nil
            sourceFile = url.lastPathComponent
            appliedName = meetingName
            lines = []
            startedAt = started
            endedAt = started.addingTimeInterval(Double(samples.count) / Resampler.sampleRate)
            currentNote = base.appendingPathExtension("md")
            noteWrittenAt = nil
            noteSaved = false
            noteSaveError = nil
            reportedProblems = []
            tracksKept = false
            meAudio = nil
            themAudio = scratch

            phase = .finishing("Finding speech…")
            var config = VadSegmentationConfig.default
            config.minSilenceDuration = 0.5
            let segments = try await vad.segmentSpeech(samples, config: config)
            let rate = Int(Resampler.sampleRate)
            for (i, segment) in segments.enumerated() {
                phase = .finishing("Transcribing \(url.lastPathComponent)… \(Int(Double(i) / Double(max(segments.count, 1)) * 100))%")
                let from = max(0, segment.startSample(sampleRate: rate))
                let to = min(samples.count, segment.endSample(sampleRate: rate))
                guard to > from else { continue }
                let (text, confidence) = try await engine.transcribeScored(Array(samples[from..<to]))
                guard !text.isEmpty else { continue }
                lines.append(TranscriptLine(id: UUID(), speaker: .them, start: segment.startTime, end: segment.endTime,
                                            text: text, isFinal: true, confidence: confidence))
            }
            writeNote()
            await checkLanguages()
            await separateSpeakers()
            _ = await saveCombinedAudio()
        } catch {
            lastError = "Couldn't transcribe \(url.lastPathComponent): \(error.localizedDescription)"
        }
        try? FileManager.default.removeItem(at: scratch)
        themAudio = nil
        phase = .idle
        cleanUpAudio()
    }

    /// Stops recording and moves everything it saved to the Trash.
    func discard() async {
        guard phase == .recording else { return }
        phase = .finishing("Discarding…")
        await teardown()
        let fm = FileManager.default
        var notTrashed = 0
        if let note = currentNote {
            let folder = note.deletingLastPathComponent()
            let base = note.deletingPathExtension().lastPathComponent
            for suffix in Self.companionSuffixes {
                let url = folder.appendingPathComponent(base + suffix)
                guard fm.fileExists(atPath: url.path) else { continue }
                do {
                    try fm.trashItem(at: url, resultingItemURL: nil)
                } catch {
                    notTrashed += 1
                    Log.write("couldn't move a discarded file to the Trash: \(Log.describe(error))")
                }
            }
        }
        // Temporary tracks (audio not kept) are Wingman's own scratch files; kept
        // tracks were handled above, and never get deleted outright.
        if !tracksKept {
            for url in [meAudio, themAudio].compactMap({ $0 }) where fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
            }
        }
        meAudio = nil
        themAudio = nil
        lines = []
        currentNote = nil
        startedAt = nil
        callApp = nil
        callSessionID = nil
        callMeetingCode = nil
        meeting = nil
        meetingName = ""
        appliedName = ""
        nameFromCalendar = false
        notice = notTrashed == 0
            ? "Recording discarded — its files are in the Trash."
            : "Recording discarded, but \(notTrashed == 1 ? "one of its files" : "\(notTrashed) of its files") couldn't be moved to the Trash: \(notTrashed == 1 ? "it's" : "they're") still in the meeting's folder."
        phase = .idle
    }

    /// Names to offer when renaming a speaker: invited people not already used.
    var suggestedNames: [String] {
        guard let meeting else { return [] }
        let used = Set(speakerNames.values)
        var names = meeting.attendees
        if let organizer = meeting.organizer, !names.contains(organizer) { names.insert(organizer, at: 0) }
        return names.filter { !used.contains($0) }
    }

    func stop() async {
        guard phase == .recording else { return }
        phase = .finishing("Finishing transcript…")
        await teardown()
        endedAt = Date()
        applyMeetingName()
        writeNote()
        await checkLanguages()
        await separateSpeakers()
        let saved = await saveCombinedAudio()
        if tracksKept {
            await compressTracks()
        } else if saved {
            for url in [meAudio, themAudio].compactMap({ $0 }) { try? FileManager.default.removeItem(at: url) }
        } else if keepTemporaryTracks() {
            warning = (warning ?? "") + " The separate tracks were kept next to the note instead."
        } else {
            warning = (warning ?? "") + " The separate tracks couldn't be kept either."
        }
        meAudio = nil
        themAudio = nil
        phase = .idle
        cleanUpAudio()
    }

    /// The separate tracks are recorded as WAV next to the note, so they survive
    /// Wingman quitting mid-meeting; once the meeting is done they're kept as
    /// .m4a, about a tenth of the size. A WAV stays if its copy couldn't be made.
    private func compressTracks() async {
        phase = .finishing("Saving audio…")
        let fm = FileManager.default
        for speaker in [Speaker.me, .them] {
            guard let track = speaker == .me ? meAudio : themAudio else { continue }
            let copy = Self.scratchFile("wingman-\(UUID().uuidString).m4a")
            do {
                try await Task.detached(priority: .userInitiated) { try AudioMix.mix([track], to: copy) }.value
                // Renaming the meeting meanwhile moves the track: follow it.
                guard let current = speaker == .me ? meAudio : themAudio else { continue }
                let output = current.deletingPathExtension().appendingPathExtension("m4a")
                try? fm.removeItem(at: output)
                try fm.moveItem(at: copy, to: output)
                try fm.removeItem(at: current)
            } catch {
                try? fm.removeItem(at: copy)
                Log.write("couldn't compress the \(speaker) track, kept the WAV: \(Log.describe(error))")
            }
        }
    }

    /// Applies the audio rules from Settings → Audio in the background. Never
    /// while a meeting is recording or finishing, and never to the meeting in
    /// the window.
    func cleanUpAudio() {
        guard phase == .idle, removeAudioAfterDays > 0 || audioLimitGB > 0 else { return }
        let keep = Set([currentNote].compactMap { $0.map(AudioCleanup.key(for:)) })
        let (days, limit, folder, previous) = (removeAudioAfterDays, audioLimitGB, Self.notesFolder, cleanup)
        cleanup = Task.detached(priority: .utility) {
            await previous?.value
            AudioCleanup.run(in: folder, maxAgeDays: days, limitGB: limit, keep: keep)
        }
    }

    func cleanupFinished() async { await cleanup?.value }

    /// Writes "<meeting>.m4a": both sides mixed into one small file. Returns
    /// false only when that was wanted and failed.
    private func saveCombinedAudio() async -> Bool {
        guard keepAudio, let note = currentNote else { return true }
        let tracks = [meAudio, themAudio].compactMap { $0 }
        guard !tracks.isEmpty else { return true }
        phase = .finishing("Saving audio…")
        let output = note.deletingPathExtension().appendingPathExtension("m4a")
        do {
            try await Task.detached(priority: .userInitiated) { try AudioMix.mix(tracks, to: output) }.value
            return true
        } catch {
            warning = "Couldn't save the combined audio (\(error.localizedDescription))."
            Log.write("combined audio failed: \(Log.describe(error))")
            return false
        }
    }

    /// The combined audio failed: rather than delete the only copy of the
    /// meeting's audio, move the temporary tracks next to the note.
    /// Moves the temporary tracks next to the note; true when every one made it.
    private func keepTemporaryTracks() -> Bool {
        guard let note = currentNote else { return false }
        let base = note.deletingPathExtension()
        var kept = true
        for (url, suffix) in [(meAudio, "me"), (themAudio, "them")] {
            guard let url, FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.moveItem(at: url, to: audioURL(base, suffix))
            } catch {
                Log.write("couldn't keep the \(suffix) track: \(Log.describe(error))")
                kept = false
            }
        }
        return kept
    }

    /// The after-meeting language review (see LanguageReview): lines the live
    /// engine was unsure about, or that came out in a language that isn't
    /// enabled, are transcribed again from their audio. Echoes are filtered
    /// again afterwards, since the two copies may only now read alike.
    private func checkLanguages() async {
        var audio: [Speaker: URL] = [:]
        if let meAudio { audio[.me] = meAudio }
        if let themAudio { audio[.them] = themAudio }
        let enabled = enabledLanguages
        let snapshot = lines
        guard snapshot.contains(where: { LanguageReview.needsReview($0, enabled: enabled) }) else { return }

        phase = .finishing("Reviewing languages…")
        let fixes = await LanguageReview.fixes(for: snapshot, audio: audio, enabled: enabled, main: mainLanguage) {
            [weak self] message in self?.phase = .finishing(message)
        }
        for fix in fixes {
            guard let index = lines.firstIndex(where: { $0.id == snapshot[fix.index].id }) else { continue }
            lines[index].text = fix.text
            if fix.languageFixed { lines[index].rechecked = true }
        }
        for line in lines where line.isFinal && line.speaker == .them { removeEchoes(around: line) }
        writeNote()
    }

    /// Relabels "Them" lines as Them 1, Them 2, … using the call-audio track.
    private func separateSpeakers() async {
        guard let audio = themAudio else { return }
        let themIndices = lines.indices.filter { lines[$0].speaker == .them && lines[$0].isFinal }
        guard themIndices.count > 1 else { return }

        phase = .finishing("Identifying speakers (the first time downloads ~20 MB)…")
        do {
            let result = try await separation.separate(audio)
            let numbered = SpeakerSeparation.numbered(result.turns, themIndices.map { (lines[$0].start, lines[$0].end) })
            for (index, voice) in zip(themIndices, numbered.voices) {
                lines[index].voice = voice
            }
            if numbered.ids.isEmpty {
                // One remote voice: it keeps the plain "Them" label.
                if result.voiceprints.count == 1, let only = result.voiceprints.values.first { voiceprints["Them"] = only }
            } else {
                for (number, id) in numbered.ids {
                    if let print = result.voiceprints[id] { voiceprints["Them \(number)"] = print }
                }
            }
            recognizePeople()
            writeNote()
        } catch {
            warning = "Couldn't tell the other speakers apart (\(error.localizedDescription)). They're all labeled \"Them\"."
        }
    }

    // MARK: - Export

    /// Writes the current transcript as subtitles next to the note and returns the file.
    func exportSubtitles(_ format: SubtitleExport.Format) -> URL? {
        applyMeetingName()
        guard let currentNote, lines.contains(where: \.isFinal) else { return nil }
        let url = currentNote.deletingPathExtension().appendingPathExtension(format.rawValue)
        do {
            let title = meetingName.trimmingCharacters(in: .whitespaces)
            try SubtitleExport.render(lines, as: format, title: title.isEmpty ? nil : title, names: exportNames)
                .write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            lastError = "Couldn't save \(url.lastPathComponent): \(error.localizedDescription)"
            return nil
        }
    }

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
        feeds = [:]
        feeders = []
        streams = []
    }

    /// Creates the transcriber for one stream and returns the callback the
    /// audio thread uses to hand it samples (in order, without blocking).
    private func makeStream(_ speaker: Speaker, vad: VadManager, audio: URL?, mutedBy flag: LockedFlag? = nil) -> ([Float]) -> Void {
        let stream = StreamTranscriber(speaker: speaker, engine: engine, vad: vad, audioFileURL: audio,
                                       onProblem: { [weak self] problem in await self?.streamProblem(speaker, problem) }) { [weak self] event in
            await self?.handle(event)
        }
        let (input, continuation) = AsyncStream<StreamTranscriber.Feed>.makeStream(bufferingPolicy: .unbounded)
        feeders.append(Task.detached(priority: .userInitiated) {
            for await item in input { await stream.take(item) }
        })
        streams.append(stream)
        feeds[speaker] = continuation
        let aligner = ClockAligner { continuation.yield(.samples($0)) }
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

    private func handle(_ event: TranscriptEvent) {
        let index = lines.firstIndex { $0.id == event.utteranceID }
        if event.isFinal && event.failed {
            // Recognition failed, which isn't silence: keep what was shown so far, marked.
            guard let index, !lines[index].text.isEmpty else {
                if let index { lines.remove(at: index) }
                return
            }
            lines[index].isFinal = true
            lines[index].incomplete = true
            lines[index].end = event.end
            writeNote()
            return
        }
        if event.isFinal && event.text.isEmpty {
            if let index { lines.remove(at: index) }
            return
        }
        let line = TranscriptLine(id: event.utteranceID, speaker: event.speaker, start: event.start,
                                  end: event.end, text: event.text, isFinal: event.isFinal,
                                  confidence: event.confidence)
        if let index {
            lines[index] = line
        } else if !event.text.isEmpty {
            let position = lines.firstIndex { $0.start > line.start } ?? lines.endIndex
            lines.insert(line, at: position)
        }
        if event.isFinal {
            removeEchoes(around: line)
            writeNote()
        }
    }

    /// Safety net for echo: if the mic picked up the call from the speakers,
    /// the same words show up as both "Them" and "Me" at the same moment.
    /// Keep the "Them" copy.
    /// On speakers the microphone also hears the call. A line of yours that
    /// clearly repeats theirs is that echo and goes; one that's only similar
    /// stays, marked, since it may be a real reply ("We should *not* deploy").
    private func removeEchoes(around line: TranscriptLine) {
        guard speakersUsed else { return }
        let others = lines.filter {
            $0.isFinal && $0.speaker != line.speaker
                && $0.start < line.end + 1.5 && line.start < $0.end + 1.5
        }
        for other in others {
            let (mine, theirs) = line.speaker == .me ? (line, other) : (other, line)
            switch Self.echoVerdict(mine: mine.text, theirs: theirs.text, delay: mine.start - theirs.start) {
            case .echo:
                lines.removeAll { $0.id == mine.id }
            case .possible:
                if let i = lines.firstIndex(where: { $0.id == mine.id }) { lines[i].possibleEcho = true }
            case .none:
                break
            }
        }
    }

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
    static func echoVerdict(mine: String, theirs: String, delay: TimeInterval) -> EchoVerdict {
        let a = words(mine), b = words(theirs)
        guard !a.isEmpty, !b.isEmpty else { return .none }
        let lengthRatio = Double(min(a.count, b.count)) / Double(max(a.count, b.count))
        if (-0.5...1.5).contains(delay), a.count >= 3, lengthRatio >= 0.75,
           orderedSimilarity(a, b) >= 0.85, negations(a) == negations(b) {
            return .echo
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

    /// Lowercased words; apostrophes stay inside them ("don't" is one word).
    private static func words(_ s: String) -> [String] {
        s.lowercased().replacingOccurrences(of: "’", with: "'")
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Files

    /// Picks the files' place and time prefix for a new note named `name`.
    /// Changes nothing else, so a failure leaves the previous meeting as it was.
    private func makeNoteBase(for date: Date, name: String) throws -> URL {
        let fm = FileManager.default
        try Self.createNotesFolder()
        let folder = Self.notesFolder.appendingPathComponent(Self.dayFolderName(for: date), isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let time = Self.timeOfDay(date)
        var prefix = time
        var n = 2
        while fm.fileExists(atPath: base(in: folder, prefix: prefix, name: name).appendingPathExtension("md").path) {
            prefix = "\(time) (\(n))"
            n += 1
        }
        timePrefix = prefix
        return base(in: folder, prefix: prefix, name: name)
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

    /// "17-07 Weekly sync" — time first so files sort, then the meeting name.
    private func base(in folder: URL, prefix: String? = nil, name: String? = nil) -> URL {
        let prefix = prefix ?? timePrefix
        let name = Self.fileSafe(name ?? meetingName)
        return folder.appendingPathComponent(name.isEmpty ? prefix : "\(prefix) \(name)")
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
    func removeLeftoverScratch() {
        guard phase == .idle else { return }
        let fm = FileManager.default
        var leftovers = (try? fm.contentsOfDirectory(at: Self.scratchFolder, includingPropertiesForKeys: nil)) ?? []
        leftovers += ((try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("wingman-") && ["wav", "m4a"].contains($0.pathExtension) }
        var removed = 0
        for url in leftovers where (try? fm.removeItem(at: url)) != nil { removed += 1 }
        if removed > 0 { Log.write("removed \(removed) leftover scratch audio file\(removed == 1 ? "" : "s") from an earlier session") }
        if removed < leftovers.count { Log.write("couldn't remove \(leftovers.count - removed) leftover scratch audio file(s)") }
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

    /// 255 bytes minus the prefix ("HH-mm (99) ") and suffix, with room to spare.
    static let maxNameBytes = 200

    private static let companionSuffixes = [".md", ".m4a", "-me.m4a", "-them.m4a", "-me.wav", "-them.wav", ".vtt", ".srt"]

    /// Renames the current meeting's files to match `meetingName`. Safe while
    /// recording: open audio files keep writing after a rename.
    func applyMeetingName() {
        if meetingName != meeting?.title { nameFromCalendar = false }
        guard let note = currentNote, meetingName != appliedName else { return }
        let folder = note.deletingLastPathComponent()
        let oldBase = note.deletingPathExtension()
        let newBase = base(in: folder)
        guard newBase.lastPathComponent != oldBase.lastPathComponent else {
            appliedName = meetingName
            writeNote()
            return
        }
        let fm = FileManager.default
        // On a case-insensitive disk, a change of upper/lower case only finds the
        // same file under the new name: that's a rename, not a clash.
        let newNote = newBase.appendingPathExtension("md")
        if fm.fileExists(atPath: newNote.path), !Self.isSameFile(note, newNote) {
            lastError = "A meeting named \"\(newBase.lastPathComponent)\" already exists in this folder."
            return
        }
        var failed: String?
        var noteMoved = false
        for suffix in Self.companionSuffixes {
            let from = folder.appendingPathComponent(oldBase.lastPathComponent + suffix)
            let to = folder.appendingPathComponent(newBase.lastPathComponent + suffix)
            guard fm.fileExists(atPath: from.path) else { continue }
            do {
                if Self.isSameFile(from, to) {
                    // Via a temporary name; put it back if the second step fails.
                    let step = folder.appendingPathComponent(".wingman-rename-\(UUID().uuidString)\(suffix)")
                    try fm.moveItem(at: from, to: step)
                    do {
                        try fm.moveItem(at: step, to: to)
                    } catch {
                        try? fm.moveItem(at: step, to: from)
                        throw error
                    }
                } else {
                    try fm.moveItem(at: from, to: to)
                }
                if suffix == ".md" { noteMoved = true }
                if themAudio == from { themAudio = to }
                if meAudio == from { meAudio = to }
            } catch {
                failed = failed ?? "Couldn't rename \(from.lastPathComponent): \(error.localizedDescription)"
            }
        }
        // The note itself couldn't move: keep pointing at it, under its old name.
        if !noteMoved, fm.fileExists(atPath: note.path) {
            lastError = failed
            return
        }
        currentNote = newNote
        appliedName = meetingName
        lastError = failed
        writeNote()
    }

    /// Whether two paths name the same file (e.g. only upper/lower case differs
    /// on a case-insensitive disk). False if either doesn't exist.
    private static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        let key = URLResourceKey.fileResourceIdentifierKey
        // Fresh URL objects, so cached resource values can't answer for an old state.
        guard let idA = try? URL(fileURLWithPath: a.path).resourceValues(forKeys: [key]).fileResourceIdentifier,
              let idB = try? URL(fileURLWithPath: b.path).resourceValues(forKeys: [key]).fileResourceIdentifier
        else { return false }
        return idA.isEqual(idB)
    }

    // MARK: - Speaker names

    /// The labels in this transcript, in order of first appearance.
    var speakerLabels: [String] {
        var seen: [String] = []
        for line in lines where line.isFinal && !seen.contains(line.label) { seen.append(line.label) }
        return seen
    }

    /// Labels voices that match people named in earlier meetings: confident
    /// matches by name, the rest as "Name?" for the user to confirm.
    private func recognizePeople() {
        guard recognizeVoices, !voiceprints.isEmpty, !voices.people.isEmpty else { return }
        let invitees = (meeting?.attendees ?? []) + [meeting?.organizer].compactMap { $0 }
        // Re-runs (e.g. after picking a calendar event) leave the user's own names alone.
        let namedByUser = Set(speakerNames.keys).subtracting(recognized)
        for label in recognized { speakerNames[label] = nil }
        recognized = []
        voiceGuesses = voiceGuesses.filter { namedByUser.contains($0.key) }
        var known: [String] = [], unsure: [String] = []
        for (label, match) in voices.match(voiceprints.filter { !namedByUser.contains($0.key) }, invitees: invitees) {
            if match.confident {
                speakerNames[label] = match.name
                recognized.insert(label)
                known.append(match.name)
            } else {
                voiceGuesses[label] = match.name
                unsure.append(match.name)
            }
        }
        var parts: [String] = []
        if !known.isEmpty { parts.append("Recognized \(known.sorted().joined(separator: ", ")) from earlier meetings.") }
        if !unsure.isEmpty { parts.append("Click \(unsure.sorted().map { "\($0)?" }.joined(separator: ", ")) to confirm.") }
        if !parts.isEmpty { notice = parts.joined(separator: " ") }
    }

    // MARK: - Calendar event

    /// Attaches a calendar event to this meeting (or detaches it with nil):
    /// its invitees become rename suggestions and recognition candidates, and
    /// its details go in the note. The meeting name follows the event unless
    /// the user typed their own. Before recording, it's used when recording starts.
    func attach(_ new: MeetingInfo?) {
        let oldTitle = meeting?.title
        meeting = new
        let typed = meetingName.trimmingCharacters(in: .whitespaces)
        if typed.isEmpty || nameFromCalendar || typed == oldTitle {
            meetingName = new?.title ?? ""
            nameFromCalendar = new != nil
        }
        Log.write("calendar event \(new == nil ? "detached" : "picked") by user")
        guard currentNote != nil else {
            preselection = new.map { .event($0) } ?? .noEvent
            return
        }
        applyMeetingName()
        recognizePeople()
        writeNote()
    }

    /// Invitees (with the organizer first) and whether each is already a speaker's name.
    var invitees: [(name: String, matched: Bool)] {
        guard let meeting else { return [] }
        var names = meeting.attendees
        if let organizer = meeting.organizer, !names.contains(organizer) { names.insert(organizer, at: 0) }
        let used = Set(speakerNames.values.map { $0.lowercased() })
        return names.map { ($0, used.contains($0.lowercased())) }
    }

    /// The voice-based guess for a label, if one is waiting for confirmation.
    func guess(for label: String) -> String? {
        speakerNames[label] == nil ? voiceGuesses[label] : nil
    }

    func isRecognized(_ label: String) -> Bool { recognized.contains(label) }

    func displayName(_ line: TranscriptLine) -> String {
        if let name = speakerNames[line.label] { return name }
        if let guess = voiceGuesses[line.label] { return "\(guess)?" }
        let mine = myName.trimmingCharacters(in: .whitespaces)
        if line.speaker == .me, !mine.isEmpty { return mine }
        return line.label
    }

    /// Names for exports: per-meeting renames, plus the default name for "Me".
    private var exportNames: [String: String] {
        var names = speakerNames
        for (label, guess) in voiceGuesses where names[label] == nil { names[label] = "\(guess)?" }
        let mine = myName.trimmingCharacters(in: .whitespaces)
        if names[Speaker.me.rawValue] == nil, !mine.isEmpty { names[Speaker.me.rawValue] = mine }
        return names
    }

    func rename(speaker label: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = trimmed.isEmpty || trimmed == label ? nil : trimmed
        guard new != speakerNames[label] || voiceGuesses[label] != nil || recognized.contains(label) else { return }
        speakerNames[label] = new
        voiceGuesses[label] = nil
        recognized.remove(label)
        // A correction: forget what this voice taught Wingman under the old name.
        if let undo = learned.removeValue(forKey: label) { voices.undo(undo) }
        // Naming a remote voice teaches Wingman to recognize it next time.
        if recognizeVoices, let name = new, let print = voiceprints[label] {
            learned[label] = voices.learn(name, voiceprint: print)
        }
        writeNote()
    }

    /// Accepts a "Name?" guess, which also refines that person's voiceprint.
    func confirmGuess(for label: String) {
        guard let name = voiceGuesses[label] else { return }
        rename(speaker: label, to: name)
    }

    private func audioURL(_ base: URL, _ suffix: String) -> URL {
        base.deletingLastPathComponent()
            .appendingPathComponent("\(base.lastPathComponent)-\(suffix).wav")
    }

    /// Writes the note. A failure is shown in the window (with Save Note As…)
    /// and clears `noteSaved`, so no notification or report claims it was saved.
    @discardableResult
    private func writeNote() -> Bool {
        guard let currentNote, let text = noteText() else { return false }
        // After the meeting the note is yours: an edit made in another app, or
        // moving the note to the Trash, wins over a later change in Wingman.
        if phase == .idle, let written = noteWrittenAt {
            guard let modified = Self.modificationDate(currentNote) else {
                notice = "The note was moved or deleted outside Wingman, so this change wasn't saved to it."
                return false
            }
            guard modified == written else {
                notice = "The note was edited outside Wingman, so this change wasn't saved to it (your edits are kept)."
                return false
            }
        }
        do {
            try text.write(to: currentNote, atomically: true, encoding: .utf8)
            noteWrittenAt = Self.modificationDate(currentNote)
            noteSaved = true
            noteSaveError = nil
            return true
        } catch {
            Log.write("couldn't write the note: \(Log.describe(error))")
            noteSaved = false
            noteSaveError = "Wingman couldn't save the note (\(error.localizedDescription)). The transcript is still here: use Save Note As… to keep a copy."
            return false
        }
    }

    /// The note's Markdown, from the meeting in the window.
    private func noteText() -> String? {
        guard let startedAt else { return nil }
        let minutes = Int((endedAt ?? Date()).timeIntervalSince(startedAt) / 60)
        let title = meetingName.trimmingCharacters(in: .whitespaces).isEmpty ? "Meeting" : meetingName
        var text = """
        # \(title)

        **Date:** \(startedAt.formatted(date: .abbreviated, time: .shortened))  
        **Duration:** \(minutes) min

        """
        if let sourceFile { text += "\n**Transcribed from:** \(sourceFile)  \n" }
        if let meeting {
            let time = "\(meeting.start.formatted(date: .omitted, time: .shortened))–\(meeting.end.formatted(date: .omitted, time: .shortened))"
            text += "\n**Calendar:** \(meeting.title.isEmpty ? "Untitled event" : meeting.title), \(time)  \n"
            if let organizer = meeting.organizer { text += "**Organizer:** \(organizer)  \n" }
            if !meeting.attendees.isEmpty { text += "**Invited:** \(meeting.attendees.joined(separator: ", "))  \n" }
            if let link = meeting.link { text += "**Link:** \(link.absoluteString)  \n" }
        }
        text += "\n## Transcript\n"
        for line in lines where line.isFinal {
            let flag = line.incomplete ? " *(incomplete)*" : line.possibleEcho ? " *(possible echo)*" : line.isUnclear ? " *(unclear)*" : ""
            text += "\n[\(Self.timestamp(line.start))] **\(displayName(line)):** \(line.text)\(flag)\n"
        }
        let final = lines.filter(\.isFinal)
        var marks: [String] = []
        if final.contains(where: \.isUnclear) { marks.append("*(unclear)* marks lines the speech model wasn't confident about; check them against the audio.") }
        if final.contains(where: \.incomplete) { marks.append("*(incomplete)* marks lines the speech model failed on; the text is what it had heard so far.") }
        if final.contains(where: \.possibleEcho) { marks.append("*(possible echo)* marks your lines that may be the call coming back through your speakers.") }
        if !marks.isEmpty { text += "\n---\n" + marks.joined(separator: "  \n") + "\n" }
        return text
    }

    /// Save Note As…: the note somewhere else, when it couldn't be saved where it belongs.
    func saveNoteCopy(to url: URL) throws {
        guard let text = noteText() else { return }
        try text.write(to: url, atomically: true, encoding: .utf8)
        notice = "Saved a copy of the note as \(url.lastPathComponent)."
        Log.write("note saved elsewhere (user choice)")
    }

    /// Something a stream couldn't fix by itself: say so once per kind and track.
    private func streamProblem(_ speaker: Speaker, _ problem: StreamProblem) {
        guard phase != .idle else { return }
        let side = speaker == .me ? "your microphone's" : "the call's"
        switch problem {
        case .audioFile(let what):
            guard reportedProblems.insert("audio \(speaker)").inserted else { return }
            Log.write("couldn't save the \(speaker == .me ? "microphone" : "call") audio: \(what)")
            warning = "Wingman couldn't save \(side) audio, so this meeting's audio may be missing or incomplete (is the disk full?). The transcript is still being saved."
        case .recognition:
            guard reportedProblems.insert("recognition").inserted else { return }
            warning = "Wingman's speech recognition failed on some lines; what it had heard of them is kept, marked (incomplete)."
        case .voiceDetection:
            guard reportedProblems.insert("detection \(speaker)").inserted else { return }
            Log.write("voice detection keeps failing (\(speaker == .me ? "microphone" : "call"))")
            warning = "Wingman's voice detection isn't working for \(side) audio, so some speech may be missing from the transcript (the audio is still saved)."
        }
    }

    /// Read fresh each time (URL resource values are cached per URL instance).
    private static func modificationDate(_ url: URL) -> Date? {
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
