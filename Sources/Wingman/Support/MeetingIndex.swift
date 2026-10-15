import CryptoKit
import Foundation
import Observation

/// What Wingman remembers about each meeting's speakers, outside the notes:
///
/// - `meetings.json`: names only. Each meeting's id, file key, real start time,
///   the name you were recorded under, its speakers (a stable id per original
///   voice, its label and current name, and which lines are theirs), whether its
///   voices may be kept, and unfinished renames. Kept while the note exists.
/// - `meeting-voices.json`: the voices (speaker embeddings) of speakers nobody
///   has named yet, so they can be named — and learned — later. Each meeting's
///   are deleted 180 days after the meeting, or sooner when the user says so.
///
/// Both are in Wingman's folder in Application Support (never the notes folder,
/// which is often synced), written atomically, and changed only after the write
/// worked. A file from a newer Wingman is left alone: nothing is written to it.
@MainActor
@Observable
final class MeetingIndex {
    nonisolated static let keepVoicesDays = 180

    struct LineRef: Codable, Hashable {
        /// The line's timestamp, in seconds.
        let start: Int
        /// Which of the lines with that timestamp (0 for the first).
        let ordinal: Int
    }

    struct Speaker: Codable, Equatable, Identifiable {
        let id: UUID
        /// The label Wingman gave the voice: "Them 1", or "Them".
        let label: String
        /// The name shown in the note now, when it isn't the label.
        var name: String?
        var lines: [LineRef]
        /// Waiting for the voice to be found in old audio before it can be learned.
        var pendingLearn = false
        /// Learned into People (the contribution's id), for undo.
        var learned: UUID?
    }

    enum VoiceState: String, Codable {
        /// Never looked for (meetings before 0.9, or nothing kept yet).
        case none
        /// Its unnamed speakers' voices are kept.
        case stored
        /// The user deleted them: never kept or looked for again.
        case deleted
        /// 180 days passed.
        case expired
        /// Recognize people was off.
        case notAllowed
        /// Searched for in an older meeting's audio; none clear enough to offer.
        case searched
    }

    struct Meeting: Codable, Equatable, Identifiable {
        let id: UUID
        /// "<day folder>/<file name without extension>"; changes when the meeting is renamed.
        var key: String
        /// When recording started, if Wingman knows (not for notes from before 0.9).
        var started: Date?
        /// The name your own lines carry in this note.
        var meName: String?
        var eventID: String?
        var speakers: [Speaker] = []
        var voiceState: VoiceState = .none
        /// Bumped whenever voices are deleted, so a voice search that started
        /// before can't save what it found.
        var generation = 0
        /// First scan that didn't find the note; the entry goes 30 days later.
        var missingSince: Date?
        /// SHA-256 of the note as Wingman last wrote it. A note that hashes
        /// differently was changed elsewhere (another app, or another Mac
        /// through a synced folder), so this entry's line references may no
        /// longer match it. Nil for entries from before it was recorded.
        var noteHash: String?
    }

    /// The hash `Meeting.noteHash` records.
    nonisolated static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A rename in progress, kept on disk until every step is done, so a crash
    /// or a failed step can be finished on the next try.
    struct RenameJob: Codable, Equatable, Identifiable {
        enum Step: String, Codable, CaseIterable { case note, subtitles, index, learn }
        let id: UUID
        let meeting: UUID
        let from: String
        let to: String
        /// The speakers that had the old name (not others already called `to`).
        var speakers: [UUID] = []
        var done: Set<Step> = []
        var failed: Set<Step> = []
    }

    struct Voice: Codable, Equatable {
        let embedding: [Float]
        let model: String
        /// Found afterwards in an older meeting's audio: only learned when the
        /// user has played a sample and chosen Learn.
        var recovered: Bool? = nil
        /// That sample: start and end in the call audio, in seconds.
        var sample: [Double]? = nil
    }

    private struct IndexFile: Codable {
        var version = 1
        var meetings: [Meeting] = []
        /// Delete All / Forget Everyone: no voices are kept or looked for for
        /// meetings that started before this.
        var voicesDeletedBefore: Date?
        /// Recognize people was turned off then; the same rule applies.
        var recognitionOffSince: Date?
        var jobs: [RenameJob] = []
    }

    private struct VoicesFile: Codable {
        var version = 1
        /// By meeting id.
        var meetings: [String: StoredVoices] = [:]
    }

    struct StoredVoices: Codable, Equatable {
        let expires: Date
        /// By speaker id.
        var speakers: [String: Voice]
    }

    private(set) var meetings: [Meeting] = []
    private(set) var jobs: [RenameJob] = []
    private(set) var voicesDeletedBefore: Date?
    private(set) var recognitionOffSince: Date?
    private var stored: [String: StoredVoices] = [:]
    /// What couldn't be saved; nil when the files match what's shown.
    private(set) var problem: String?
    /// A file is from a newer Wingman: read what we can, write nothing.
    private(set) var readOnly = false

    nonisolated static let defaultFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Wingman", isDirectory: true)
    private let indexFile: URL
    private let voicesFile: URL

    init(folder: URL = MeetingIndex.defaultFolder) {
        indexFile = folder.appendingPathComponent("meetings.json")
        voicesFile = folder.appendingPathComponent("meeting-voices.json")
        if let data = try? Data(contentsOf: indexFile) {
            if let file = try? JSONDecoder().decode(IndexFile.self, from: data), file.version <= 1 {
                meetings = file.meetings
                jobs = file.jobs
                voicesDeletedBefore = file.voicesDeletedBefore
                recognitionOffSince = file.recognitionOffSince
            } else {
                readOnly = true
            }
        }
        if let data = try? Data(contentsOf: voicesFile) {
            if let file = try? JSONDecoder().decode(VoicesFile.self, from: data), file.version <= 1 {
                stored = file.meetings
            } else {
                readOnly = true
            }
        }
        if readOnly { Log.write("meeting index is from a newer Wingman; leaving it as it is") }
    }

    // MARK: - Meetings

    func meeting(id: UUID) -> Meeting? { meetings.first { $0.id == id } }
    /// The newest entry for a note: a note removed outside Wingman (Finder)
    /// leaves its entry behind, and a later meeting can reuse its number.
    func meeting(key: String) -> Meeting? {
        meetings.filter { $0.key == key }.max { ($0.started ?? .distantPast) < ($1.started ?? .distantPast) }
    }

    /// Adds or replaces a meeting's entry. An older entry for the same note
    /// (whose note was removed outside Wingman, its number now reused) goes,
    /// with the voices kept for it. False if it couldn't be saved.
    @discardableResult
    func save(_ meeting: Meeting) -> Bool {
        let stale = Set(meetings.filter { $0.key == meeting.key && $0.id != meeting.id }.map(\.id))
        var list = meetings.filter { !stale.contains($0.id) }
        if let i = list.firstIndex(where: { $0.id == meeting.id }) { list[i] = meeting } else { list.append(meeting) }
        guard !stale.isEmpty else { return commit(meetings: list) }
        Log.write("replaced \(stale.count == 1 ? "an entry" : "\(stale.count) entries") left by a note removed outside Wingman")
        var voices = stored
        for id in stale { voices[id.uuidString] = nil }
        return commit(meetings: list, voices: voices, jobs: jobs.filter { !stale.contains($0.meeting) })
    }

    /// Forgets a meeting entirely (a discarded recording): its entry and voices.
    @discardableResult
    func remove(meeting id: UUID) -> Bool {
        var voices = stored
        voices[id.uuidString] = nil
        return commit(meetings: meetings.filter { $0.id != id }, voices: voices, jobs: jobs.filter { $0.meeting != id })
    }

    /// The meeting's entry, or a new one for a note Wingman hasn't seen before:
    /// one speaker per name in it (an old note's names are what Wingman has).
    func entry(forKey key: String, note: MeetingNote) -> Meeting {
        if let existing = meeting(key: key) { return existing }
        var meeting = Meeting(id: UUID(), key: key)
        meeting.speakers = note.speakers.compactMap { name in
            guard MeetingNote.kind(of: name) != .me else { return nil }
            return Speaker(id: UUID(), label: name, name: nil, lines: Self.lineRefs(in: note, speaker: name))
        }
        return meeting
    }

    /// The note's lines spoken by `speaker`, as references that survive renames.
    static func lineRefs(in note: MeetingNote, speaker: String) -> [LineRef] {
        var seen: [Int: Int] = [:]
        var refs: [LineRef] = []
        for line in note.lines {
            let ordinal = seen[line.start, default: 0]
            seen[line.start] = ordinal + 1
            if line.speaker == speaker { refs.append(LineRef(start: line.start, ordinal: ordinal)) }
        }
        return refs
    }

    // MARK: - Voices

    /// When a meeting's voices go: 180 days after it started, or after the end of
    /// its day when the start time isn't known (never earlier than it should).
    nonisolated static func voicesExpire(_ meeting: Meeting) -> Date {
        let start = meeting.started ?? endOfDay(meeting.key) ?? Date()
        return Calendar.current.date(byAdding: .day, value: keepVoicesDays, to: start)!
    }

    /// 23:59:59 local time on the key's day folder, if it is one.
    nonisolated static func endOfDay(_ key: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let day = key.split(separator: "/").first, let start = formatter.date(from: String(day)) else { return nil }
        return Calendar.current.date(byAdding: DateComponents(day: 1, second: -1), to: start)
    }

    /// Whether Wingman may keep (or look for) this meeting's voices now.
    func mayKeepVoices(_ meeting: Meeting, now: Date = Date()) -> Bool {
        guard meeting.voiceState == .none || meeting.voiceState == .stored, !readOnly else { return false }
        let start = meeting.started ?? Self.endOfDay(meeting.key) ?? now
        if let cutoff = voicesDeletedBefore, start < cutoff { return false }
        if let cutoff = recognitionOffSince, start < cutoff { return false }
        return Self.voicesExpire(meeting) > now
    }

    /// The meeting's kept voices, by speaker id; expired ones are deleted first.
    func voices(for meeting: Meeting, now: Date = Date()) -> [UUID: Voice] {
        purgeExpired(now: now)
        guard let set = stored[meeting.id.uuidString] else { return [:] }
        return Dictionary(uniqueKeysWithValues: set.speakers.compactMap { key, voice in UUID(uuidString: key).map { ($0, voice) } })
    }

    /// Keeps voices for speakers nobody has named yet (replacing the meeting's
    /// earlier ones). Only call while Recognize people is on.
    @discardableResult
    func keepVoices(_ voices: [UUID: Voice], for id: UUID, now: Date = Date()) -> Bool {
        guard var meeting = meeting(id: id), mayKeepVoices(meeting, now: now) else { return false }
        var all = stored
        if voices.isEmpty {
            all[id.uuidString] = nil
        } else {
            all[id.uuidString] = StoredVoices(expires: Self.voicesExpire(meeting),
                                              speakers: Dictionary(uniqueKeysWithValues: voices.map { ($0.key.uuidString, $0.value) }))
        }
        meeting.voiceState = .stored
        var list = meetings
        list[list.firstIndex { $0.id == id }!] = meeting
        return commit(meetings: list, voices: all)
    }

    /// Keeps one more speaker's voice (one taken back from People after a
    /// correction, so it can still be named).
    @discardableResult
    func keepVoice(_ voice: Voice, of speaker: UUID, in id: UUID, now: Date = Date()) -> Bool {
        var all = self.voices(for: meeting(id: id) ?? Meeting(id: id, key: ""), now: now)
        all[speaker] = voice
        return keepVoices(all, for: id, now: now)
    }

    /// Forgets a speaker's kept voice once it's learned (People has it now).
    @discardableResult
    func dropVoice(of speaker: UUID, in id: UUID) -> Bool {
        guard stored[id.uuidString]?.speakers[speaker.uuidString] != nil else { return true }
        var all = stored
        all[id.uuidString]?.speakers[speaker.uuidString] = nil
        return commit(voices: all)
    }

    /// Delete Voices on one meeting: its kept voices go, and it's never looked
    /// at again. (Voices learned from it are People's: see `VoiceLibrary.removeVoices`.)
    @discardableResult
    func deleteVoices(of id: UUID) -> Bool {
        guard var meeting = meeting(id: id) else { return false }
        var all = stored
        all[id.uuidString] = nil
        meeting.voiceState = .deleted
        meeting.generation += 1
        // What was learned from it went too (Recorder.deleteVoices).
        for i in meeting.speakers.indices { meeting.speakers[i].learned = nil }
        var list = meetings
        list[list.firstIndex { $0.id == id }!] = meeting
        return commit(meetings: list, voices: all)
    }

    /// Delete All / Forget Everyone (`reason: .deleted`) or turning Recognize
    /// people off (`.notAllowed`): every kept voice goes, and meetings from
    /// before now are never looked at again.
    @discardableResult
    func deleteAllVoices(because reason: VoiceState, now: Date = Date()) -> Bool {
        let list = meetings.map { meeting -> Meeting in
            var meeting = meeting
            if meeting.voiceState == .stored || meeting.voiceState == .none { meeting.voiceState = reason }
            meeting.generation += 1
            // Delete All and Forget Everyone remove what was learned; turning
            // recognition off keeps People.
            if reason == .deleted { for i in meeting.speakers.indices { meeting.speakers[i].learned = nil } }
            return meeting
        }
        return commit(meetings: list, voices: [:],
                      deletedBefore: reason == .deleted ? now : voicesDeletedBefore,
                      offSince: reason == .notAllowed ? now : recognitionOffSince)
    }

    /// Deletes voices past their 180 days. Runs at launch, hourly, and before
    /// voices are read.
    func purgeExpired(now: Date = Date()) {
        let expired = stored.filter { $0.value.expires <= now }.map(\.key)
        let late = meetings.filter { $0.voiceState == .stored || $0.voiceState == .none }
            .filter { Self.voicesExpire($0) <= now }
        guard !expired.isEmpty || late.contains(where: { $0.voiceState == .stored }) else { return }
        var all = stored
        for key in expired { all[key] = nil }
        let lateIDs = Set(late.map(\.id))
        let list = meetings.map { meeting -> Meeting in
            var meeting = meeting
            if lateIDs.contains(meeting.id), meeting.voiceState == .stored { meeting.voiceState = .expired }
            return meeting
        }
        if commit(meetings: list, voices: all) { Log.write("meeting voices: \(expired.count) expired") }
    }

    /// Meetings with voices kept, for Settings → People.
    var meetingsWithVoices: [Meeting] {
        meetings.filter { stored[$0.id.uuidString]?.speakers.isEmpty == false }
    }

    // MARK: - Rename jobs

    @discardableResult
    func save(_ job: RenameJob) -> Bool {
        var list = jobs
        if let i = list.firstIndex(where: { $0.id == job.id }) { list[i] = job } else { list.append(job) }
        return commit(jobs: list)
    }

    @discardableResult
    func finish(_ job: RenameJob) -> Bool {
        commit(jobs: jobs.filter { $0.id != job.id })
    }

    // MARK: - Saving

    /// Writes the files, and only then shows the change.
    private func commit(meetings newMeetings: [Meeting]? = nil, voices newVoices: [String: StoredVoices]? = nil,
                        jobs newJobs: [RenameJob]? = nil, deletedBefore: Date?? = nil, offSince: Date?? = nil) -> Bool {
        guard !readOnly else {
            problem = "Wingman's list of meetings was written by a newer version of Wingman, so this version can't change it."
            return false
        }
        var index = IndexFile(meetings: newMeetings ?? meetings, voicesDeletedBefore: deletedBefore ?? voicesDeletedBefore,
                              recognitionOffSince: offSince ?? recognitionOffSince, jobs: newJobs ?? jobs)
        index.version = 1
        do {
            try FileManager.default.createDirectory(at: indexFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Voices first: if the index can't be written after, the voices
            // aren't listed as kept, and the next purge or keep tidies up.
            if let newVoices {
                try JSONEncoder().encode(VoicesFile(meetings: newVoices)).write(to: voicesFile, options: [.atomic, .completeFileProtection])
                stored = newVoices
            }
            try JSONEncoder().encode(index).write(to: indexFile, options: [.atomic, .completeFileProtection])
        } catch {
            Log.write("couldn't save the meeting index: \(Log.describe(error))")
            problem = "Wingman couldn't save what it knows about past meetings (\(error.localizedDescription))."
            return false
        }
        meetings = index.meetings
        jobs = index.jobs
        voicesDeletedBefore = index.voicesDeletedBefore
        recognitionOffSince = index.recognitionOffSince
        problem = nil
        return true
    }
}
