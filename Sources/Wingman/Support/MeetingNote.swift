import Foundation

/// A Wingman note read back from disk: its header and its transcript lines, with
/// every byte accounted for, so a speaker can be renamed without touching
/// anything else the user wrote. Pure: no file access.
///
/// The transcript is the part between a line that is exactly `## Transcript` and
/// the next `#` or `##` heading (or the end). In it, a transcript line is
/// `[HH:MM:SS] **Speaker:** text`, optionally ending in one of Wingman's marks;
/// every other row (blank lines, the user's own text, fenced code) is kept as is.
struct MeetingNote: Equatable {
    /// Why a note can be shown but not changed.
    enum ReadOnly: Equatable {
        case notText, tooLarge, noTranscript, severalTranscripts, unclosedCodeBlock, notWingman

        var reason: String {
            switch self {
            case .notText: "it isn't plain text Wingman can read"
            case .tooLarge: "it's too large"
            case .noTranscript: "it has no Transcript section"
            case .severalTranscripts: "it has more than one Transcript section"
            case .unclosedCodeBlock: "a code block in it isn't closed"
            case .notWingman: "it doesn't look like a Wingman note"
            }
        }
    }

    enum Mark: String, CaseIterable {
        case unclear = " *(unclear)*"
        case possibleEcho = " *(possible echo)*"
        case incomplete = " *(incomplete)*"
    }

    struct Line: Equatable {
        /// Which row of the note it is.
        let row: Int
        /// Seconds from the start of the recording.
        let start: Int
        let speaker: String
        /// What was said, without the mark.
        let text: String
        let mark: Mark?
    }

    /// The note's rows, split at "\n" (a "\r" before it stays in the row), so
    /// joining them with "\n" gives back the exact bytes.
    let rows: [String]
    let lines: [Line]
    let title: String?
    /// `**Date:**`, `**Calendar:**`, `**Organizer:**`, `**Invited:**`, … by field name.
    let header: [String: String]
    let readOnly: ReadOnly?

    static let maximumBytes = 10_000_000

    /// Reads a note's bytes. Never fails: a note Wingman can't safely change
    /// comes back with `readOnly` set (and its lines, when it has them).
    static func parse(_ data: Data) -> MeetingNote {
        guard data.count <= maximumBytes else { return MeetingNote(rows: [], lines: [], title: nil, header: [:], readOnly: .tooLarge) }
        // Split the bytes, not the String: Swift treats "\r\n" as one character.
        var rows: [String] = []
        for piece in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
            guard let row = String(data: Data(piece), encoding: .utf8) else {
                return MeetingNote(rows: [], lines: [], title: nil, header: [:], readOnly: .notText)
            }
            rows.append(row)
        }

        var lines: [Line] = []
        var title: String?
        var header: [String: String] = [:]
        var fence: (char: Character, count: Int)?
        var transcripts = 0
        var inTranscript = false
        for (index, raw) in rows.enumerated() {
            let row = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if let open = fence {
                if isFenceClose(row, open) { fence = nil }
                continue
            }
            if let open = fenceOpen(row) {
                fence = open
                continue
            }
            if row == "## Transcript" {
                transcripts += 1
                inTranscript = true
                continue
            }
            if row.hasPrefix("# ") || row.hasPrefix("## ") || row == "#" || row == "##" {
                if title == nil, transcripts == 0, row.hasPrefix("# ") {
                    title = String(row.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                }
                inTranscript = false
                continue
            }
            if inTranscript {
                if let line = transcriptLine(row, at: index) { lines.append(line) }
            } else if transcripts == 0, let (field, value) = headerField(row) {
                header[field] = header[field] ?? value
            }
        }

        let readOnly: ReadOnly? =
            fence != nil ? .unclosedCodeBlock
            : transcripts == 0 ? .noTranscript
            : transcripts > 1 ? .severalTranscripts
            : header["Date"] == nil ? .notWingman
            : nil
        return MeetingNote(rows: rows, lines: lines, title: title, header: header, readOnly: readOnly)
    }

    /// The note's bytes, rebuilt from its rows.
    var data: Data { Data(rows.joined(separator: "\n").utf8) }

    /// The speakers in order of their first line, each once.
    var speakers: [String] {
        var seen = Set<String>(), order: [String] = []
        for line in lines where seen.insert(line.speaker).inserted { order.append(line.speaker) }
        return order
    }

    // MARK: - Rows

    private static let linePattern = try! NSRegularExpression(pattern: #"^\[(\d{2,}):(\d{2}):(\d{2})\] \*\*(.+?):\*\* ?(.*)$"#)

    /// The speaker's place in a transcript row (UTF-16 offsets), for rewriting it.
    static func speakerRange(in row: String) -> NSRange? {
        let row = row.hasSuffix("\r") ? String(row.dropLast()) : row
        let match = linePattern.firstMatch(in: row, range: NSRange(row.startIndex..., in: row))
        return match?.range(at: 4)
    }

    private static func transcriptLine(_ row: String, at index: Int) -> Line? {
        let ns = row as NSString
        guard let match = linePattern.firstMatch(in: row, range: NSRange(location: 0, length: ns.length)),
              let h = Int(ns.substring(with: match.range(at: 1))),
              let m = Int(ns.substring(with: match.range(at: 2))),
              let s = Int(ns.substring(with: match.range(at: 3))), m < 60, s < 60
        else { return nil }
        var text = ns.substring(with: match.range(at: 5))
        var mark: Mark?
        if let found = Mark.allCases.first(where: { text.hasSuffix($0.rawValue) }) {
            mark = found
            text = String(text.dropLast(found.rawValue.count))
        }
        return Line(row: index, start: h * 3600 + m * 60 + s, speaker: ns.substring(with: match.range(at: 4)), text: text, mark: mark)
    }

    /// `**Field:** value` (Wingman ends header lines with two spaces).
    private static func headerField(_ row: String) -> (String, String)? {
        guard row.hasPrefix("**") else { return nil }
        let start = row.index(row.startIndex, offsetBy: 2)
        guard let close = row.range(of: ":**", range: start..<row.endIndex) else { return nil }
        let field = String(row[start..<close.lowerBound])
        guard !field.isEmpty, !field.contains("*") else { return nil }
        return (field, String(row[close.upperBound...]).trimmingCharacters(in: .whitespaces))
    }

    /// A code fence: up to three spaces, then three or more ` or ~.
    private static func fenceOpen(_ row: String) -> (char: Character, count: Int)? {
        let trimmed = row.drop { $0 == " " }
        guard row.count - trimmed.count <= 3, let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let count = trimmed.prefix { $0 == first }.count
        guard count >= 3 else { return nil }
        // A backtick fence's info string can't contain backticks.
        if first == "`", trimmed.dropFirst(count).contains("`") { return nil }
        return (first, count)
    }

    private static func isFenceClose(_ row: String, _ open: (char: Character, count: Int)) -> Bool {
        let trimmed = row.drop { $0 == " " }
        guard row.count - trimmed.count <= 3 else { return false }
        let count = trimmed.prefix { $0 == open.char }.count
        return count >= open.count && trimmed.dropFirst(count).allSatisfy { $0 == " " || $0 == "\t" }
    }
}

// MARK: - Speakers

extension MeetingNote {
    enum SpeakerKind: Equatable {
        /// `Them`, `Them 2`: nobody has named them yet.
        case unnamed
        /// `Ana?`: Wingman's guess, waiting to be confirmed.
        case guess
        /// The person recording.
        case me
        case named
    }

    /// What a speaker's name in a note means. Only the literal `Me` or the name
    /// the note was recorded with (`meName`) is you; a name that happens to match
    /// today's "my name" setting isn't enough.
    static func kind(of speaker: String, meName: String? = nil) -> SpeakerKind {
        if speaker == "Me" { return .me }
        if let meName, !meName.isEmpty, speaker == meName { return .me }
        if SpeakerName.isPlaceholder(speaker) { return .unnamed }
        if speaker.hasSuffix("?") { return .guess }
        return .named
    }
}

/// Names people can give a speaker.
enum SpeakerName {
    static let maximumLength = 60

    /// The name to use, or nil if it can't be one: whitespace collapsed, `*` and a
    /// trailing `?` removed, at most 60 characters. `Me`, `Them` and `Them 2` are
    /// Wingman's own labels, and a name can't contain what would end it in a note.
    static func clean(_ name: String) -> String? {
        var name = name.replacingOccurrences(of: "*", with: "")
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        while name.hasSuffix("?") { name = String(name.dropLast()).trimmingCharacters(in: .whitespaces) }
        if name.count > maximumLength { name = String(name.prefix(maximumLength)).trimmingCharacters(in: .whitespaces) }
        guard !name.isEmpty, !isPlaceholder(name), name.caseInsensitiveCompare("Me") != .orderedSame else { return nil }
        return name
    }

    /// `Them` or `Them <number>`, in any case.
    static func isPlaceholder(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard lower.hasPrefix("them") else { return false }
        let rest = lower.dropFirst(4)
        return rest.isEmpty || (rest.first == " " && rest.dropFirst().allSatisfy(\.isNumber) && rest.count > 1)
    }
}

// MARK: - Rewriting

/// Renames a speaker in a note's (or subtitles') text, changing nothing else, and
/// proves it: the result is parsed again and compared row by row.
enum NoteRewriter {
    enum Failure: Error, Equatable {
        case readOnly(MeetingNote.ReadOnly)
        case invalidName
        case speakerNotFound
        /// The result differs in more than the speaker names (a bug: nothing is written).
        case unexpectedChange
    }

    /// The spelling to use for `name`: an existing speaker's, if one matches
    /// ignoring case (naming two speakers the same merges them).
    static func spelling(for name: String, in note: MeetingNote, renaming from: String) -> String {
        note.speakers.first { $0 != from && $0.caseInsensitiveCompare(name) == .orderedSame } ?? name
    }

    /// The note with every transcript line spoken by exactly `from` given `to`
    /// (already cleaned and spelled; see `spelling`).
    static func renameSpeaker(in data: Data, from: String, to: String) throws -> Data {
        let note = MeetingNote.parse(data)
        if let readOnly = note.readOnly { throw Failure.readOnly(readOnly) }
        guard !to.isEmpty, !to.contains(":**"), !to.contains("\n"), !to.contains("\r") else { throw Failure.invalidName }
        let targets = note.lines.filter { $0.speaker == from }
        guard !targets.isEmpty else { throw Failure.speakerNotFound }
        if from == to { return data }

        var rows = note.rows
        for line in targets {
            guard let range = MeetingNote.speakerRange(in: rows[line.row]) else { throw Failure.unexpectedChange }
            rows[line.row] = (rows[line.row] as NSString).replacingCharacters(in: range, with: to)
        }
        let result = Data(rows.joined(separator: "\n").utf8)
        try verify(old: note, new: MeetingNote.parse(result), from: from, to: to)
        return result
    }

    /// Only the target lines' speakers changed; every other row is identical.
    static func verify(old: MeetingNote, new: MeetingNote, from: String, to: String) throws {
        guard new.readOnly == nil, new.rows.count == old.rows.count, new.lines.count == old.lines.count
        else { throw Failure.unexpectedChange }
        let changed = Set(old.lines.filter { $0.speaker == from }.map(\.row))
        for (a, b) in zip(old.lines, new.lines) {
            let expected = a.speaker == from ? to : a.speaker
            guard a.row == b.row, a.start == b.start, a.text == b.text, a.mark == b.mark, b.speaker == expected
            else { throw Failure.unexpectedChange }
        }
        for row in old.rows.indices where !changed.contains(row) {
            guard old.rows[row] == new.rows[row] else { throw Failure.unexpectedChange }
        }
    }
}
