import Foundation
import Observation

/// People whose voices Wingman can recognize in later meetings, stored in
/// Wingman's folder (never uploaded). A voiceprint is a speaker embedding — 256
/// numbers describing how a voice sounds, not what was said — averaged over every
/// meeting where the user named or confirmed that person.
///
/// Each voice learned is kept as a contribution (which meeting, which speaker in
/// it), so one can be taken back exactly, a meeting's voices can be deleted, and
/// the same voice is never learned twice. The file stays readable by 0.8.
@MainActor
@Observable
final class VoiceLibrary {
    struct Person: Codable, Identifiable, Equatable {
        let id: UUID
        var name: String
        var voiceprint: [Float]
        /// How many meetings the voiceprint is averaged over.
        var meetings: Int
        var lastHeard: Date
        /// Sum of the (normalized) voices learned, so one can be taken out
        /// exactly; `voiceprint` is its direction. Missing in older files.
        var sum: [Float]? = nil
        /// The voices learned. Missing in files from 0.8; `load` turns what 0.8
        /// learned into one legacy contribution.
        var contributions: [Contribution]? = nil
        /// The speech model the voices come from; nil for voices learned before 0.9
        /// (all from the same model so far).
        var model: String? = nil

        /// The sum, or the best stand-in for people saved before it existed.
        var runningSum: [Float] { sum ?? voiceprint.map { $0 * Float(meetings) } }
    }

    /// One voice learned into a person.
    struct Contribution: Codable, Equatable, Identifiable {
        let id: UUID
        /// The meeting it came from (`MeetingIndex` id); nil for what 0.8 learned.
        let meeting: UUID?
        /// The speaker in that meeting (`MeetingIndex` speaker id).
        let speaker: UUID?
        /// Normalized, except a legacy contribution, which holds 0.8's whole sum.
        let embedding: [Float]
        /// How many meetings it stands for: 1, or 0.8's count for a legacy one.
        let weight: Int
        let learned: Date

        var isLegacy: Bool { meeting == nil }
    }

    /// What happened when Wingman was asked to learn a voice.
    enum LearnOutcome: Equatable {
        case learned(person: UUID, contribution: UUID)
        /// This meeting's speaker was learned before; nothing changed.
        case alreadyLearned(person: UUID, contribution: UUID)
        /// Someone with that name is known, but this voice doesn't sound like them.
        case soundsDifferent(person: UUID, similarity: Float)
        /// The voice comes from a different speech model than the person's.
        case differentModel
        case notSaved

        var contribution: UUID? {
            switch self {
            case .learned(_, let id), .alreadyLearned(_, let id): id
            default: nil
            }
        }
    }

    /// The speaker-embedding model the voices come from (FluidAudio's offline
    /// diarizer, pinned by the package version). Change it when a FluidAudio
    /// update changes the embedding: voices from different models aren't comparable.
    nonisolated static let currentModel = "fluidaudio-offline-diarizer-1"

    struct Match {
        let name: String
        let similarity: Float
        /// Confident enough to label without asking; otherwise shown as "Name?".
        let confident: Bool
    }

    /// Calibrated on synthetic voices across separate recordings: the same voice
    /// scored 0.77–0.93, different voices 0.17–0.54. Real voices on different
    /// microphones vary more, so the "ask" band is generous.
    static let confidentAt: Float = 0.72
    static let askAt: Float = 0.58
    /// A confident label also needs a clear lead over the next-best person.
    static let minimumLead: Float = 0.08

    private(set) var people: [Person] = []
    /// What couldn't be saved or deleted, shown in Settings → People; nil when
    /// the list on disk matches what's shown.
    private(set) var problem: String?

    nonisolated static let defaultFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Wingman", isDirectory: true)
        .appendingPathComponent("voices.json")
    private let file: URL
    /// Which meeting each voice came from, also kept beside `voices.json` (as `voices-history.json`):
    /// 0.8 rewrites `voices.json` without it (it keeps the sums, so its own
    /// learning shows up as a difference), so a downgrade and back doesn't
    /// lose what Delete Voices and undo need.
    private var historyFile: URL { Self.historyFile(for: file) }
    nonisolated static func historyFile(for file: URL) -> URL {
        file.deletingLastPathComponent().appendingPathComponent(file.deletingPathExtension().lastPathComponent + "-history.json")
    }
    struct History: Codable, Equatable {
        var contributions: [Contribution]
        var model: String?
    }

    init(file: URL = VoiceLibrary.defaultFile) {
        self.file = file
        guard let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode([Person].self, from: data) else { return }
        let history = (try? Data(contentsOf: historyFile)).flatMap { try? JSONDecoder().decode([String: History].self, from: $0) } ?? [:]
        people = saved.map { Self.withContributions(Self.restoring($0, from: history[$0.id.uuidString])) }
    }

    /// A person as an older Wingman saved them (no contributions) gets back
    /// the ones the history file kept for them.
    nonisolated static func restoring(_ person: Person, from history: History?) -> Person {
        guard person.contributions == nil, let history, !history.contributions.isEmpty else { return person }
        var person = person
        person.contributions = history.contributions
        if person.model == nil { person.model = history.model }
        return person
    }

    /// A person with contributions that add up to their sum: what 0.8 learned
    /// (no contributions, or a sum 0.8 changed after 0.9 wrote them) becomes one
    /// legacy contribution.
    nonisolated static func withContributions(_ person: Person) -> Person {
        var person = person
        let old = person.contributions ?? []
        let tracked = old.filter { !$0.isLegacy }
        let trackedSum = sum(of: tracked, count: person.voiceprint.count)
        let trackedCount = tracked.reduce(0) { $0 + $1.weight }
        let total = person.runningSum
        // Whatever the tracked voices don't account for is what 0.8 learned.
        let rest = total.count == trackedSum.count ? zip(total, trackedSum).map(-) : total
        var list = tracked
        if person.meetings > trackedCount, rest.contains(where: { abs($0) > 1e-4 }) {
            let id = old.first(where: \.isLegacy)?.id ?? UUID()
            list.insert(Contribution(id: id, meeting: nil, speaker: nil, embedding: rest,
                                     weight: person.meetings - trackedCount, learned: person.lastHeard), at: 0)
        }
        guard !list.isEmpty else { return person }
        person.contributions = list
        recompute(&person)
        return person
    }

    private nonisolated static func sum(of list: [Contribution], count: Int) -> [Float] {
        var total = [Float](repeating: 0, count: list.first?.embedding.count ?? count)
        for c in list where c.embedding.count == total.count {
            for i in total.indices { total[i] += c.embedding[i] }
        }
        return total
    }

    // MARK: - Learning

    /// Learns a meeting speaker's voice as `name`.
    /// - A new name makes a new person.
    /// - A known name adds to that person if the voice sounds like them
    ///   (similarity ≥ `askAt`); otherwise nothing is learned and the caller can
    ///   offer to learn it as a different person with the same name (`asNewPerson`).
    /// - The same meeting speaker is never learned twice into the same person.
    /// Saved before it's shown; `.notSaved` if the file couldn't be written.
    @discardableResult
    func learn(_ name: String, voiceprint: [Float], meeting: UUID, speaker: UUID,
               model: String = VoiceLibrary.currentModel, asNewPerson: Bool = false) -> LearnOutcome {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !voiceprint.isEmpty else { return .notSaved }
        let vector = Self.normalized(voiceprint)
        let contribution = Contribution(id: UUID(), meeting: meeting, speaker: speaker, embedding: vector, weight: 1, learned: Date())
        var list = people

        let sameName = list.indices.filter { list[$0].name.caseInsensitiveCompare(name) == .orderedSame }
        for i in sameName {
            if let done = list[i].contributions?.first(where: { $0.meeting == meeting && $0.speaker == speaker }) {
                return .alreadyLearned(person: list[i].id, contribution: done.id)
            }
        }
        if !asNewPerson, !sameName.isEmpty {
            let comparable = sameName.filter { (list[$0].model ?? model) == model && list[$0].voiceprint.count == vector.count }
            guard !comparable.isEmpty else { return .differentModel }
            let best = comparable.max { Self.similarity(vector, list[$0].voiceprint) < Self.similarity(vector, list[$1].voiceprint) }!
            let score = Self.similarity(vector, list[best].voiceprint)
            guard score >= Self.askAt else { return .soundsDifferent(person: list[best].id, similarity: score) }
            list[best].contributions = (list[best].contributions ?? []) + [contribution]
            list[best].model = model
            Self.recompute(&list[best])
            list[best].lastHeard = Date()
            return replace(with: list, failure: "Wingman couldn't save \(name)'s voice")
                ? .learned(person: list[best].id, contribution: contribution.id) : .notSaved
        }
        let person = Person(id: UUID(), name: name, voiceprint: vector, meetings: 1, lastHeard: Date(), sum: vector,
                            contributions: [contribution], model: model)
        list.append(person)
        return replace(with: list, failure: "Wingman couldn't save \(name)'s voice")
            ? .learned(person: person.id, contribution: contribution.id) : .notSaved
    }

    /// Takes one learned voice back out of its person; a person left with no
    /// voices is forgotten. Later learning is unaffected.
    func undo(contribution id: UUID) {
        guard let i = people.firstIndex(where: { $0.contributions?.contains { $0.id == id } == true }) else { return }
        var list = people
        list[i].contributions?.removeAll { $0.id == id }
        if list[i].contributions?.isEmpty ?? true {
            list.remove(at: i)
        } else {
            Self.recompute(&list[i])
        }
        replace(with: list, failure: "Wingman couldn't take back a voice it had learned")
    }

    func contribution(_ id: UUID) -> Contribution? {
        people.lazy.compactMap { $0.contributions?.first { $0.id == id } }.first
    }

    /// Who deleting a meeting's voices would change: people recalculated without
    /// it, and people learned only from it (forgotten).
    func effectOfRemoving(meetings: Set<UUID>) -> (recalculated: [String], forgotten: [String]) {
        var recalculated: [String] = [], forgotten: [String] = []
        let from = { (c: Contribution) in c.meeting.map(meetings.contains) ?? false }
        for person in people where person.contributions?.contains(where: from) == true {
            if person.contributions!.allSatisfy(from) { forgotten.append(person.name) } else { recalculated.append(person.name) }
        }
        return (recalculated.sorted(), forgotten.sorted())
    }

    /// Removes every voice learned from `meetings`. False if it couldn't be saved.
    @discardableResult
    func removeVoices(fromMeetings meetings: Set<UUID>) -> Bool {
        var list = people
        for i in list.indices.reversed() where list[i].contributions?.contains(where: { $0.meeting.map(meetings.contains) ?? false }) == true {
            list[i].contributions?.removeAll { $0.meeting.map(meetings.contains) ?? false }
            if list[i].contributions?.isEmpty ?? true { list.remove(at: i) } else { Self.recompute(&list[i]) }
        }
        guard list != people else { return true }
        return replace(with: list, failure: "Wingman couldn't delete the voices learned from that meeting")
    }

    /// Sum, voiceprint and meeting count from the contributions.
    private nonisolated static func recompute(_ person: inout Person) {
        let list = person.contributions ?? []
        let total = sum(of: list, count: person.voiceprint.count)
        person.sum = total
        person.voiceprint = normalized(total)
        person.meetings = list.reduce(0) { $0 + $1.weight }
    }

    func rename(_ person: Person, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let i = people.firstIndex(of: person) else { return }
        var list = people
        list[i].name = name
        replace(with: list, failure: "Wingman couldn't rename \(person.name)")
    }

    /// Forgets a person only once that's on disk: if it can't be saved, they stay
    /// listed (forgetting again retries) and the problem is shown.
    func forget(_ person: Person) {
        replace(with: people.filter { $0.id != person.id }, failure: "Wingman couldn't forget \(person.name)")
    }

    func forgetEveryone() {
        do {
            // The history holds voices too.
            for url in [file, historyFile] where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            people = []
            problem = nil
        } catch {
            Log.write("couldn't delete the voices: \(Log.describe(error))")
            problem = "Wingman couldn't delete its list of voices (\(error.localizedDescription)), so nobody was forgotten. Try again."
        }
    }

    /// Saves `list` and only then shows it.
    @discardableResult
    private func replace(with list: [Person], failure: String) -> Bool {
        do {
            try persist(list)
            people = list
            problem = nil
            return true
        } catch {
            Log.write("couldn't save voices: \(Log.describe(error))")
            problem = "\(failure) (\(error.localizedDescription)). Try again."
            return false
        }
    }

    // MARK: - Matching

    /// Matches each voice (keyed by label, e.g. "Them 1") to a known person.
    /// When the meeting has invitees, only they can be labeled confidently;
    /// anyone else is at most suggested ("Name?"), since people join calls
    /// they weren't invited to. Each person is matched to at
    /// most one voice, best pairs first.
    func match(_ voiceprints: [String: [Float]], invitees: [String]) -> [String: Match] {
        guard !people.isEmpty, !voiceprints.isEmpty else { return [:] }
        let invited = Set(people.filter { person in invitees.contains { Self.sameName($0, person.name) } }.map(\.id))
        let candidates = people

        var scores: [(label: String, person: Person, score: Float)] = []
        for (label, print) in voiceprints {
            for person in candidates {
                scores.append((label, person, Self.similarity(print, person.voiceprint)))
            }
        }

        var matches: [String: Match] = [:]
        var usedPeople = Set<UUID>()
        for entry in scores.sorted(by: { $0.score > $1.score }) where entry.score >= Self.askAt {
            guard matches[entry.label] == nil, !usedPeople.contains(entry.person.id) else { continue }
            let runnerUp = scores
                .filter { $0.label == entry.label && $0.person.id != entry.person.id }
                .map(\.score).max() ?? -1
            // With an invitee list, only invited people are labeled outright —
            // even when none of them is known yet.
            let confident = entry.score >= Self.confidentAt && entry.score - runnerUp >= Self.minimumLead
                && (invitees.isEmpty || invited.contains(entry.person.id))
            matches[entry.label] = Match(name: entry.person.name, similarity: entry.score, confident: confident)
            usedPeople.insert(entry.person.id)
        }
        return matches
    }

    // MARK: - Helpers

    /// Cosine similarity of two voiceprints, -1…1.
    nonisolated static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }

    nonisolated static func normalized(_ v: [Float]) -> [Float] {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? v.map { $0 / norm } : v
    }

    /// "Ana López" matches an invitee listed as "Ana López", "ana lópez" or
    /// "Ana López (Marketing)"; a first name alone matches only if it's a whole word.
    nonisolated static func sameName(_ invitee: String, _ name: String) -> Bool {
        let a = invitee.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let b = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if a == b { return true }
        let words = Set(a.split { !$0.isLetter }.map(String.init))
        let nameWords = b.split { !$0.isLetter }.map(String.init)
        return !nameWords.isEmpty && nameWords.allSatisfy(words.contains)
    }

    private func persist(_ list: [Person]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(list).write(to: file, options: [.atomic, .completeFileProtection])
        var history: [String: History] = [:]
        for person in list { history[person.id.uuidString] = History(contributions: person.contributions ?? [], model: person.model) }
        try JSONEncoder().encode(history).write(to: historyFile, options: [.atomic, .completeFileProtection])
    }

    /// Of these learned voices (contribution ids), the ones no longer
    /// traceable: an older Wingman folded them into a person's voice.
    func untraceable(_ contributions: Set<UUID>) -> Set<UUID> {
        let known = Set(people.flatMap { $0.contributions ?? [] }.map(\.id))
        return contributions.subtracting(known)
    }
}
