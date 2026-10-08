import Foundation
import Observation

/// People whose voices Wingman can recognize in later meetings, stored only on
/// this Mac. A voiceprint is a speaker embedding — 256 numbers describing how a
/// voice sounds, not what was said — averaged over every meeting where the
/// user named or confirmed that person.
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

        /// The sum, or the best stand-in for people saved before it existed.
        var runningSum: [Float] { sum ?? voiceprint.map { $0 * Float(meetings) } }
    }

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

    init(file: URL = VoiceLibrary.defaultFile) {
        self.file = file
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([Person].self, from: data) {
            people = saved
        }
    }

    // MARK: - Learning

    /// One voice taught to one person, so it can be taken back on its own,
    /// e.g. when the user corrects a name — even if the same person learned
    /// other voices since.
    struct LearnUndo {
        let person: UUID
        let voiceprint: [Float]
    }

    /// Remembers `voiceprint` as `name`, refining the stored one if this person
    /// is known. Returns how to undo it.
    @discardableResult
    func learn(_ name: String, voiceprint: [Float]) -> LearnUndo? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !voiceprint.isEmpty else { return nil }
        let vector = Self.normalized(voiceprint)
        let undo: LearnUndo
        if let i = people.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            undo = LearnUndo(person: people[i].id, voiceprint: vector)
            let old = people[i].runningSum
            let sum = old.count == vector.count ? zip(old, vector).map(+) : vector
            people[i].sum = sum
            people[i].voiceprint = Self.normalized(sum)
            people[i].meetings += 1
            people[i].lastHeard = Date()
        } else {
            let person = Person(id: UUID(), name: name, voiceprint: vector, meetings: 1, lastHeard: Date(), sum: vector)
            people.append(person)
            undo = LearnUndo(person: person.id, voiceprint: vector)
        }
        save()
        return undo
    }

    /// Takes one learned voice back out of the person's average; a person left
    /// with no voices is forgotten.
    func undo(_ undo: LearnUndo) {
        guard let i = people.firstIndex(where: { $0.id == undo.person }) else { return }
        var list = people
        let sum = list[i].runningSum
        if list[i].meetings <= 1 || sum.count != undo.voiceprint.count {
            list.remove(at: i)
        } else {
            let rest = zip(sum, undo.voiceprint).map(-)
            list[i].sum = rest
            list[i].voiceprint = Self.normalized(rest)
            list[i].meetings -= 1
        }
        replace(with: list, failure: "Wingman couldn't take back a voice it had learned")
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
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            people = []
            problem = nil
        } catch {
            Log.write("couldn't delete the voices: \(Log.describe(error))")
            problem = "Wingman couldn't delete its list of voices (\(error.localizedDescription)), so nobody was forgotten. Try again."
        }
    }

    /// Saves `list` and only then shows it.
    private func replace(with list: [Person], failure: String) {
        do {
            try persist(list)
            people = list
            problem = nil
        } catch {
            Log.write("couldn't save voices: \(Log.describe(error))")
            problem = "\(failure) (\(error.localizedDescription)). Try again."
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

    private nonisolated static func normalized(_ v: [Float]) -> [Float] {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? v.map { $0 / norm } : v
    }

    /// "Ana López" matches an invitee listed as "Ana López", "ana lópez" or
    /// "Ana López (Marketing)"; a first name alone matches only if it's a whole word.
    private nonisolated static func sameName(_ invitee: String, _ name: String) -> Bool {
        let a = invitee.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let b = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if a == b { return true }
        let words = Set(a.split { !$0.isLetter }.map(String.init))
        let nameWords = b.split { !$0.isLetter }.map(String.init)
        return !nameWords.isEmpty && nameWords.allSatisfy(words.contains)
    }

    private func save() {
        do {
            try persist(people)
            problem = nil
        } catch {
            Log.write("couldn't save voices: \(Log.describe(error))")
            problem = "Wingman couldn't save its list of voices (\(error.localizedDescription))."
        }
    }

    private func persist(_ list: [Person]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(list).write(to: file, options: [.atomic, .completeFileProtection])
    }
}
