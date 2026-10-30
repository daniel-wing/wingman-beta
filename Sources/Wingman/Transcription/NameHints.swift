import Foundation

/// Names the user gave lines during the call ("this line is Ana"), resolved
/// after Stop, once each line has its voice. Live, every remote line is plain
/// "Them": a name belongs to a line, and only afterwards to a voice.
///
/// A voice is named outright only when the user's name and the voice library
/// agree. Anything else is a "Name?" for the user to confirm: a new person,
/// a voice that sounds like someone else, or a voice given two names (the
/// separation may have merged two people).
enum NameHints {
    struct Result: Equatable {
        /// Label → name: the hints and the voice agree.
        var named: [String: String] = [:]
        /// Label → name, shown as "Name?" until the user confirms it.
        var toConfirm: [String: String] = [:]
        var notices: [String] = []
    }

    /// `hints` are (label, name) per hinted line, in transcript order;
    /// `matches` are the voice library's matches by label.
    static func resolve(_ hints: [(label: String, name: String)], matches: [String: VoiceLibrary.Match]) -> Result {
        var labels: [String] = []
        var byLabel: [String: [String]] = [:]
        for hint in hints {
            if byLabel[hint.label] == nil { labels.append(hint.label) }
            byLabel[hint.label, default: []].append(hint.name)
        }
        var result = Result()
        for label in labels {
            let names = distinct(byLabel[label] ?? [])
            guard let top = names.first else { continue }
            let match = matches[label]
            if names.count > 1 {
                result.toConfirm[label] = top.name
                let listed = names.map(\.name)
                result.notices.append("You named \(label) both \(listed.dropLast().joined(separator: ", ")) and \(listed.last!) during the call: check its lines.")
            } else if let match, VoiceLibrary.sameName(top.name, match.name) || VoiceLibrary.sameName(match.name, top.name) {
                // "Ana" for the known "Ana López", or the other way round.
                // Wingman's own spelling, so the voice joins that person.
                result.named[label] = match.name
            } else {
                result.toConfirm[label] = top.name
                if let match, match.confident {
                    result.notices.append("\(label) sounds like \(match.name), but you named them \(top.name) during the call.")
                }
            }
        }
        return result
    }

    /// The names given, most often first (earliest first on a tie), ignoring
    /// case and accents.
    private static func distinct(_ names: [String]) -> [(name: String, count: Int)] {
        var order: [String] = []
        var counts: [String: (name: String, count: Int)] = [:]
        for name in names {
            let key = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            if let seen = counts[key] {
                counts[key] = (seen.name, seen.count + 1)
            } else {
                order.append(key)
                counts[key] = (name, 1)
            }
        }
        return order.enumerated()
            .sorted { a, b in
                let (ca, cb) = (counts[a.element]!.count, counts[b.element]!.count)
                return ca != cb ? ca > cb : a.offset < b.offset
            }
            .map { counts[$0.element]! }
    }
}
