import AVFoundation
import FluidAudio
import Foundation

/// Splits the call-audio track into individual voices after a meeting, so
/// "Them" lines can become "Them 1", "Them 2", … Runs fully on this Mac.
actor SpeakerSeparation {
    struct Turn: Sendable {
        let speaker: String
        let start: TimeInterval
        let end: TimeInterval
    }

    private var manager: OfflineDiarizerManager?

    /// Downloads the voice models on first use (~30 MB, cached afterwards).
    func load() async throws {
        guard manager == nil else { return }
        let manager = OfflineDiarizerManager(config: .default)
        try await manager.prepareModels()
        self.manager = manager
    }

    func turns(in audio: URL) async throws -> [Turn] {
        try await separate(audio).turns
    }

    /// Who spoke when, plus a voiceprint (speaker embedding) for each voice.
    func separate(_ audio: URL) async throws -> (turns: [Turn], voiceprints: [String: [Float]]) {
        try await load()
        guard let manager else { return ([], [:]) }
        // Stretches of exact digital silence (the call track has many: nothing
        // playing, gaps filled while reconnecting) make FluidAudio's separator
        // find extra speakers (FluidAudio issue #981). A copy with a trace of
        // inaudible noise in those stretches avoids it; the saved track is untouched.
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("wingman-separate-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: copy) }
        var source = audio
        do {
            try Self.writeDithered(audio, to: copy)
            source = copy
        } catch {
            Log.write("couldn't prepare audio for speaker separation, using it as is: \(error)")
        }
        let result = try await manager.process(source)
        let turns = result.segments.map {
            Turn(speaker: $0.speakerId, start: TimeInterval($0.startTimeSeconds), end: TimeInterval($0.endTimeSeconds))
        }
        return (turns, result.speakerDatabase ?? [:])
    }

    /// Copies `input` to `output`, replacing exact zeros with noise around
    /// -70 dBFS. Reads in pieces, so long meetings don't need much memory.
    nonisolated static func writeDithered(_ input: URL, to output: URL) throws {
        let reader = try AVAudioFile(forReading: input)
        let format = reader.processingFormat
        let writer = try AVAudioFile(forWriting: output, settings: reader.fileFormat.settings,
                                     commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        guard format.commonFormat == .pcmFormatFloat32,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1 << 18)
        else { throw CaptureError.unsupportedFormat("speaker separation (\(format))") }
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        while reader.framePosition < reader.length {
            try reader.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            let count = Int(buffer.frameLength) * (format.isInterleaved ? Int(format.channelCount) : 1)
            for channel in 0..<(format.isInterleaved ? 1 : Int(format.channelCount)) {
                ditherZeros(UnsafeMutableBufferPointer(start: channels[channel], count: count), state: &state)
            }
            try writer.write(from: buffer)
        }
    }

    /// Replaces exact zeros with tiny pseudo-random values (±0.0003); leaves
    /// everything else alone. Deterministic, so results are repeatable.
    nonisolated static func ditherZeros(_ samples: UnsafeMutableBufferPointer<Float>, state: inout UInt64) {
        for i in samples.indices where samples[i] == 0 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Float(state >> 40) / Float(1 << 24)  // 0..<1
            samples[i] = (unit * 2 - 1) * 3e-4
        }
    }

    /// The speaker IDs in `turns`, in the order they first speak — the same
    /// order `assign` numbers them (Them 1, Them 2, …).
    nonisolated static func speakerOrder(_ turns: [Turn]) -> [String] {
        var order: [String] = []
        for turn in turns.sorted(by: { $0.start < $1.start }) where !order.contains(turn.speaker) {
            order.append(turn.speaker)
        }
        return order
    }

    /// Gives each line the voice it overlaps most. Voices are numbered in the
    /// order they first speak. Returns nil numbers when only one voice was found,
    /// since "Them 1" alone adds nothing; `ids` maps each number back to its voice.
    nonisolated static func assign(_ turns: [Turn], to lines: [(start: TimeInterval, end: TimeInterval)]) -> [Int?] {
        numbered(turns, lines).voices
    }

    nonisolated static func numbered(
        _ turns: [Turn], _ lines: [(start: TimeInterval, end: TimeInterval)]
    ) -> (voices: [Int?], ids: [Int: String]) {
        var best: [String?] = lines.map { line in
            var overlap: [String: TimeInterval] = [:]
            for turn in turns {
                let shared = min(line.end, turn.end) - max(line.start, turn.start)
                if shared > 0 { overlap[turn.speaker, default: 0] += shared }
            }
            return overlap.max { $0.value < $1.value }?.key
        }
        // A line with no overlap (e.g. a cough the separator ignored) takes the nearest turn's voice.
        for i in best.indices where best[i] == nil {
            let mid = (lines[i].start + lines[i].end) / 2
            best[i] = turns.min { abs(($0.start + $0.end) / 2 - mid) < abs(($1.start + $1.end) / 2 - mid) }?.speaker
        }

        var numbers: [String: Int] = [:]
        for id in best.compactMap({ $0 }) where numbers[id] == nil {
            numbers[id] = numbers.count + 1
        }
        guard numbers.count > 1 else { return (lines.map { _ in nil }, [:]) }
        let ids = Dictionary(uniqueKeysWithValues: numbers.map { ($0.value, $0.key) })
        return (best.map { $0.flatMap { numbers[$0] } }, ids)
    }
}
