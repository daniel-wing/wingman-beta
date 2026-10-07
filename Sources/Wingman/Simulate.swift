import FluidAudio
import Foundation

/// `Wingman simulate <audio file> [--speakers] [--languages en,es] [--vtt out.vtt]` streams a
/// recording through the live pipeline in real-time-sized chunks and prints
/// what the transcript window would show. With `--speakers` it then runs the
/// same speaker separation as the app does after a meeting.
enum Simulate {
    static func run(_ args: [String]) async -> Int32 {
        guard let path = args.first(where: { !$0.hasPrefix("--") && !$0.hasSuffix(".vtt") && !$0.contains(",") && SpokenLanguage(rawValue: $0) == nil }) else {
            print("Usage: Wingman simulate <audio file> [--speakers] [--languages en,es] [--vtt out.vtt]")
            return 2
        }
        let url = URL(fileURLWithPath: path)
        do {
            let samples = try AudioConverter().resampleAudioFile(url)
            let engine = ParakeetEngine()
            try await engine.load()
            let collector = Collector()
            let stream = StreamTranscriber(
                speaker: .them, engine: engine, vad: try await VadManager(), audioFileURL: nil
            ) { event in
                if event.isFinal {
                    await collector.add(event)
                } else {
                    print("partial [\(Recorder.timestamp(event.start))] \(event.text)")
                }
            }
            // Same cadence as the audio callbacks: ~100 ms buffers.
            for start in stride(from: 0, to: samples.count, by: 1600) {
                await stream.feed(Array(samples[start..<min(start + 1600, samples.count)]))
            }
            await stream.finish()

            var lines = await collector.lines
            if args.contains("--speakers") {
                let turns = try await SpeakerSeparation().turns(in: url)
                let voices = SpeakerSeparation.assign(turns, to: lines.map { ($0.start, $0.end) })
                for i in lines.indices { lines[i].voice = voices[i] }
            }
            if let i = args.firstIndex(of: "--languages"), i + 1 < args.count {
                let enabled = Set(args[i + 1].split(separator: ",").compactMap { SpokenLanguage(rawValue: String($0)) })
                for fix in await TranscriptCheck.fixes(for: lines, audio: [.them: url], enabled: enabled) {
                    print("rechecked [\(Recorder.timestamp(lines[fix.index].start))] \"\(lines[fix.index].text)\" → (\(fix.language.rawValue)) \"\(fix.text)\"")
                    lines[fix.index].text = fix.text
                }
            }
            print("")
            for line in lines {
                print("[\(Recorder.timestamp(line.start))] \(line.label): \(line.text)\(line.isUnclear ? "  (unclear)" : "")")
            }
            if let i = args.firstIndex(of: "--vtt"), i + 1 < args.count {
                try SubtitleExport.render(lines, as: .vtt)
                    .write(toFile: args[i + 1], atomically: true, encoding: .utf8)
            }
            return 0
        } catch {
            print("Failed: \(error.localizedDescription)")
            return 1
        }
    }
}

private actor Collector {
    var lines: [TranscriptLine] = []

    func add(_ event: TranscriptEvent) {
        guard !event.text.isEmpty else { return }
        lines.append(TranscriptLine(id: event.utteranceID, speaker: event.speaker, start: event.start,
                                    end: event.end, text: event.text, isFinal: true, confidence: event.confidence))
    }
}
