import FluidAudio
import Foundation
import NaturalLanguage
import WhisperKit

/// `Wingman langtest <audio file> [--from S] [--to S] [--max N] [--out report.md]`
/// splits a recording into utterances (as the live transcript does) and runs
/// each through the candidate engines — Parakeet v3 and Ultra (auto language), Whisper
/// (auto, forced Spanish, forced English) and Apple (Spanish, English) — plus
/// Whisper's spoken-language guess, side by side. For choosing how to lock the
/// live transcript to one language and how to review languages afterwards.
enum LangTest {
    static func run(_ args: [String]) async -> Int32 {
        guard let path = args.first(where: { !$0.hasPrefix("--") && !isValue($0, args) }) else {
            print("Usage: Wingman langtest <audio file> [--from S] [--to S] [--max N] [--out report.md]")
            return 2
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let from = value("--from", args).flatMap(Double.init) ?? 0
        let to = value("--to", args).flatMap(Double.init) ?? .infinity
        let maxCount = value("--max", args).flatMap(Int.init) ?? 60
        let out = value("--out", args).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? url.deletingPathExtension().appendingPathExtension("langtest.md")
        do {
            let samples = try AudioConverter().resampleAudioFile(url)
            let rate = Int(Resampler.sampleRate)
            var config = VadSegmentationConfig.default
            config.minSilenceDuration = 0.5
            let segments = try await VadManager().segmentSpeech(samples, config: config)
                .filter { $0.startTime >= from && $0.startTime < to && $0.endTime - $0.startTime >= 0.8 }
                .prefix(maxCount)
            print("\(segments.count) utterances from \(url.lastPathComponent)")

            let parakeet = ParakeetEngine(version: .v3)
            try await parakeet.load()
            let ultra = ParakeetEngine(version: .ultra)
            try await ultra.load()
            // --parakeet-only: just v3 vs Ultra (fast).
            let quick = args.contains("--parakeet-only")
            let whisper = quick ? nil : try await WhisperKit(WhisperKitConfig(model: "large-v3-v20240930_turbo"))
            var time: [String: Double] = [:]
            func timed<T>(_ name: String, _ work: () async throws -> T) async rethrows -> T {
                let start = Date()
                defer { time[name, default: 0] += Date().timeIntervalSince(start) }
                return try await work()
            }

            var report = "# Language test: \(url.lastPathComponent)\n"
            var audioSeconds = 0.0
            for segment in segments {
                let clip = Array(samples[max(0, segment.startSample(sampleRate: rate))..<min(samples.count, segment.endSample(sampleRate: rate))])
                audioSeconds += Double(clip.count) / Resampler.sampleRate
                let pk: (text: String, confidence: Float) = (try? await timed("parakeet") { try await parakeet.transcribeScored(clip) }) ?? ("", 0)
                let ul: (text: String, confidence: Float) = (try? await timed("ultra") { try await ultra.transcribeScored(clip) }) ?? ("", 0)
                var lid: (language: String, langProbs: [String: Float])?
                var wAuto = "", wEs = "", wEn = "", aEs = "", aEn = ""
                if let whisper {
                    lid = try? await timed("whisper-lid") { try await whisper.detectLangauge(audioArray: clip) }
                    func whisperText(_ language: String?) async -> String {
                        let options = DecodingOptions(language: language, detectLanguage: language == nil)
                        let results = (try? await whisper.transcribe(audioArray: clip, decodeOptions: options)) ?? []
                        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    wAuto = await timed("whisper-auto") { await whisperText(nil) }
                    wEs = await timed("whisper-es") { await whisperText("es") }
                    wEn = await timed("whisper-en") { await whisperText("en") }
                    aEs = (try? await timed("apple-es") { try await AppleSpeech.transcribe(clip, locale: Locale(identifier: "es-MX")) }) ?? "⚠️"
                    aEn = (try? await timed("apple-en") { try await AppleSpeech.transcribe(clip, locale: Locale(identifier: "en-US")) }) ?? "⚠️"
                }

                let es = lid?.langProbs["es"].map { exp($0) } ?? 0
                let en = lid?.langProbs["en"].map { exp($0) } ?? 0
                report += "\n## [\(Recorder.timestamp(segment.startTime))] \(String(format: "%.1f s", segment.endTime - segment.startTime))\n"
                report += "- **Whisper hears:** \(lid?.language ?? "?") (es \(String(format: "%.2f", es)), en \(String(format: "%.2f", en)))\n"
                report += "- **Parakeet v3** (text looks \(textLanguage(pk.text)), conf \(String(format: "%.2f", pk.confidence))): \(pk.text)\n"
                report += "- **Parakeet Ultra** (text looks \(textLanguage(ul.text)), conf \(String(format: "%.2f", ul.confidence))): \(ul.text)\n"
                report += "- **Whisper auto:** \(wAuto)\n- **Whisper es:** \(wEs)\n- **Whisper en:** \(wEn)\n"
                report += "- **Apple es-MX:** \(aEs)\n- **Apple en-US:** \(aEn)\n"
                print("[\(Recorder.timestamp(segment.startTime))] \(lid?.language ?? "?") | pk: \(pk.text.prefix(70))")
            }
            report += "\n## Speed (\(String(format: "%.0f", audioSeconds)) s of speech)\n"
            for (name, seconds) in time.sorted(by: { $0.key < $1.key }) {
                report += "- \(name): \(String(format: "%.1f s (%.1f× real time)", seconds, audioSeconds / max(seconds, 0.001)))\n"
            }
            try report.write(to: out, atomically: true, encoding: .utf8)
            print("Report: \(out.path)")
            return 0
        } catch {
            print("Failed: \(error.localizedDescription)")
            return 1
        }
    }

    private static func textLanguage(_ text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue ?? "?"
    }

    private static func value(_ option: String, _ args: [String]) -> String? {
        guard let i = args.firstIndex(of: option), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static func isValue(_ arg: String, _ args: [String]) -> Bool {
        guard let i = args.firstIndex(of: arg), i > 0 else { return false }
        return args[i - 1].hasPrefix("--")
    }
}
