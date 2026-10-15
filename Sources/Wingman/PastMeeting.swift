import Foundation
import Observation

/// A meeting that's already saved, opened from its note so its speakers can be
/// named later: in the Meetings window, while another call records. It never
/// touches the Recorder.
///
/// A rename is a job kept on disk (`MeetingIndex.RenameJob`) and done in steps,
/// the note first, since it's what the user reads:
/// 1. a backup copy of the note and subtitles (if that fails, nothing changes);
/// 2. the note, changed in place by `NoteFile` + `NoteRewriter`;
/// 3. its `.vtt` / `.srt`, only where they line up with the note;
/// 4. the meeting's entry in the index;
/// 5. learning the voice, if Wingman kept it.
/// Each outcome is reported on its own, a failed step can be retried, and a job
/// interrupted by a crash is finished at the next launch. Repeating a finished
/// step changes nothing (the old name is gone; the voice is learned once).
@MainActor
@Observable
final class PastMeeting: Identifiable {
    struct Outcome: Equatable {
        let text: String
        let isError: Bool
        /// A job with a failed step, to offer Retry.
        let retry: MeetingIndex.RenameJob?
    }

    /// A name given to a voice that doesn't sound like the person known by it.
    struct DifferentVoice: Equatable {
        let speaker: UUID
        let name: String
    }

    nonisolated let id: URL
    private(set) var url: URL
    private(set) var note: MeetingNote
    private(set) var entry: MeetingIndex.Meeting
    private(set) var outcome: Outcome?
    private(set) var differentVoice: DifferentVoice?
    private(set) var busy = false
    private let index: MeetingIndex
    private let voices: VoiceLibrary
    private let recognize: () -> Bool
    /// Test hook: throws to make a step fail.
    var inject: ((MeetingIndex.RenameJob.Step) throws -> Void)?
    /// Where backups go (tests use a temporary folder).
    var backups = NoteFile.backupsFolder

    private init(url: URL, note: MeetingNote, entry: MeetingIndex.Meeting, index: MeetingIndex,
                 voices: VoiceLibrary, recognize: @escaping () -> Bool) {
        id = url
        self.url = url
        self.note = note
        self.entry = entry
        self.index = index
        self.voices = voices
        self.recognize = recognize
    }

    /// Reads the note and finds (or starts) its entry in the index.
    static func open(_ url: URL, index: MeetingIndex, voices: VoiceLibrary,
                     recognize: @escaping () -> Bool) async throws -> PastMeeting {
        let data = try await Task.detached { try NoteFile.read(url) }.value
        let note = MeetingNote.parse(data)
        let key = AudioCleanup.key(for: url)
        var entry = index.entry(forKey: key, note: note)
        // First sight of a note from before hashes were kept: this is the
        // version the entry's line references were made from.
        if entry.noteHash == nil { entry.noteHash = MeetingIndex.hash(data) }
        if index.meeting(id: entry.id) == nil, note.readOnly == nil { index.save(entry) }
        return PastMeeting(url: url, note: note, entry: entry, index: index, voices: voices, recognize: recognize)
    }

    /// The note no longer is what Wingman last wrote or first read: it was
    /// edited elsewhere (another app, or another Mac), so speaker membership
    /// (line references) can't be trusted without checking each line.
    func changedElsewhere(_ data: Data) -> Bool {
        guard let recorded = entry.noteHash else { return false }
        return recorded != MeetingIndex.hash(data)
    }

    /// Reads the note again (after a change, or one made elsewhere).
    func reload() async {
        guard let data = try? await Task.detached(operation: { [url] in try NoteFile.read(url) }).value else { return }
        note = MeetingNote.parse(data)
        entry = index.meeting(id: entry.id) ?? entry
    }

    var title: String { note.title ?? NoteNaming.displayName(base: url.deletingPathExtension().lastPathComponent) }

    /// Speakers as the note shows them, in order, without you.
    var speakers: [String] {
        note.speakers.filter { MeetingNote.kind(of: $0, meName: entry.meName) != .me }
    }

    func kind(of speaker: String) -> MeetingNote.SpeakerKind { MeetingNote.kind(of: speaker, meName: entry.meName) }

    var tally: SpeakerTally { SpeakerTally(speakers: note.speakers, meName: entry.meName) }

    /// Invited people (organizer first) not already a speaker's name.
    var suggestions: [String] {
        var names: [String] = []
        if let organizer = note.header["Organizer"] { names.append(organizer) }
        for name in (note.header["Invited"] ?? "").split(separator: ",") {
            let name = name.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        let used = Set(note.speakers.map { $0.lowercased() })
        return names.filter { !used.contains($0.lowercased()) }
    }

    // MARK: - Renaming

    /// Renames `speaker` (as the note shows it) to `name`. Naming two speakers
    /// the same puts them under one name (the existing spelling) without
    /// pooling their voices.
    func rename(_ speaker: String, to name: String) async {
        guard !busy else { return }
        if let reason = note.readOnly {
            outcome = Outcome(text: "This note can't be changed: \(reason.reason).", isError: true, retry: nil)
            return
        }
        // Back to the label ("Them 2") is allowed here, unlike a new name.
        let label = entry.speakers.first { ($0.name ?? $0.label) == speaker }?.label
        let target: String
        if let label, name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(label) == .orderedSame {
            target = label
        } else if let clean = SpeakerName.clean(name) {
            target = NoteRewriter.spelling(for: clean, in: note, renaming: speaker)
        } else {
            outcome = Outcome(text: "\"\(name)\" can't be used as a name.", isError: true, retry: nil)
            return
        }
        guard target != speaker else { return }
        let speakers = entry.speakers.filter { ($0.name ?? $0.label) == speaker }.map(\.id)
        let job = MeetingIndex.RenameJob(id: UUID(), meeting: entry.id, from: speaker, to: target, speakers: speakers)
        index.save(job)
        await run(job)
    }

    /// Accepts a "Name?" guess.
    func confirm(_ guess: String) async {
        guard guess.hasSuffix("?") else { return }
        await rename(guess, to: String(guess.dropLast()))
    }

    /// Retry for a job with a failed step, or one left by a crash.
    func resume(_ job: MeetingIndex.RenameJob) async {
        guard !busy else { return }
        var job = job
        job.failed = []
        await run(job, resuming: true)
    }

    /// "Learn as a different <name>".
    func learnAsDifferentPerson() {
        guard let different = differentVoice, recognize(),
              let voice = index.voices(for: entry)[different.speaker] else { return }
        differentVoice = nil
        let result = voices.learn(different.name, voiceprint: voice.embedding, meeting: entry.id,
                                  speaker: different.speaker, asNewPerson: true)
        if let contribution = result.contribution { markLearned(different.speaker, contribution) }
        outcome = Outcome(text: result.contribution == nil ? "\(different.name)'s voice couldn't be saved." : "Learned as a different \(different.name).",
                          isError: result.contribution == nil, retry: nil)
    }

    /// The note shows the new name and not the old one.
    private func alreadyRenamed(_ job: MeetingIndex.RenameJob) -> Bool {
        let shown = Set(note.speakers)
        return shown.contains(job.to) && !shown.contains(job.from)
    }

    private func run(_ start: MeetingIndex.RenameJob, resuming: Bool = false) async {
        busy = true
        defer { busy = false }
        var job = start
        var messages: [String] = []
        differentVoice = nil

        // 1–2. Backup, then the note. Without both, nothing else happens.
        if !job.done.contains(.note) {
            if let failure = await renameInNote(job, resuming: resuming, messages: &messages) {
                index.finish(job)
                await reload()
                outcome = Outcome(text: failure, isError: true, retry: nil)
                return
            }
            job.done.insert(.note)
            index.save(job)
        }
        let before = note
        await reload()
        if !job.done.contains(.subtitles) {
            let skipped = await renameInSubtitles(job, before: before)
            if skipped.isEmpty {
                job.done.insert(.subtitles)
            } else {
                job.failed.insert(.subtitles)
                messages.append("The subtitles (\(skipped.joined(separator: ", "))) couldn't be updated.")
            }
        }
        if !job.done.contains(.index) {
            if renameInIndex(job, speakers: job.speakers) {
                job.done.insert(.index)
            } else {
                job.failed.insert(.index)
                messages.append("Wingman couldn't record the new name in its list of meetings.")
            }
        }
        if !job.done.contains(.learn) {
            do {
                try inject?(.learn)
                messages += learn(job.speakers, as: job.to)
                job.done.insert(.learn)
            } catch {
                job.failed.insert(.learn)
                messages.append("The voice wasn't learned.")
            }
        }

        if job.failed.isEmpty { index.finish(job) } else { index.save(job) }
        let text: String = (["Name saved."] + messages).joined(separator: " ")
        outcome = Outcome(text: text, isError: !job.failed.isEmpty, retry: job.failed.isEmpty ? nil : job)
    }

    /// Backs up the note and its subtitles, then renames in the note. Returns
    /// what to say if nothing could be changed.
    private func renameInNote(_ job: MeetingIndex.RenameJob, resuming: Bool, messages: inout [String]) async -> String? {
        let base = url.deletingPathExtension()
        let files: [URL] = [url, base.appendingPathExtension("vtt"), base.appendingPathExtension("srt")]
        let backups = self.backups, meeting = entry.id, url = self.url
        do {
            try inject?(.note)
            let backup = Task.detached { () throws -> Void in try NoteFile.backUp(files, meeting: meeting, in: backups) }
            try await backup.value
        } catch {
            return "Nothing was changed: Wingman couldn't make a backup copy of the note first (\(error.localizedDescription))."
        }
        let from = job.from, to = job.to
        let change = Task.detached { () throws -> NoteFile.Result in
            try NoteFile.rewrite(url) { data in try NoteRewriter.renameSpeaker(in: data, from: from, to: to) }
        }
        do {
            let result = try await change.value
            if !result.attributesLost.isEmpty {
                messages.append("The note's \(result.attributesLost.joined(separator: " and ")) couldn't be kept.")
            }
            return nil
        } catch {
            // Already renamed (the app quit before the job was marked): nothing to do.
            if resuming, case NoteRewriter.Failure.speakerNotFound = error, alreadyRenamed(job) { return nil }
            return "Not saved: \(Self.describe(error))"
        }
    }

    /// Renames in the `.vtt` and `.srt` where they line up with the note
    /// (`before`: the note as it was). Returns the ones that couldn't be.
    private func renameInSubtitles(_ job: MeetingIndex.RenameJob, before: MeetingNote) async -> [String] {
        let from = job.from, to = job.to
        // What the cues should say: the note as it was or, after a crash, the
        // note with the old name put back.
        var old: MeetingNote = before
        if !before.speakers.contains(from), let restored = try? NoteRewriter.renameSpeaker(in: note.data, from: to, to: from) {
            old = MeetingNote.parse(restored)
        }
        let cues = old
        var skipped: [String] = []
        for format in SubtitleExport.Format.allCases {
            let file = url.deletingPathExtension().appendingPathExtension(format.rawValue)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            guard passes(.subtitles) else {
                skipped.append(".\(format.rawValue)")
                continue
            }
            let change = Task.detached { () throws -> NoteFile.Result in
                try NoteFile.rewrite(file) { data in
                    try SubtitleRewriter.renameSpeaker(in: data, format: format, note: cues, from: from, to: to)
                }
            }
            if (try? await change.value) == nil { skipped.append(".\(format.rawValue)") }
        }
        return skipped
    }

    /// False when a test makes this step fail.
    private func passes(_ step: MeetingIndex.RenameJob.Step) -> Bool {
        do {
            try inject?(step)
            return true
        } catch {
            return false
        }
    }

    /// Records the new name on the speakers that had the old one.
    private func renameInIndex(_ job: MeetingIndex.RenameJob, speakers: [UUID]) -> Bool {
        var updated = entry
        for i in updated.speakers.indices where speakers.contains(updated.speakers[i].id) {
            updated.speakers[i].name = job.to == updated.speakers[i].label ? nil : job.to
        }
        // The note as this rename left it.
        if let data = try? Data(contentsOf: url) { updated.noteHash = MeetingIndex.hash(data) }
        guard passes(.index), index.save(updated) else { return false }
        entry = updated
        return true
    }

    /// Learns each speaker's kept voice as `name`, undoing what it taught under
    /// an earlier name. Returns what to tell the user.
    private func learn(_ speakers: [UUID], as name: String) -> [String] {
        var messages: [String] = []
        let learnable = MeetingNote.kind(of: name, meName: entry.meName) == .named
        for id in speakers {
            guard let speaker = entry.speakers.first(where: { $0.id == id }) else { continue }
            // A correction: take back what this voice taught under the old name.
            var embedding = index.voices(for: entry)[id]?.embedding
            if let learned = speaker.learned {
                if let contribution = voices.contribution(learned) {
                    embedding = contribution.embedding
                    voices.undo(contribution: learned)
                }
                markLearned(id, nil)
                if let embedding, recognize() {
                    index.keepVoice(MeetingIndex.Voice(embedding: embedding, model: VoiceLibrary.currentModel), of: id, in: entry.id)
                }
            }
            guard learnable, recognize(), entry.voiceState != .deleted else { continue }
            // Found afterwards in old audio: offered (play a sample, then Learn), never learned on its own.
            if index.voices(for: entry)[id]?.recovered == true {
                setPending(id, true)
                continue
            }
            guard let embedding else {
                // An older meeting: the voice may still be found in its audio.
                if entry.voiceState == .none, var updated = index.meeting(id: entry.id),
                   let i = updated.speakers.firstIndex(where: { $0.id == id }) {
                    updated.speakers[i].pendingLearn = true
                    if index.save(updated) { entry = updated }
                }
                continue
            }
            // Two voices under one name: only if they sound alike.
            if let other = otherVoice(named: name, besides: id), VoiceLibrary.similarity(other, embedding) < VoiceLibrary.askAt {
                messages.append("\(speaker.label)'s voice wasn't learned: it doesn't sound like the other \(name).")
                continue
            }
            messages += learnNow(id, name: name, embedding: embedding)
        }
        return messages
    }

    /// The voice of another speaker in this meeting already called `name`.
    private func otherVoice(named name: String, besides id: UUID) -> [Float]? {
        let kept = index.voices(for: entry)
        for other in entry.speakers where other.id != id && (other.name ?? other.label) == name {
            if let learned = other.learned, let contribution = voices.contribution(learned) { return contribution.embedding }
            if let voice = kept[other.id] { return voice.embedding }
        }
        return nil
    }

    private func setPending(_ speaker: UUID, _ pending: Bool) {
        guard var updated = index.meeting(id: entry.id), let i = updated.speakers.firstIndex(where: { $0.id == speaker }),
              updated.speakers[i].pendingLearn != pending else { return }
        updated.speakers[i].pendingLearn = pending
        if index.save(updated) { entry = updated }
    }

    // MARK: - Voices found in old audio

    struct Offer: Identifiable, Equatable {
        var id: UUID { speaker }
        let speaker: UUID
        let name: String
        let sample: VoiceRecovery.Span?
    }

    /// Speakers named here whose voice was found in the call audio: Learn needs
    /// the user's say-so (after playing a sample).
    private(set) var dismissedOffers: Set<UUID> = []

    var offers: [Offer] {
        guard recognize(), entry.voiceState != .deleted else { return [] }
        let kept = index.voices(for: entry)
        return entry.speakers.compactMap { speaker in
            guard speaker.pendingLearn, speaker.learned == nil, !dismissedOffers.contains(speaker.id),
                  let voice = kept[speaker.id], voice.recovered == true, let name = speaker.name,
                  MeetingNote.kind(of: name, meName: entry.meName) == .named else { return nil }
            let sample = voice.sample.flatMap { $0.count == 2 ? VoiceRecovery.Span(start: $0[0], end: $0[1]) : nil }
            return Offer(speaker: speaker.id, name: name, sample: sample)
        }
    }

    func notNow(_ offer: Offer) { dismissedOffers.insert(offer.speaker) }

    /// Learn, after the user listened: the same checks as any other voice.
    func learn(_ offer: Offer) {
        guard recognize(), let voice = index.voices(for: entry)[offer.speaker] else { return }
        let messages = learnNow(offer.speaker, name: offer.name, embedding: voice.embedding)
        outcome = Outcome(text: messages.isEmpty ? "Learned \(offer.name)'s voice." : messages.joined(separator: " "),
                          isError: !messages.isEmpty, retry: nil)
    }

    private func learnNow(_ id: UUID, name: String, embedding: [Float]) -> [String] {
        switch voices.learn(name, voiceprint: embedding, meeting: entry.id, speaker: id) {
        case .learned(_, let contribution), .alreadyLearned(_, let contribution):
            markLearned(id, contribution)
            index.dropVoice(of: id, in: entry.id)
            return []
        case .soundsDifferent:
            differentVoice = DifferentVoice(speaker: id, name: name)
            return ["This voice doesn't sound like the \(name) Wingman knows, so it wasn't learned."]
        case .differentModel:
            return ["\(name)'s voice wasn't learned: Wingman knows \(name) from an older version of its voice model."]
        case .notSaved:
            return ["The voice couldn't be saved."]
        }
    }

    /// "Ana?" for unnamed speakers whose voice, found in old audio, sounds like someone known.
    var voiceGuesses: [String: String] {
        guard recognize() else { return [:] }
        let kept = index.voices(for: entry)
        var prints: [String: [Float]] = [:]
        for speaker in entry.speakers where speaker.name == nil && MeetingNote.kind(of: speaker.label) == .unnamed {
            if let voice = kept[speaker.id] { prints[speaker.label] = voice.embedding }
        }
        let invited = suggestions + [note.header["Organizer"]].compactMap { $0 }
        return voices.match(prints, invitees: invited).mapValues(\.name)
    }

    /// The meeting's call audio, to play a sample from.
    var callAudio: URL? { VoiceRecovery.callAudio(for: url) }

    private func markLearned(_ speaker: UUID, _ contribution: UUID?) {
        guard var updated = index.meeting(id: entry.id), let i = updated.speakers.firstIndex(where: { $0.id == speaker }) else { return }
        updated.speakers[i].learned = contribution
        updated.speakers[i].pendingLearn = false
        if index.save(updated) { entry = updated }
    }

    // MARK: - Deleting

    /// Delete Meeting…: the note, its audio and subtitles go to the Trash —
    /// never deleted outright — and Wingman forgets the meeting: its entry, its
    /// kept voices and the voices learned from it. Returns how many files
    /// couldn't be moved to the Trash.
    func delete() -> Int {
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        var notTrashed = 0
        for suffix in Recorder.companionSuffixes {
            let file = folder.appendingPathComponent(base + suffix)
            guard fm.fileExists(atPath: file.path) else { continue }
            do {
                try fm.trashItem(at: file, resultingItemURL: nil)
            } catch {
                notTrashed += 1
            }
        }
        voices.removeVoices(fromMeetings: [entry.id])
        index.remove(meeting: entry.id)
        Log.write("meeting deleted from Meetings (files to the Trash)")
        return notTrashed
    }

    // MARK: - Voices

    /// "Voices from this meeting are kept until …" and whether Delete Voices applies.
    var voiceStatus: String {
        switch entry.voiceState {
        case .stored:
            let date = MeetingIndex.voicesExpire(entry).formatted(date: .abbreviated, time: .omitted)
            return "This meeting's voices are kept until \(date) (\(MeetingIndex.keepVoicesDays) days after the meeting) so you can name speakers later."
        case .deleted: return "Voices deleted. Names you give here won't be learned."
        case .expired: return "This meeting's voices were deleted after \(MeetingIndex.keepVoicesDays) days. Names you give here change the note only."
        case .notAllowed: return "Recognize people was off, so no voices were kept. Names you give here change the note only."
        case .searched: return "No voice in this meeting's call audio was clear enough to learn. Names you give here change the note only."
        case .none:
            guard recognize() else { return "Names you give here change the note only: Recognize people is off (Settings → People)." }
            return callAudio == nil
                ? "Names you give here change the note only: this meeting's call audio wasn't kept."
                : "Names you give here change the note; Wingman then looks for their voice in the call audio, to learn it if you want."
        }
    }

    static func describe(_ error: Error) -> String {
        if let failure = error as? NoteFile.Failure {
            switch failure {
            case .notDownloaded: return "This note isn't downloaded to this Mac yet. Open it in Finder, then try again."
            case .changedWhileWriting: return "the note changed while Wingman was saving it. It's showing the latest version; try again."
            case .unreadable: return "Wingman couldn't read the note."
            case .verifyFailed: return "the note didn't read back as written. Check it, and its backup in Settings → People."
            case .writeFailed(let reason): return reason
            }
        }
        if let failure = error as? NoteRewriter.Failure {
            switch failure {
            case .speakerNotFound: return "the note changed, and that speaker isn't in it anymore. It's showing the latest version."
            case .readOnly(let reason): return "the note can't be changed: \(reason.reason)."
            case .unexpectedChange: return "Wingman couldn't make that change safely, so the note was left as it was."
            case .invalidName: return "that can't be used as a name."
            }
        }
        return error.localizedDescription
    }
}

/// How many speakers still need a name, and how many guesses need confirming.
struct SpeakerTally: Equatable {
    var toName: [String] = []
    var toConfirm: [String] = []
    var named = 0

    /// From names as a note shows them; you aren't counted.
    init(speakers: [String], meName: String?) {
        for speaker in speakers {
            switch MeetingNote.kind(of: speaker, meName: meName) {
            case .unnamed: toName.append(speaker)
            case .guess: toConfirm.append(speaker)
            case .named: named += 1
            case .me: break
            }
        }
    }

    var isDone: Bool { toName.isEmpty && toConfirm.isEmpty }

    /// "2 speakers to name · 1 to confirm", or nil when there's nothing left.
    var summary: String? {
        var parts: [String] = []
        if !toName.isEmpty { parts.append(toName.count == 1 ? "1 speaker to name" : "\(toName.count) speakers to name") }
        if !toConfirm.isEmpty { parts.append("\(toConfirm.count) to confirm") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
