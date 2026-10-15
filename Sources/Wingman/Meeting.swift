import AppKit
import Foundation
import Observation

/// One meeting: its transcript, speakers, note and audio files, and the work
/// after it ends (language review, telling speakers apart, saving audio). The
/// `Recorder` captures audio and feeds whichever meeting is recording; a meeting
/// that ended finishes on its own, so the next call can record meanwhile. Each
/// has its own window.
@MainActor
@Observable
final class Meeting: Identifiable {
    enum Stage: Equatable {
        case recording
        /// After the recording, with what's being done.
        case finishing(String)
        case done

        var isFinishing: Bool { if case .finishing = self { true } else { false } }
    }

    /// Also its id in `MeetingIndex` and for the voices learned from it.
    let id = UUID()
    /// For recovery records and notifications about this recording.
    let recordingID = UUID()
    private(set) var stage: Stage
    unowned let recorder: Recorder

    private(set) var lines: [TranscriptLine] = []
    /// Where this meeting starts in the recorder's capture, in seconds (0 unless
    /// it was split off a running recording).
    let origin: TimeInterval

    private(set) var warning: String?
    var notice: String?
    var lastError: String?
    /// Whether the note on disk has this meeting (false while it couldn't be written).
    private(set) var noteSaved = false
    private(set) var noteSaveError: String?
    private var reportedProblems: Set<String> = []
    /// The call played through speakers at some point, so the microphone may
    /// have heard it (no echo filtering when it's headphones only).
    var speakersUsed = true

    private(set) var currentNote: URL?
    private(set) var startedAt: Date?
    /// Hash of the note as last written (`MeetingIndex.Meeting.noteHash`).
    private var noteHash: String?
    private(set) var endedAt: Date?
    /// What the user calls this meeting; it becomes part of every file name.
    var meetingName = ""
    private var appliedName = ""
    /// "2026-10-07_01", the part of the file names that never changes.
    private let notePrefix: String
    private(set) var speakerNames: [String: String] = [:]
    private var voiceprints: [String: [Float]] = [:]
    private(set) var voiceGuesses: [String: String] = [:]
    private(set) var recognized: Set<String> = []
    private var speakerIDs: [String: UUID] = [:]
    private(set) var differentVoice: DifferentVoice?
    struct DifferentVoice: Equatable {
        let label: String
        let name: String
    }
    private(set) var sourceFile: String?
    /// The calendar event this meeting belongs to, when there is one.
    private(set) var meeting: MeetingInfo?
    private var nameFromCalendar = false
    /// The call this meeting was recorded for.
    var callApp: CallApp?
    var callSessionID: UUID?
    var callMeetingCode: String?
    /// Whether the WAV tracks live next to the note (vs. scratch files).
    let tracksKept: Bool
    private(set) var meAudio: URL?
    private(set) var themAudio: URL?
    private var learned: [String: UUID] = [:]
    private var noteWrittenAt: Date?
    /// Done when everything after the recording is (see `waitUntilDone`).
    private var finishing: Task<Void, Never>?
    /// Split off the previous meeting automatically: offered to join back for a minute.
    var joinable = false

    init(recorder: Recorder, stage: Stage, origin: TimeInterval, started: Date, name: String, event: MeetingInfo?,
         nameFromCalendar: Bool, base: URL, prefix: String, tracksKept: Bool, meAudio: URL?, themAudio: URL?, sourceFile: String? = nil) {
        self.recorder = recorder
        self.stage = stage
        self.origin = origin
        self.startedAt = started
        self.meetingName = name
        self.appliedName = name
        self.meeting = event
        self.nameFromCalendar = nameFromCalendar
        self.currentNote = base.appendingPathExtension("md")
        self.notePrefix = prefix
        self.tracksKept = tracksKept
        self.meAudio = meAudio
        self.themAudio = themAudio
        self.sourceFile = sourceFile
        writeNote()
        saveRecoveryRecord()
    }

    var isRecording: Bool { stage == .recording }

    // MARK: - Transcript

    func handle(_ event: TranscriptEvent) {
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

    /// Lines a split moved here from the previous meeting (or back on a join).
    func adopt(_ moved: [TranscriptLine]) {
        guard !moved.isEmpty else { return }
        lines = (lines + moved).sorted { $0.start < $1.start }
        writeNote()
    }

    /// Takes out the lines that started at or after `start` (for a split).
    func release(from start: TimeInterval) -> [TranscriptLine] {
        let moved = lines.filter { $0.start >= start }
        lines.removeAll { $0.start >= start }
        writeNote()
        return moved
    }

    /// A partial line still waiting for its final text.
    var hasLiveLine: Bool { lines.contains { !$0.isFinal } }

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
            switch Recorder.echoVerdict(mine: mine.text, theirs: theirs.text, delay: mine.start - theirs.start) {
            case .echo:
                lines.removeAll { $0.id == mine.id }
            case .possible:
                if let i = lines.firstIndex(where: { $0.id == mine.id }) { lines[i].possibleEcho = true }
            case .none:
                break
            }
        }
    }

    /// Something a stream couldn't fix by itself: say so once per kind and track.
    func streamProblem(_ speaker: Speaker, _ problem: StreamProblem) {
        guard stage == .recording else { return }
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

    func setWarning(_ text: String?) { warning = text }

    /// When the meeting stopped taking audio: Stop, or the split that started
    /// the next one (finishing comes later). A join clears it.
    func setEnded(_ date: Date?) { endedAt = date }

    // MARK: - After the recording

    /// Ends the recording and runs everything after it in the background.
    /// `waitUntilDone` waits for it.
    func finish(transcribedFrom file: (samples: Int, scratch: URL)? = nil) {
        guard finishing == nil else { return }
        endedAt = file.map { startedAt!.addingTimeInterval(Double($0.samples) / Resampler.sampleRate) } ?? endedAt ?? Date()
        stage = .finishing("Finishing transcript…")
        finishing = Task { [weak self] in
            guard let self else { return }
            // A partial line left by a split or a stop becomes final as it is.
            for i in lines.indices where !lines[i].isFinal && !lines[i].text.isEmpty { lines[i].isFinal = true }
            lines.removeAll { !$0.isFinal }
            applyMeetingName()
            writeNote()
            await checkLanguages()
            await separateSpeakers()
            let saved = await saveCombinedAudio()
            if let file {
                try? FileManager.default.removeItem(at: file.scratch)
                themAudio = nil
            } else if tracksKept {
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
            RecordingRecovery.remove(id: recordingID, in: Recorder.scratchFolder)
            stage = .done
            recorder.meetingFinished(self)
        }
    }

    func waitUntilDone() async { await finishing?.value }

    /// What the next launch needs to finish this recording's audio if Wingman
    /// doesn't get to (see `RecordingRecovery`).
    func saveRecoveryRecord() {
        guard sourceFile == nil, let note = currentNote, stage != .done else { return }
        let record = RecordingRecovery.Record(note: note, tracks: [meAudio, themAudio].compactMap { $0 },
                                              keepAudio: recorder.keepAudio, tracksKept: tracksKept, started: startedAt ?? Date())
        RecordingRecovery.save(record, id: recordingID, in: Recorder.scratchFolder)
    }

    /// The separate tracks are recorded as WAV next to the note, so they survive
    /// Wingman quitting mid-meeting; once the meeting is done they're kept as
    /// .m4a, about a tenth of the size. A WAV stays if its copy couldn't be made.
    private func compressTracks() async {
        stage = .finishing("Saving audio…")
        let fm = FileManager.default
        for speaker in [Speaker.me, .them] {
            guard let track = speaker == .me ? meAudio : themAudio else { continue }
            let copy = Recorder.scratchFile("wingman-\(UUID().uuidString).m4a")
            do {
                try await Task.detached(priority: .utility) { try AudioMix.mix([track], to: copy) }.value
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

    /// Writes "<meeting>.m4a": both sides mixed into one small file. Returns
    /// false only when that was wanted and failed.
    private func saveCombinedAudio() async -> Bool {
        guard recorder.keepAudio, let note = currentNote else { return true }
        let tracks = [meAudio, themAudio].compactMap { $0 }
        guard !tracks.isEmpty else { return true }
        stage = .finishing("Saving audio…")
        let output = note.deletingPathExtension().appendingPathExtension("m4a")
        do {
            try await Task.detached(priority: .utility) { try AudioMix.mix(tracks, to: output) }.value
            return true
        } catch {
            warning = "Couldn't save the combined audio (\(error.localizedDescription))."
            Log.write("combined audio failed: \(Log.describe(error))")
            return false
        }
    }

    /// The combined audio failed: rather than delete the only copy of the
    /// meeting's audio, move the temporary tracks next to the note. True when
    /// every one made it.
    private func keepTemporaryTracks() -> Bool {
        guard let note = currentNote else { return false }
        let base = note.deletingPathExtension()
        var kept = true
        for (url, suffix) in [(meAudio, "me"), (themAudio, "them")] {
            guard let url, FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.moveItem(at: url, to: Recorder.audioURL(base, suffix))
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
        let enabled = recorder.enabledLanguages
        let snapshot = lines
        guard snapshot.contains(where: { LanguageReview.needsReview($0, enabled: enabled) }) else { return }

        stage = .finishing("Reviewing languages…")
        let fixes = await LanguageReview.fixes(for: snapshot, audio: audio, enabled: enabled, main: recorder.mainLanguage) {
            [weak self] message in self?.stage = .finishing(message)
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

        stage = .finishing("Identifying speakers (the first time downloads ~20 MB)…")
        do {
            let result = try await recorder.separation.separate(audio)
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

    // MARK: - Deleting

    /// Delete Meeting (or Discard while recording): its note, audio and
    /// subtitles go to the Trash — never deleted outright — and nothing of it
    /// stays in Wingman: its entry, its kept voices, voices learned from it.
    /// Returns how many files couldn't be moved to the Trash.
    @discardableResult
    func trashFiles() -> Int {
        let fm = FileManager.default
        var notTrashed = 0
        if let note = currentNote {
            let folder = note.deletingLastPathComponent()
            let base = note.deletingPathExtension().lastPathComponent
            for suffix in Recorder.companionSuffixes {
                let url = folder.appendingPathComponent(base + suffix)
                guard fm.fileExists(atPath: url.path) else { continue }
                do {
                    try fm.trashItem(at: url, resultingItemURL: nil)
                } catch {
                    notTrashed += 1
                    Log.write("couldn't move a deleted meeting's file to the Trash: \(Log.describe(error))")
                }
            }
        }
        // Temporary tracks (audio not kept) are Wingman's own scratch files.
        if !tracksKept {
            for url in [meAudio, themAudio].compactMap({ $0 }) where fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
            }
        }
        RecordingRecovery.remove(id: recordingID, in: Recorder.scratchFolder)
        recorder.voices.removeVoices(fromMeetings: [id])
        recorder.index.remove(meeting: id)
        learned = [:]
        return notTrashed
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

    // MARK: - Name and files

    /// "2026-10-07_01_Weekly sync": the day and the meeting's number first, so
    /// files sort, then the meeting name.
    private func base(in folder: URL) -> URL {
        folder.appendingPathComponent(NoteNaming.base(prefix: notePrefix, name: Recorder.fileSafe(meetingName)))
    }

    /// Renames the meeting's files to match `meetingName`. Safe while
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
        if fm.fileExists(atPath: newNote.path), !Recorder.isSameFile(note, newNote) {
            lastError = "A meeting named \"\(newBase.lastPathComponent)\" already exists in this folder."
            return
        }
        var failed: String?
        var noteMoved = false
        for suffix in Recorder.companionSuffixes {
            let from = folder.appendingPathComponent(oldBase.lastPathComponent + suffix)
            let to = folder.appendingPathComponent(newBase.lastPathComponent + suffix)
            guard fm.fileExists(atPath: from.path) else { continue }
            do {
                if Recorder.isSameFile(from, to) {
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
        recorder.tracksMoved(for: self)
        saveRecoveryRecord()
        writeNote()
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
        let voices = recorder.voices
        guard recorder.recognizeVoices, !voiceprints.isEmpty, !voices.people.isEmpty else { return }
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

    /// Attaches a calendar event to this meeting (or detaches it with nil): its
    /// invitees become rename suggestions and recognition candidates, and its
    /// details go in the note. The name follows the event unless the user typed their own.
    func attach(_ new: MeetingInfo?) {
        let oldTitle = meeting?.title
        meeting = new
        let typed = meetingName.trimmingCharacters(in: .whitespaces)
        if typed.isEmpty || nameFromCalendar || typed == oldTitle {
            meetingName = new?.title ?? ""
            nameFromCalendar = new != nil
        }
        Log.write("calendar event \(new == nil ? "detached" : "picked") by user")
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

    /// Names to offer when renaming a speaker: invited people not already used.
    var suggestedNames: [String] {
        guard let meeting else { return [] }
        let used = Set(speakerNames.values)
        var names = meeting.attendees
        if let organizer = meeting.organizer, !names.contains(organizer) { names.insert(organizer, at: 0) }
        return names.filter { !used.contains($0) }
    }

    /// The voice-based guess for a label, if one is waiting for confirmation.
    func guess(for label: String) -> String? {
        speakerNames[label] == nil ? voiceGuesses[label] : nil
    }

    func isRecognized(_ label: String) -> Bool { recognized.contains(label) }

    func displayName(_ line: TranscriptLine) -> String {
        if let name = speakerNames[line.label] { return name }
        if let guess = voiceGuesses[line.label] { return "\(guess)?" }
        let mine = recorder.myName.trimmingCharacters(in: .whitespaces)
        if line.speaker == .me, !mine.isEmpty { return mine }
        return line.label
    }

    /// Names for exports: per-meeting renames, plus the default name for "Me".
    private var exportNames: [String: String] {
        var names = speakerNames
        for (label, guess) in voiceGuesses where names[label] == nil { names[label] = "\(guess)?" }
        let mine = recorder.myName.trimmingCharacters(in: .whitespaces)
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
        if let contribution = learned.removeValue(forKey: label) { recorder.voices.undo(contribution: contribution) }
        if differentVoice?.label == label { differentVoice = nil }
        // Naming a remote voice teaches Wingman to recognize it next time.
        if recorder.recognizeVoices, let name = new { learnVoice(of: label, as: name) }
        writeNote()
    }

    /// Accepts a "Name?" guess, which also refines that person's voiceprint.
    func confirmGuess(for label: String) {
        guard let name = voiceGuesses[label] else { return }
        rename(speaker: label, to: name)
    }

    /// Learns a label's voice as `name` (see `VoiceLibrary.learn`), unless the
    /// user deleted this meeting's voices.
    private func learnVoice(of label: String, as name: String, asNewPerson: Bool = false) {
        guard let print = voiceprints[label], recorder.index.meeting(id: id)?.voiceState != .deleted else { return }
        let speaker = speakerIDs[label] ?? UUID()
        speakerIDs[label] = speaker
        switch recorder.voices.learn(name, voiceprint: print, meeting: id, speaker: speaker, asNewPerson: asNewPerson) {
        case .learned(_, let contribution), .alreadyLearned(_, let contribution):
            learned[label] = contribution
        case .soundsDifferent:
            differentVoice = DifferentVoice(label: label, name: name)
        case .differentModel:
            notice = "\(name)'s voice wasn't learned: Wingman knows \(name) from an older version of its voice model."
        case .notSaved:
            break  // `voices.problem` says why, in Settings → People.
        }
    }

    /// "Learn as a different <name>": the voice is a second person with that name.
    func learnAsDifferentPerson() {
        guard let different = differentVoice, recorder.recognizeVoices else { return }
        differentVoice = nil
        learnVoice(of: different.label, as: different.name, asNewPerson: true)
        recordMeeting()
    }

    /// This meeting's voices were deleted (Delete Voices): nothing learned stays.
    func forgetLearned() {
        learned = [:]
        differentVoice = nil
    }

    /// Updates this meeting's entry in the index once the recording is over: its
    /// speakers (names and lines) and, while Recognize people is on, the voices of
    /// speakers not learned yet, so they can still be named — and learned — later.
    private func recordMeeting() {
        guard let note = currentNote, stage != .recording else { return }
        let index = recorder.index
        var entry = index.meeting(id: id) ?? MeetingIndex.Meeting(id: id, key: AudioCleanup.key(for: note))
        entry.key = AudioCleanup.key(for: note)
        entry.noteHash = noteHash
        entry.started = startedAt
        let mine = recorder.myName.trimmingCharacters(in: .whitespaces)
        entry.meName = mine.isEmpty ? Speaker.me.rawValue : mine
        entry.eventID = meeting?.id
        // Line references count every line, yours too, the way the note lists them.
        var seen: [Int: Int] = [:]
        var refs: [String: [MeetingIndex.LineRef]] = [:]
        for line in lines where line.isFinal {
            let start = Int(line.start)
            let ordinal = seen[start, default: 0]
            seen[start] = ordinal + 1
            if line.speaker != .me { refs[line.label, default: []].append(MeetingIndex.LineRef(start: start, ordinal: ordinal)) }
        }
        var speakers: [MeetingIndex.Speaker] = []
        for label in speakerLabels {
            guard let lineRefs = refs[label] else { continue }
            let speaker = speakerIDs[label] ?? UUID()
            speakerIDs[label] = speaker
            speakers.append(MeetingIndex.Speaker(id: speaker, label: label,
                                                 name: speakerNames[label] ?? voiceGuesses[label].map { "\($0)?" },
                                                 lines: lineRefs, learned: learned[label]))
        }
        entry.speakers = speakers
        guard index.save(entry), recorder.recognizeVoices else { return }
        var keep: [UUID: MeetingIndex.Voice] = [:]
        for (label, print) in voiceprints where learned[label] == nil {
            if let speaker = speakerIDs[label] { keep[speaker] = MeetingIndex.Voice(embedding: print, model: VoiceLibrary.currentModel) }
        }
        index.keepVoices(keep, for: id)
    }

    // MARK: - The note

    /// Writes the note. A failure is shown in the window (with Save Note As…)
    /// and clears `noteSaved`, so no notification or report claims it was saved.
    @discardableResult
    func writeNote() -> Bool {
        guard let currentNote, let text = noteText() else { return false }
        // After the meeting the note is yours: an edit made in another app, or
        // moving the note to the Trash, wins over a later change in Wingman.
        if stage == .done, let written = noteWrittenAt {
            guard let modified = Recorder.modificationDate(currentNote) else {
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
            noteWrittenAt = Recorder.modificationDate(currentNote)
            noteHash = MeetingIndex.hash(Data(text.utf8))
            noteSaved = true
            noteSaveError = nil
            recordMeeting()
            return true
        } catch {
            Log.write("couldn't write the note: \(Log.describe(error))")
            noteSaved = false
            noteSaveError = "Wingman couldn't save the note (\(error.localizedDescription)). The transcript is still here: use Save Note As… to keep a copy."
            return false
        }
    }

    /// The note's Markdown.
    func noteText() -> String? {
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
            text += "\n[\(Recorder.timestamp(line.start))] **\(displayName(line)):** \(line.text)\(flag)\n"
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

    // MARK: - Transcribing a file

    /// Fills the transcript from a recording or video file (see `Recorder.transcribeFile`).
    func setFileLines(_ new: [TranscriptLine]) {
        lines = new
        writeNote()
    }

    func setStage(_ new: Stage) { stage = new }


    /// Stress mode and tests: replaces the lines as they are.
    func replaceLines(_ new: [TranscriptLine]) { lines = new }
}
