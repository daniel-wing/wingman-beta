import FluidAudio
import Foundation

/// `Wingman transcribe <file>` transcribes a recording through the app's
/// recorder and prints the result (the note is saved like any meeting).
/// `--segments` only prints the speech segments the voice detector finds and
/// each one's text (nothing is saved); `--whole` adds the whole file
/// transcribed in one piece, to compare.
enum TranscribeTool {
    @MainActor
    static func run(_ args: [String]) async -> Int32 {
        guard let path = args.first else {
            print("Usage: Wingman transcribe <recording or video file>")
            return 2
        }
        if args.contains("--segments") { return await segments(path) }
        let recorder = Recorder()
        let started = Date()
        await recorder.transcribeFile(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        if let error = recorder.lastError {
            print(error)
            return 1
        }
        guard let meeting = recorder.focus else { return 1 }
        await meeting.waitUntilDone()
        print(String(format: "Done in %.1f s", Date().timeIntervalSince(started)))
        for line in meeting.lines where line.isFinal {
            print("[\(Recorder.timestamp(line.start))] \(meeting.displayName(line)): \(line.text)")
        }
        print("Note: \(meeting.currentNote?.path ?? "none")")
        return 0
    }

    @MainActor
    private static func segments(_ path: String) async -> Int32 {
        do {
            let engine = ParakeetEngine()
            try await engine.load()
            let vad = try await VadManager()
            let samples = try await AudioExtractor.samples(from: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            var config = VadSegmentationConfig.default
            config.minSilenceDuration = 0.5
            let rate = Int(Resampler.sampleRate)
            print(String(format: "%.1f s of audio", Double(samples.count) / Double(rate)))
            if CommandLine.arguments.contains("--whole") {
                print("whole file: " + (try await engine.transcribeScored(samples).text))
            }
            for segment in try await vad.segmentSpeech(samples, config: config) {
                let from = max(0, segment.startSample(sampleRate: rate))
                let to = min(samples.count, segment.endSample(sampleRate: rate))
                let text = to > from ? try await engine.transcribeScored(Array(samples[from..<to])).text : ""
                print(String(format: "%6.2f–%6.2f (%4.1f s)  ", segment.startTime, segment.endTime, segment.endTime - segment.startTime) + text)
            }
            return 0
        } catch {
            print("Failed: \(error.localizedDescription)")
            return 1
        }
    }
}
