import Foundation

/// Renames a speaker in a meeting's `.vtt` or `.srt`, alongside its note. A cue
/// is only changed when it lines up with the note: same order, same speaker,
/// and a start within a few seconds of the line's timestamp (cues can start a
/// little later, trimmed to where the previous one ends). If the file doesn't
/// line up — edited by hand, or written by something else — it's left alone.
enum SubtitleRewriter {
    enum Failure: Error, Equatable {
        case notText
        /// The cues don't match the note's transcript lines.
        case doesNotLineUp
        case unexpectedChange
    }

    struct Cue: Equatable {
        /// The row holding the text (just after the timing row).
        let row: Int
        let start: Double
    }

    /// `note` is the note before the rename (its speakers are what the cues should say).
    static func renameSpeaker(in data: Data, format: SubtitleExport.Format, note: MeetingNote,
                              from: String, to: String) throws -> Data {
        let rows = try split(data)
        let cues = Self.cues(in: rows)
        try check(rows, cues, format, speakers: note.lines.map(\.speaker), starts: note.lines.map(\.start))
        if from == to { return data }

        var new = rows
        for (cue, line) in zip(cues, note.lines) where line.speaker == from {
            let old = prefix(from, format), replacement = prefix(to, format)
            guard new[cue.row].hasPrefix(old) else { throw Failure.unexpectedChange }
            new[cue.row] = replacement + new[cue.row].dropFirst(old.count)
        }
        // Prove it: the result lines up with the renamed speakers, and nothing
        // but those cues' first rows changed.
        let speakers = note.lines.map { $0.speaker == from ? to : $0.speaker }
        try check(new, Self.cues(in: new), format, speakers: speakers, starts: note.lines.map(\.start))
        let changed = Set(zip(cues, note.lines).filter { $0.1.speaker == from }.map(\.0.row))
        for i in rows.indices where !changed.contains(i) && rows[i] != new[i] { throw Failure.unexpectedChange }
        return Data(new.joined(separator: "\n").utf8)
    }

    private static func prefix(_ name: String, _ format: SubtitleExport.Format) -> String {
        switch format {
        case .vtt: "<v \(SubtitleExport.escape(name))>"
        case .srt: "\(name): "
        }
    }

    private static func split(_ data: Data) throws -> [String] {
        try data.split(separator: 0x0A, omittingEmptySubsequences: false).map {
            guard let row = String(data: Data($0), encoding: .utf8) else { throw Failure.notText }
            return row
        }
    }

    static func cues(in rows: [String]) -> [Cue] {
        rows.indices.compactMap { i in
            let row = rows[i].hasSuffix("\r") ? String(rows[i].dropLast()) : rows[i]
            guard let arrow = row.range(of: " --> "), i + 1 < rows.count,
                  let start = seconds(String(row[..<arrow.lowerBound]))
            else { return nil }
            return Cue(row: i + 1, start: start)
        }
    }

    private static func check(_ rows: [String], _ cues: [Cue], _ format: SubtitleExport.Format,
                              speakers: [String], starts: [Int]) throws {
        guard cues.count == speakers.count else { throw Failure.doesNotLineUp }
        for (i, cue) in cues.enumerated() {
            let offset = cue.start - Double(starts[i])
            guard offset >= 0, offset < 3, rows[cue.row].hasPrefix(prefix(speakers[i], format)) else {
                throw Failure.doesNotLineUp
            }
        }
    }

    /// "00:01:02.500" (VTT) or "00:01:02,500" (SRT).
    private static func seconds(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }
}
