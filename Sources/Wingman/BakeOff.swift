import AVFoundation
import FluidAudio
import Foundation
import WhisperKit

/// Runs the same recording through each speech engine and writes a
/// side-by-side Markdown report, so the default engine can be chosen on real
/// meeting audio instead of published benchmarks.
enum BakeOff {
    static let allEngines = ["parakeet-ultra", "parakeet-v3", "whisper", "apple"]

    static func run(_ args: [String]) async -> Int32 {
        guard let path = args.first(where: { !$0.hasPrefix("--") && !isOptionValue($0, in: args) }) else {
            print("""
            Usage: Wingman bakeoff <audio file> [--lang es-ES] [--engines \(allEngines.joined(separator: ","))]

              --lang     Language for Apple's engine, which can't detect it (default: your system language).
                         Parakeet and Whisper detect the language themselves.
              --engines  Comma-separated subset to run (default: all).
            """)
            return 2
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let locale = value(of: "--lang", in: args).map(Locale.init(identifier:)) ?? Locale.current
        let engines = value(of: "--engines", in: args)?.split(separator: ",").map(String.init) ?? allEngines

        let samples: [Float]
        do {
            samples = try AudioConverter().resampleAudioFile(url)
        } catch {
            print("Can't read \(url.path): \(error.localizedDescription)")
            return 1
        }
        let seconds = Double(samples.count) / Resampler.sampleRate
        print(String(format: "Audio: %@ (%.0f s)\n", url.lastPathComponent, seconds))

        var report = "# Speech engine bake-off\n\n**File:** \(url.lastPathComponent)  \n"
        report += String(format: "**Length:** %.0f s  \n**Apple language:** %@\n", seconds, locale.identifier)

        for name in engines {
            print("▶︎ \(name)… (first run downloads the model)")
            let clock = ContinuousClock()
            let began = clock.now
            var text: String
            do {
                text = try await transcribe(name, samples: samples, url: url, locale: locale)
            } catch {
                text = "⚠️ Failed: \(error.localizedDescription)"
            }
            let elapsed = began.duration(to: clock.now)
            let secs = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let timing = String(format: "%.1f s (%.0f× real time, includes model loading)", secs, seconds / max(secs, 0.001))
            print("  \(timing)\n  \(text)\n")
            report += "\n## \(name)\n\n_\(timing)_\n\n\(text)\n"
        }

        let reportURL = url.deletingPathExtension().appendingPathExtension("bakeoff.md")
        do {
            try report.write(to: reportURL, atomically: true, encoding: .utf8)
            print("Report saved: \(reportURL.path)")
        } catch {
            print("Couldn't save the report: \(error.localizedDescription)")
        }
        return 0
    }

    private static func transcribe(_ engine: String, samples: [Float], url: URL, locale: Locale) async throws -> String {
        switch engine {
        case "parakeet-ultra":
            return try await parakeet(.ultra, samples)
        case "parakeet-v3":
            return try await parakeet(.v3, samples)
        case "whisper":
            return try await whisper(samples)
        case "apple":
            return try await AppleSpeech.transcribe(url, locale: locale)
        default:
            throw BakeOffError("Unknown engine \(engine). Choose from: \(allEngines.joined(separator: ", "))")
        }
    }

    private static func parakeet(_ version: AsrModelVersion, _ samples: [Float]) async throws -> String {
        let models = try await AsrModels.downloadAndLoad(version: version)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        var state = TdtDecoderState.make()
        return try await manager.transcribe(samples, decoderState: &state).text
    }

    private static func whisper(_ samples: [Float]) async throws -> String {
        let pipe = try await WhisperKit(WhisperKitConfig(model: "large-v3-v20240930_turbo"))
        let options = DecodingOptions(language: nil, detectLanguage: true)
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func value(of option: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: option), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static func isOptionValue(_ arg: String, in args: [String]) -> Bool {
        guard let i = args.firstIndex(of: arg), i > 0 else { return false }
        return args[i - 1].hasPrefix("--")
    }
}

struct BakeOffError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
