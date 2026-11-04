import AVFoundation
import Foundation

/// Joining a saved meeting onto the one before it: one call recorded in pieces
/// (Wingman restarted mid-call, or a split that shouldn't have happened). The
/// later meeting's lines go after the earlier one's, at the time they were
/// said, its audio after the earlier audio with silence for the gap between.
/// Owner, 2026-11-02: suggested when two pieces look like one call, never done
/// on its own. The pure parts are here; `Recorder.join` does the files.
enum MeetingJoin {
    /// Who each of the later meeting's speakers is in the joined note:
    /// - you are you (the earlier note's name for you);
    /// - a name or a guess stays as it is (the same name in both is one person);
    /// - an unnamed voice whose kept voiceprint matches one of the earlier
    ///   meeting's unnamed voices becomes that one (`sameVoice`);
    /// - any other unnamed voice keeps its label if the earlier meeting doesn't
    ///   use it, else gets the next free `Them N`.
    static func speakerMap(earlier: [String], later: [String], earlierMe: String?, laterMe: String?,
                           sameVoice: [String: String]) -> [String: String] {
        var used = Set(earlier)
        var map: [String: String] = [:]
        let me = earlier.first { MeetingNote.kind(of: $0, meName: earlierMe) == .me } ?? earlierMe.flatMap { $0.isEmpty ? nil : $0 } ?? "Me"
        var next = (earlier.compactMap(number(in:)).max() ?? 0) + 1
        for speaker in later {
            switch MeetingNote.kind(of: speaker, meName: laterMe) {
            case .me:
                map[speaker] = me
            case .named, .guess:
                map[speaker] = speaker
            case .unnamed:
                if let same = sameVoice[speaker] {
                    map[speaker] = same
                } else if !used.contains(speaker) {
                    map[speaker] = speaker
                } else {
                    while used.contains("Them \(next)") { next += 1 }
                    map[speaker] = "Them \(next)"
                    next += 1
                }
            }
            used.insert(map[speaker]!)
        }
        return map
    }

    /// 2 for "Them 2"; nil for anything else.
    private static func number(in label: String) -> Int? {
        guard SpeakerName.isPlaceholder(label) else { return nil }
        return Int(label.split(separator: " ").last ?? "")
    }

    /// The joined note: the earlier note as it is, with the later one's lines
    /// after its last line (moved by `offset` seconds, speakers renamed by
    /// `names`), a row for the time between them when there was some, the
    /// duration updated, and the explanation of any mark the earlier note
    /// didn't have. Nothing else in the earlier note changes.
    static func joinedNote(earlier: MeetingNote, later: MeetingNote, offset: Int, earlierEnd: Int,
                           names: [String: String], minutes: Int) -> String {
        var rows = earlier.rows
        let insertAt = (earlier.lines.last?.row ?? rows.count - 1) + 1
        var added: [String] = []
        let gap = offset - earlierEnd
        if gap >= 1 {
            added += ["", "*[\(Recorder.timestamp(TimeInterval(earlierEnd)))] Not recorded for \(Meeting.duration(TimeInterval(gap))) (between two recordings).*"]
        }
        for line in later.lines {
            added += ["", "[\(Recorder.timestamp(TimeInterval(line.start + offset)))] **\(names[line.speaker] ?? line.speaker):** \(line.text)\(line.mark?.rawValue ?? "")"]
        }
        rows.insert(contentsOf: added, at: insertAt)
        if let duration = rows.firstIndex(where: { $0.hasPrefix("**Duration:**") }) {
            rows[duration] = "**Duration:** \(minutes) min"
        }
        // "Wingman stopped unexpectedly…, so it ends there" is about where the
        // recording ends: now the later one's (if it says so), not the earlier one's.
        let ending = later.rows.first { $0.hasPrefix("**Recording:**") }
        if let row = rows.firstIndex(where: { $0.hasPrefix("**Recording:**") }) {
            if let ending { rows[row] = ending } else { rows.remove(at: row) }
        }
        // Marks the later lines brought that the earlier note doesn't explain.
        let had = Set(earlier.lines.compactMap(\.mark))
        let missing = MeetingNote.Mark.allCases.filter { mark in !had.contains(mark) && later.lines.contains { $0.mark == mark } }
        if !missing.isEmpty {
            while rows.last?.isEmpty == true { rows.removeLast() }
            if had.isEmpty {
                rows += ["", "---"]
            } else if let last = rows.indices.last {
                rows[last] += "  "
            }
            rows += [missing.map(\.explanation).joined(separator: "  \n")]
            rows.append("")
        }
        return rows.joined(separator: "\n")
    }

    /// The earlier audio, silence up to `offset` seconds, then the later audio,
    /// as one compressed file like the meeting's own (`AudioMix.settings`).
    /// Either side may be missing; its time is silence.
    static func joinAudio(earlier: URL?, later: URL?, offset: TimeInterval, to output: URL) throws {
        let format = Resampler.outputFormat
        try? FileManager.default.removeItem(at: output)
        let out = try AVAudioFile(forWriting: output, settings: AudioMix.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = format.sampleRate
        var written: AVAudioFramePosition = 0
        func copy(_ url: URL) throws {
            let file = try AVAudioFile(forReading: url)
            guard file.processingFormat.sampleRate == rate, file.processingFormat.channelCount == 1 else {
                throw AudioMixError("\(url.lastPathComponent) isn't 16 kHz mono")
            }
            let chunk: AVAudioFrameCount = 16_000 * 4
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return }
            while file.framePosition < file.length {
                try file.read(into: buffer, frameCount: chunk)
                guard buffer.frameLength > 0 else { break }
                try out.write(from: buffer)
                written += AVAudioFramePosition(buffer.frameLength)
            }
        }
        func silence(until frame: AVAudioFramePosition) throws {
            let chunk: AVAudioFrameCount = 16_000 * 4
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return }
            while written < frame {
                let n = AVAudioFrameCount(min(AVAudioFramePosition(chunk), frame - written))
                memset(buffer.floatChannelData![0], 0, Int(n) * MemoryLayout<Float>.size)
                buffer.frameLength = n
                try out.write(from: buffer)
                written += AVAudioFramePosition(n)
            }
        }
        if let earlier { try copy(earlier) }
        try silence(until: AVAudioFramePosition(offset * rate))
        if let later { try copy(later) }
    }

    /// Seconds of audio in a file, or nil if it can't be read.
    static func seconds(of url: URL) -> Double? {
        (try? AVAudioFile(forReading: url)).map { Double($0.length) / $0.fileFormat.sampleRate }
    }
}
