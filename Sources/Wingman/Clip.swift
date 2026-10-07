import FluidAudio
import Foundation

/// `Wingman clip <audio file> <start s> <end s>` re-transcribes one stretch of
/// a recording with and without the Latin-alphabet restriction.
enum Clip {
    static func run(_ args: [String]) async -> Int32 {
        guard args.count >= 3, let start = Double(args[1]), let end = Double(args[2]), end > start else {
            print("Usage: Wingman clip <audio file> <start seconds> <end seconds>")
            return 2
        }
        do {
            let samples = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: args[0]))
            let from = max(0, Int(start * Resampler.sampleRate)), to = min(samples.count, Int(end * Resampler.sampleRate))
            let clip = Array(samples[from..<to])
            let engine = ParakeetEngine()
            for latin in [false, true] {
                await engine.setLatinOnly(latin)
                let r = try await engine.transcribeScored(clip)
                print(String(format: "%@ (confidence %.2f): %@", latin ? "Latin only" : "Any alphabet", r.confidence, r.text))
            }
            return 0
        } catch {
            print("Failed: \(error.localizedDescription)")
            return 1
        }
    }
}
