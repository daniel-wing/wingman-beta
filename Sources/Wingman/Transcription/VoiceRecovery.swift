import AVFoundation
import Foundation

/// Finds the voices of a meeting recorded before 0.9 in its saved call audio, so
/// people named in it now can be recognized next time. Notes only have each
/// line's start time, so who spoke when is estimated, and the voices found are
/// only *offered*: the user plays a sample and chooses Learn. Nothing is learned
/// on its own.
///
/// The rules for offering a voice are hypotheses to be checked on real meetings
/// (`voicerecover`), not measured results; they lean toward offering nothing.
enum VoiceRecovery {
    struct Span: Equatable {
        let start: TimeInterval
        let end: TimeInterval
        var duration: TimeInterval { max(0, end - start) }
    }

    enum Outcome: Equatable {
        /// Their voice is cluster `cluster`; `sample` is a stretch of it to play.
        case offer(cluster: String, sample: Span)
        /// Less than 40 % (or 3 s) of their estimated speech was found.
        case tooLittleSpeech
        /// Their best cluster overlaps them for under 8 s.
        case notFound
        /// Their speech is spread over several voices (best has under 60 %).
        case mixed
        /// The voice they overlap most is mostly someone else's (they have under 75 % of it).
        case shared

        var reason: String {
            switch self {
            case .offer: "found"
            case .tooLittleSpeech, .notFound: "not enough of their speech was found in the call audio"
            case .mixed: "their speech sounds like more than one voice in the call audio"
            case .shared: "their voice can't be told apart from someone else's in the call audio"
            }
        }
    }

    struct Numbers: Equatable {
        let estimated: TimeInterval
        let found: TimeInterval
        let best: TimeInterval
        let bestShare: Double
        let exclusivity: Double
    }

    static let minimumFoundShare = 0.4
    static let minimumFound: TimeInterval = 3
    static let minimumOverlap: TimeInterval = 8
    static let minimumClusterShare = 0.6
    static let minimumExclusivity = 0.75

    /// When each speaker's lines were probably said: from each line's start,
    /// 0.4 s a word plus 0.8 s (1.5–15 s), and never past the next line on the
    /// same side (the call, or you).
    static func spans(_ note: MeetingNote, isMe: (String) -> Bool) -> [String: [Span]] {
        var result: [String: [Span]] = [:]
        let lines = note.lines
        for (i, line) in lines.enumerated() {
            let mine = isMe(line.speaker)
            let words = line.text.split(whereSeparator: \.isWhitespace).count
            var end = Double(line.start) + min(max(0.4 * Double(words) + 0.8, 1.5), 15)
            if let next = lines[(i + 1)...].first(where: { isMe($0.speaker) == mine }) {
                end = min(end, Double(max(next.start, line.start + 1)))
            }
            result[line.speaker, default: []].append(Span(start: Double(line.start), end: end))
        }
        return result
    }

    /// Which voice cluster is each speaker's, if the evidence is clear enough.
    /// `you` are the note's names for you: they take part in the overlap shares
    /// but are never offered.
    static func assign(turns: [SpeakerSeparation.Turn], spans: [String: [Span]], you: Set<String>)
        -> [String: (outcome: Outcome, numbers: Numbers)] {
        var overlap: [String: [String: TimeInterval]] = [:]
        var clusterTotal: [String: TimeInterval] = [:]
        for (speaker, list) in spans {
            for span in list {
                for turn in turns {
                    let shared = min(span.end, turn.end) - max(span.start, turn.start)
                    guard shared > 0 else { continue }
                    overlap[speaker, default: [:]][turn.speaker, default: 0] += shared
                    clusterTotal[turn.speaker, default: 0] += shared
                }
            }
        }
        var result: [String: (outcome: Outcome, numbers: Numbers)] = [:]
        for (speaker, list) in spans where !you.contains(speaker) {
            let estimated = list.reduce(0) { $0 + $1.duration }
            let mine = overlap[speaker] ?? [:]
            let found = mine.values.reduce(0, +)
            let best = mine.max { $0.value < $1.value }
            let bestTime = best?.value ?? 0
            let share = found > 0 ? bestTime / found : 0
            let exclusivity = best.map { bestTime / max(clusterTotal[$0.key] ?? 0, 0.001) } ?? 0
            let numbers = Numbers(estimated: estimated, found: found, best: bestTime, bestShare: share, exclusivity: exclusivity)
            let outcome: Outcome
            if found < minimumFound || found < minimumFoundShare * estimated {
                outcome = .tooLittleSpeech
            } else if bestTime < minimumOverlap {
                outcome = .notFound
            } else if share < minimumClusterShare {
                outcome = .mixed
            } else if exclusivity < minimumExclusivity {
                outcome = .shared
            } else {
                outcome = .offer(cluster: best!.key, sample: sample(of: best!.key, turns: turns, spans: list))
            }
            result[speaker] = (outcome, numbers)
        }
        return result
    }

    /// 3–5 s of the cluster during the speaker's lines: the stretch where they
    /// overlap longest.
    static func sample(of cluster: String, turns: [SpeakerSeparation.Turn], spans: [Span]) -> Span {
        var best = Span(start: 0, end: 0)
        for turn in turns where turn.speaker == cluster {
            for span in spans {
                let start = max(span.start, turn.start), end = min(span.end, turn.end)
                if end - start > best.duration { best = Span(start: start, end: end) }
            }
        }
        if best.duration < 3, let turn = turns.filter({ $0.speaker == cluster }).max(by: { $0.end - $0.start < $1.end - $1.start }) {
            best = Span(start: turn.start, end: turn.end)
        }
        return Span(start: best.start, end: min(best.end, best.start + 5))
    }

    /// The call audio a note's meeting kept: its own track only (`-them.m4a`,
    /// then `-them.wav`). The combined file has your voice mixed in; it's not used yet.
    static func callAudio(for note: URL) -> URL? {
        let base = note.deletingPathExtension()
        return ["-them.m4a", "-them.wav"]
            .map { base.deletingLastPathComponent().appendingPathComponent(base.lastPathComponent + $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - The search, in its own process

    /// What the search is given, and what it returns.
    struct Job: Codable {
        let note: URL
        let audio: URL
        let you: [String]
        let result: URL
    }

    struct Found: Codable, Equatable {
        let speaker: String
        let embedding: [Float]
        let sampleStart: Double
        let sampleEnd: Double
    }

    struct Result: Codable {
        var found: [Found] = []
        /// Speakers with no offer, and why.
        var notFound: [String: String] = [:]
    }

    /// `Wingman --recover-voices <job.json>`: runs speaker separation on the
    /// call audio and writes what it found. It only reads the meeting's files;
    /// the app decides what to keep. Started at background priority, and stopped
    /// as soon as a recording starts.
    static func runJob(_ path: String) async -> Int32 {
        guard let data = FileManager.default.contents(atPath: path),
              let job = try? JSONDecoder().decode(Job.self, from: data),
              let noteData = try? Data(contentsOf: job.note) else { return 2 }
        do {
            let result = try await search(note: MeetingNote.parse(noteData), audio: job.audio, you: Set(job.you))
            try JSONEncoder().encode(result).write(to: job.result, options: .atomic)
            return 0
        } catch {
            Log.write("voice search failed: \(Log.describe(error))")
            return 1
        }
    }

    static func search(note: MeetingNote, audio: URL, you: Set<String>) async throws -> Result {
        let separation = SpeakerSeparation(computeUnits: .cpuAndNeuralEngine)
        let separated = try await separation.separate(audio)
        let spans = spans(note, isMe: you.contains)
        var result = Result()
        for (speaker, assigned) in assign(turns: separated.turns, spans: spans, you: you) {
            if case .offer(let cluster, let sample) = assigned.outcome, let embedding = separated.voiceprints[cluster] {
                result.found.append(Found(speaker: speaker, embedding: embedding, sampleStart: sample.start, sampleEnd: sample.end))
            } else {
                result.notFound[speaker] = assigned.outcome.reason
            }
        }
        return result
    }
}

/// Runs voice searches one at a time, in a child process at background
/// priority, and never alongside a recording: one starting stops the search
/// (SIGTERM, then SIGKILL after 2 s) and it starts over once the recording is
/// done. What a search finds is kept only if, when it finishes, the meeting's
/// voices may still be kept (not deleted meanwhile, not past 180 days,
/// Recognize people still on).
@MainActor
@Observable
final class VoiceRecoveryRunner {
    private(set) var running: UUID?
    private var queue: [(meeting: UUID, note: URL)] = []
    private var process: Process?
    private var generation = 0
    private let recorder: Recorder
    /// Told when a meeting's search is done (to refresh what's shown).
    var onFinished: ((UUID) -> Void)?

    init(recorder: Recorder) { self.recorder = recorder }

    /// Asks for a meeting's voices to be searched for, if it qualifies: an older
    /// meeting where someone was just named, never searched before.
    func request(_ meeting: MeetingIndex.Meeting, note: URL) {
        guard recorder.recognizeVoices, meeting.voiceState == .none, recorder.index.mayKeepVoices(meeting),
              VoiceRecovery.callAudio(for: note) != nil,
              running != meeting.id, !queue.contains(where: { $0.meeting == meeting.id }) else { return }
        queue.append((meeting.id, note))
        next()
    }

    func isSearching(_ meeting: UUID) -> Bool { running == meeting || queue.contains { $0.meeting == meeting } }

    /// The Recorder's phase changed: recording goes first.
    func phaseChanged(_ phase: Recorder.Phase) {
        if phase == .idle { next() } else { preempt() }
    }

    private func preempt() {
        guard let process, let running else { return }
        Log.write("voice search paused for a recording")
        // The stopped search's result, if any, is ignored (`generation`).
        generation += 1
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
        self.process = nil
        if let note = notes[running] { queue.insert((running, note), at: 0) }
        finish(running)
    }

    private var notes: [UUID: URL] = [:]

    private func next() {
        guard running == nil, recorder.phase == .idle, !queue.isEmpty else { return }
        let (id, note) = queue.removeFirst()
        guard let meeting = recorder.index.meeting(id: id), recorder.index.mayKeepVoices(meeting), recorder.recognizeVoices,
              meeting.voiceState == .none, let audio = VoiceRecovery.callAudio(for: note) else {
            next()
            return
        }
        notes[id] = note
        running = id
        let key = meeting.key
        recorder.audioInUse.insert(key)
        let you = Set([meeting.meName, "Me"].compactMap { $0 })
        let folder = Recorder.scratchFile("wingman-voices-\(id.uuidString)").deletingLastPathComponent()
        let jobFile = folder.appendingPathComponent("wingman-voices-\(id.uuidString).json")
        let resultFile = folder.appendingPathComponent("wingman-voices-\(id.uuidString)-found.json")
        try? FileManager.default.removeItem(at: resultFile)
        let job = VoiceRecovery.Job(note: note, audio: audio, you: Array(you), result: resultFile)
        let started = generation
        let expectedGeneration = meeting.generation
        guard let data = try? JSONEncoder().encode(job), (try? data.write(to: jobFile)) != nil,
              let executable = Bundle.main.executableURL else {
            finish(id)
            return
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--recover-voices", jobFile.path]
        process.qualityOfService = .background
        process.terminationHandler = { [weak self] done in
            let status = done.terminationStatus
            Task { @MainActor in
                guard let self, self.generation == started else { return }
                self.process = nil
                try? FileManager.default.removeItem(at: jobFile)
                self.commit(id, resultFile: resultFile, ok: status == 0, expectedGeneration: expectedGeneration)
                self.finish(id)
                self.next()
            }
        }
        do {
            try process.run()
            self.process = process
            Log.write("voice search started for an older meeting")
        } catch {
            Log.write("couldn't start the voice search: \(Log.describe(error))")
            finish(id)
        }
    }

    private func finish(_ id: UUID) {
        if running == id {
            running = nil
            if let key = recorder.index.meeting(id: id)?.key { recorder.audioInUse.remove(key) }
            onFinished?(id)
        }
    }

    /// Keeps what was found, only if it's still allowed now.
    private func commit(_ id: UUID, resultFile: URL, ok: Bool, expectedGeneration: Int) {
        defer { try? FileManager.default.removeItem(at: resultFile) }
        let index = recorder.index
        guard recorder.recognizeVoices, var meeting = index.meeting(id: id), meeting.voiceState == .none,
              meeting.generation == expectedGeneration, index.mayKeepVoices(meeting) else {
            Log.write("voice search result discarded: the meeting's voices may no longer be kept")
            return
        }
        guard ok, let data = try? Data(contentsOf: resultFile),
              let result = try? JSONDecoder().decode(VoiceRecovery.Result.self, from: data) else {
            // No speech in the call audio, or the search failed: don't search this meeting again.
            Log.write("voice search found nothing usable")
            meeting.voiceState = .searched
            index.save(meeting)
            return
        }
        var voices: [UUID: MeetingIndex.Voice] = [:]
        for found in result.found {
            guard let speaker = meeting.speakers.first(where: { ($0.name ?? $0.label) == found.speaker }) else { continue }
            voices[speaker.id] = MeetingIndex.Voice(embedding: found.embedding, model: VoiceLibrary.currentModel,
                                                    recovered: true, sample: [found.sampleStart, found.sampleEnd])
        }
        Log.write("voice search: \(voices.count) of \(result.found.count + result.notFound.count) speakers found")
        if voices.isEmpty {
            // Nothing to offer; don't search again.
            meeting.voiceState = .searched
            index.save(meeting)
        } else {
            index.keepVoices(voices, for: id)
        }
    }
}
