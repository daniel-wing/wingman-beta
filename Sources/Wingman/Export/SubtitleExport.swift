import Foundation

/// Writes a transcript as WebVTT or SRT subtitles. VTT carries the speaker
/// as a voice tag (`<v Them 1>`); SRT has no such field, so the name goes at
/// the start of the text.
enum SubtitleExport {
    enum Format: String, CaseIterable {
        case vtt, srt
    }

    static func render(
        _ lines: [TranscriptLine], as format: Format, title: String? = nil, names: [String: String] = [:]
    ) -> String {
        func name(_ line: TranscriptLine) -> String { names[line.label] ?? line.label }
        // Lines carry a little lead-in audio, so neighbours can overlap by a
        // fraction of a second; trim each cue to start when the previous ends.
        // A line said entirely during someone else's (a quick "yes") keeps its
        // own times: trimming it would leave a cue with no duration, which players skip.
        var finals = lines.filter(\.isFinal)
        for i in finals.indices.dropFirst()
        where finals[i].start < finals[i - 1].end && finals[i].end > finals[i - 1].end {
            finals[i].start = finals[i - 1].end
        }
        switch format {
        case .vtt:
            var out = title.map { "WEBVTT - \($0.replacingOccurrences(of: "\n", with: " "))\n" } ?? "WEBVTT\n"
            for line in finals {
                out += "\n\(time(line.start, ".")) --> \(time(line.end, "."))\n"
                out += "<v \(escape(name(line)))>\(escape(line.text))\n"
            }
            return out
        case .srt:
            var out = ""
            for (index, line) in finals.enumerated() {
                out += "\(index + 1)\n\(time(line.start, ",")) --> \(time(line.end, ","))\n"
                out += "\(name(line)): \(line.text)\n\n"
            }
            return out
        }
    }

    private static func time(_ seconds: TimeInterval, _ separator: String) -> String {
        let ms = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, separator, ms % 1000)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
