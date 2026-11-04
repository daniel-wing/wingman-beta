import Foundation

/// Join with Previous for saved meetings (`MeetingJoin`): finding the meeting
/// before one, whether it looks like the same call, and doing the join.
extension Recorder {
    struct JoinCandidate: Equatable {
        let note: URL
        let title: String
        let started: Date
        /// When its recording ended, as far as its audio and lines tell.
        let ended: Date
        /// Same calendar event (or the same name), and this one started less
        /// than `suggestWithin` after it ended: worth suggesting.
        let suggested: Bool
    }

    nonisolated static let suggestWithin: TimeInterval = 600

    /// When a saved meeting started: the index's time, or the note's creation
    /// (Wingman creates it when the recording starts).
    func started(_ note: URL) -> Date? {
        index.meeting(key: AudioCleanup.key(for: note))?.started
            ?? (try? note.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    /// How many seconds a saved meeting runs: its audio, or its last line.
    nonisolated static func length(_ note: URL, _ parsed: MeetingNote) -> Int {
        let base = note.deletingPathExtension()
        let audio = [".m4a", "-them.m4a", "-me.m4a"].lazy.compactMap { MeetingJoin.seconds(of: URL(fileURLWithPath: base.path + $0)) }.first
        return max(Int((audio ?? 0).rounded()), (parsed.lines.last?.start ?? 0) + 1)
    }

    /// The meeting just before this one on the same day, if there is one.
    func meetingBefore(_ note: URL) async -> JoinCandidate? {
        guard let start = started(note) else { return nil }
        let folder = note.deletingLastPathComponent()
        let notes = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey],
                                                                   options: .skipsHiddenFiles)) ?? [])
            .filter { $0.pathExtension == "md" && $0.standardizedFileURL != note.standardizedFileURL }
        guard let previous = notes.compactMap({ url in started(url).map { (url, $0) } }).filter({ $0.1 < start }).max(by: { $0.1 < $1.1 })
        else { return nil }
        let (url, began) = previous
        let pair = await Task.detached(priority: .utility) { () -> (MeetingNote, MeetingNote, Int)? in
            guard let a = try? NoteFile.read(url), let b = try? NoteFile.read(note) else { return nil }
            let earlier = MeetingNote.parse(a)
            return (earlier, MeetingNote.parse(b), Self.length(url, earlier))
        }.value
        guard let (earlier, later, length) = pair, !earlier.lines.isEmpty else { return nil }
        let ended = began.addingTimeInterval(TimeInterval(length))
        let title = earlier.title ?? NoteNaming.displayName(base: url.deletingPathExtension().lastPathComponent)
        let laterTitle = later.title ?? NoteNaming.displayName(base: note.deletingPathExtension().lastPathComponent)
        let events = (index.meeting(key: AudioCleanup.key(for: url))?.eventID, index.meeting(key: AudioCleanup.key(for: note))?.eventID)
        let sameCall = (events.0 != nil && events.0 == events.1) || (title == laterTitle && title != "Meeting" && !title.isEmpty)
        return JoinCandidate(note: url, title: title, started: began, ended: ended,
                             suggested: sameCall && start.timeIntervalSince(ended) < Self.suggestWithin)
    }

    /// Joins the meeting `later` onto `earlier`: its lines after the earlier
    /// ones at the time they were said, its audio after the earlier audio, its
    /// speakers matched where Wingman can tell. Before the earlier note
    /// changes, a backup is made; what's replaced (the earlier audio, the later
    /// meeting's files, both meetings' subtitles) goes to the Trash. Returns
    /// what to tell the user, and whether it worked.
    func join(_ later: URL, onto earlier: URL) async -> (ok: Bool, message: String) {
        let result = await joinFiles(later, onto: earlier)
        joinResult = JoinResult(note: result.ok ? earlier : later, text: result.message, ok: result.ok)
        if result.ok { showNote?(earlier) }
        return result
    }

    private func joinFiles(_ later: URL, onto earlier: URL) async -> (ok: Bool, message: String) {
        let fm = FileManager.default
        let earlierBase = earlier.deletingPathExtension(), laterBase = later.deletingPathExtension()
        // Tracks still being turned into .m4a: not now.
        for base in [earlierBase, laterBase] where ["-me.wav", "-them.wav"].contains(where: { fm.fileExists(atPath: base.path + $0) }) {
            return (false, "Not joined: a meeting's audio isn't finished yet. Try again in a minute.")
        }
        guard letGo(note: earlier), letGo(note: later) else {
            return (false, "Not joined: one of the meetings is still recording or finishing.")
        }
        let a: PastMeeting, b: PastMeeting
        do {
            a = try await PastMeeting.open(earlier, index: index, voices: voices, recognize: { [weak self] in self?.recognizeVoices ?? false })
            b = try await PastMeeting.open(later, index: index, voices: voices, recognize: { [weak self] in self?.recognizeVoices ?? false })
        } catch {
            return (false, "Not joined: \(PastMeeting.describe(error))")
        }
        if let reason = a.note.readOnly ?? b.note.readOnly { return (false, "Not joined: a note can't be changed (\(reason.reason)).") }
        guard let startA = started(earlier), let startB = started(later), startB > startA else {
            return (false, "Not joined: Wingman can't tell when the meetings started.")
        }
        let earlierEnd = Self.length(earlier, a.note)
        let offset = max(Int(startB.timeIntervalSince(startA).rounded()), earlierEnd)
        let minutes = (offset + Self.length(later, b.note)) / 60

        // Speakers: the same unnamed voice in both, by their kept voiceprints.
        let display: (MeetingIndex.Speaker) -> String = { $0.name ?? $0.label }
        let voicesA = index.voices(for: a.entry), voicesB = index.voices(for: b.entry)
        var sameVoice: [String: String] = [:]
        for speaker in b.entry.speakers where MeetingNote.kind(of: display(speaker)) == .unnamed {
            guard let voice = voicesB[speaker.id] else { continue }
            let best = a.entry.speakers.filter { MeetingNote.kind(of: display($0)) == .unnamed }
                .compactMap { other in voicesA[other.id].map { (other, VoiceLibrary.similarity(voice.embedding, $0.embedding)) } }
                .max { $0.1 < $1.1 }
            if let best, best.1 >= VoiceLibrary.confidentAt { sameVoice[display(speaker)] = display(best.0) }
        }
        let names = MeetingJoin.speakerMap(earlier: a.note.speakers, later: b.note.speakers, earlierMe: a.entry.meName,
                                           laterMe: b.entry.meName, sameVoice: sameVoice)
        let text = MeetingJoin.joinedNote(earlier: a.note, later: b.note, offset: offset, earlierEnd: earlierEnd,
                                          names: names, minutes: minutes)
        let joined = MeetingNote.parse(Data(text.utf8))
        guard joined.lines.count == a.note.lines.count + b.note.lines.count, joined.readOnly == nil else {
            return (false, "Not joined: the joined note didn't come out right, so nothing was changed.")
        }

        // The audio, joined next to the notes first; nothing is replaced yet.
        let folder = earlier.deletingLastPathComponent()
        var joinedAudio: [(temp: URL, final: URL)] = []
        for suffix in [".m4a", "-me.m4a", "-them.m4a"] {
            let first = URL(fileURLWithPath: earlierBase.path + suffix), second = URL(fileURLWithPath: laterBase.path + suffix)
            let have = (fm.fileExists(atPath: first.path), fm.fileExists(atPath: second.path))
            guard have.0 || have.1 else { continue }
            let temp = folder.appendingPathComponent(".wingman-join-\(UUID().uuidString).m4a")
            let seconds = TimeInterval(offset)
            do {
                try await Task.detached(priority: .utility) {
                    try MeetingJoin.joinAudio(earlier: have.0 ? first : nil, later: have.1 ? second : nil, offset: seconds, to: temp)
                }.value
                joinedAudio.append((temp, first))
            } catch {
                for file in joinedAudio.map(\.temp) + [temp] { try? fm.removeItem(at: file) }
                return (false, "Not joined: the audio couldn't be joined (\(error.localizedDescription)). Nothing was changed.")
            }
        }

        // The earlier note: a backup, then the joined text.
        let backups = NoteFile.backupsFolder, id = a.entry.id
        do {
            try await Task.detached { try NoteFile.backUp([earlier], meeting: id, in: backups) }.value
            _ = try await Task.detached { try NoteFile.rewrite(earlier) { _ in Data(text.utf8) } }.value
        } catch {
            for file in joinedAudio.map(\.temp) { try? fm.removeItem(at: file) }
            return (false, "Not joined: the note couldn't be saved (\(PastMeeting.describe(error))). Nothing was changed.")
        }
        var problems: [String] = []
        for (temp, final) in joinedAudio {
            do {
                if fm.fileExists(atPath: final.path) { try fm.trashItem(at: final, resultingItemURL: nil) }
                try fm.moveItem(at: temp, to: final)
            } catch {
                problems.append("some of the audio")
                try? fm.removeItem(at: temp)
            }
        }
        // The later meeting's files, and subtitles that no longer line up.
        var stale = Recorder.companionSuffixes.map { URL(fileURLWithPath: laterBase.path + $0) }
        stale += [".vtt", ".srt"].map { URL(fileURLWithPath: earlierBase.path + $0) }
        for file in stale where fm.fileExists(atPath: file.path) {
            if (try? fm.trashItem(at: file, resultingItemURL: nil)) == nil { problems.append(file.lastPathComponent) }
        }

        // The index: one entry, every speaker's lines found in the joined note.
        var entry = a.entry
        var keep = voicesA
        for speaker in b.entry.speakers {
            let name = names[display(speaker)] ?? display(speaker)
            guard !entry.speakers.contains(where: { display($0) == name }) else { continue }
            var moved = speaker
            if speaker.name == nil { moved = MeetingIndex.Speaker(id: speaker.id, label: name, name: nil, lines: [],
                                                                  pendingLearn: speaker.pendingLearn, learned: speaker.learned) }
            entry.speakers.append(moved)
            if let voice = voicesB[speaker.id] { keep[speaker.id] = voice }
        }
        for i in entry.speakers.indices {
            entry.speakers[i].lines = MeetingIndex.lineRefs(in: joined, speaker: display(entry.speakers[i]))
        }
        entry.speakers.removeAll { $0.lines.isEmpty }
        entry.noteHash = MeetingIndex.hash(Data(text.utf8))
        entry.eventID = entry.eventID ?? b.entry.eventID
        if entry.started == nil { entry.started = startA }
        if !index.save(entry) { problems.append("Wingman's list of speakers") }
        if recognizeVoices, index.mayKeepVoices(entry), !keep.isEmpty { index.keepVoices(keep, for: entry.id) }
        voices.moveContributions(from: b.entry.id, to: entry.id)
        index.remove(meeting: b.entry.id)
        Log.write("joined a meeting onto the one before it (\(b.note.lines.count) lines, \(offset) s in)")
        let time = startB.formatted(date: .omitted, time: .shortened)
        return problems.isEmpty
            ? (true, "Joined: the recording from \(time) now follows this one. Its files are in the Trash.")
            : (true, "Joined, but \(problems.joined(separator: ", ")) couldn't be moved or updated.")
    }
}
