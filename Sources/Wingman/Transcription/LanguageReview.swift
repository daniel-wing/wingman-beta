import FluidAudio
import Foundation
import WhisperKit

/// The after-meeting language review. The live engine (Parakeet) picks the
/// language on its own and is right almost always, but now and then it writes
/// a sentence in the wrong language, or garbles a short, unclear one — and
/// it's unsure when it does. Those lines, and any that came out in a language
/// the user hasn't enabled, are transcribed again by Whisper from their
/// audio: Whisper hears which of the enabled languages is spoken (the main
/// language breaks ties) and writes the line in it, English terms included.
/// If Whisper comes back empty or with one of its known made-up phrases, the
/// live text stays.
enum LanguageReview {
    struct Fix {
        let index: Int
        let text: String
        let language: SpokenLanguage
        /// The line had been written in a language the user doesn't speak. Only
        /// then is it trusted afterwards; a re-heard unclear line stays marked
        /// unclear (on garbled audio Whisper's wording changes run to run).
        let languageFixed: Bool
    }

    /// The lines marked *(unclear)*: on real calls Ultra's garbled lines scored
    /// 0.60–0.78 and clear ones 0.95–1.00.
    static let reviewBelow: Float = TranscriptLine.unclearBelow

    /// Whether a line gets a second look. Fillers and one- or two-word lines
    /// are left alone: from a second of audio Whisper does no better ("Em" → "y").
    static func needsReview(_ line: TranscriptLine, enabled: Set<SpokenLanguage>) -> Bool {
        guard line.isFinal else { return false }
        let words = line.text.split(whereSeparator: \.isWhitespace).count
        guard words >= TranscriptCheck.minimumWords else { return false }
        return line.confidence < reviewBelow || TranscriptCheck.misdetected(line.text, enabled: enabled) != nil
    }

    /// The written language of a reviewed line, if it's clearly one the user
    /// doesn't speak — then the review made nothing better (Whisper can write
    /// Italian even when asked for English on garbled audio).
    static func readsAsOtherLanguage(_ text: String, enabled: Set<SpokenLanguage>) -> Bool {
        TranscriptCheck.misdetected(text, enabled: enabled) != nil
    }

    /// The enabled language Whisper finds most likely, from its log-probabilities
    /// by language code; the main language when none of them stands out.
    static func chooseLanguage(_ logProbs: [String: Float], enabled: Set<SpokenLanguage>,
                               main: SpokenLanguage) -> SpokenLanguage {
        let scored = enabled.compactMap { language in logProbs[language.rawValue].map { (language, exp($0)) } }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= 0.2 else { return main }
        return best.0
    }

    /// Whisper's output tidied, or nil when it's empty or not believable for a
    /// clip this long: its known stock phrases, or more text than fits the time.
    static func accept(_ raw: String, seconds: Double) -> String? {
        // Whisper sometimes writes turns as a dialog: "- Sí. - Claro."
        var text = raw.replacingOccurrences(of: #"(^|\s)-\s+"#, with: "$1", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        let stock = ["thank you.", "thanks for watching", "subtítulos", "subtitulos", "amara.org", "gracias por ver"]
        if stock.contains(where: { lower.contains($0) }) && seconds < 4 { return nil }
        if Double(text.count) / max(seconds, 0.5) > 30 { return nil }
        return text
    }

    /// Re-transcribes the lines that need it. Falls back to Apple's engine (only
    /// for lines in a language that isn't enabled) if Whisper can't be loaded.
    static func fixes(
        for lines: [TranscriptLine], audio: [Speaker: URL], enabled: Set<SpokenLanguage>, main: SpokenLanguage,
        status: @escaping @MainActor (String) -> Void
    ) async -> [Fix] {
        let suspects = lines.indices.filter { needsReview(lines[$0], enabled: enabled) }
        guard !suspects.isEmpty else { return [] }
        Log.write("language review: \(suspects.count) of \(lines.filter(\.isFinal).count) lines")

        var samples: [Speaker: [Float]] = [:]
        for (speaker, url) in audio {
            samples[speaker] = try? AudioConverter().resampleAudioFile(url)
        }
        func clip(_ line: TranscriptLine) -> [Float]? {
            guard let track = samples[line.speaker] else { return nil }
            let from = max(0, Int(line.start * Resampler.sampleRate))
            let to = min(track.count, Int(line.end * Resampler.sampleRate))
            return to > from ? Array(track[from..<to]) : nil
        }

        let whisper: WhisperKit
        let began = Date()
        do {
            await status(WhisperModel.isDownloaded
                ? "Reviewing languages…"
                : "Reviewing languages (the first time downloads ~1.5 GB)…")
            whisper = try await WhisperModel.load()
            Log.write(String(format: "language review: Whisper ready in %.1f s", Date().timeIntervalSince(began)))
        } catch {
            Log.write("language review: Whisper unavailable (\(Log.describe(error))); Apple re-check only")
            return await TranscriptCheck.fixes(for: lines, audio: audio, enabled: enabled)
                .map { Fix(index: $0.index, text: $0.text, language: $0.language, languageFixed: true) }
        }

        func transcribe(_ audio: [Float], language: SpokenLanguage?) async -> (text: String, language: String?) {
            let options = DecodingOptions(language: language?.rawValue, usePrefillPrompt: true,
                                          detectLanguage: language == nil, withoutTimestamps: true)
            let results = (try? await whisper.transcribe(audioArray: audio, decodeOptions: options)) ?? []
            return (results.map(\.text).joined(separator: " "), results.first?.language)
        }
        // Prints each change (diagnostics only; the log never gets transcript text).
        // Left out of release builds: the output is meeting content.
        #if !NO_DIAGNOSTICS
        let showChanges = ProcessInfo.processInfo.environment["WINGMAN_REVIEW_DIFF"] != nil
        #endif

        var fixes: [Fix] = []
        for (n, index) in suspects.enumerated() {
            await status("Reviewing languages… \(n + 1) of \(suspects.count)")
            let line = lines[index]
            guard let audio = clip(line) else { continue }
            // One pass that finds the language as it goes; only if that's a language
            // the user doesn't speak, a second one in the likeliest language they do.
            var (raw, heard) = await transcribe(audio, language: nil)
            var language = heard.flatMap(SpokenLanguage.init(rawValue:)).flatMap { enabled.contains($0) ? $0 : nil }
            if language == nil {
                let probs = (try? await whisper.detectLangauge(audioArray: audio))?.langProbs ?? [:]
                let chosen = chooseLanguage(probs, enabled: enabled, main: main)
                (raw, heard) = await transcribe(audio, language: chosen)
                language = chosen
            }
            guard let language, let text = accept(raw, seconds: line.end - line.start),
                  !readsAsOtherLanguage(text, enabled: enabled)
            else { continue }
            if text != line.text {
                let wasOtherLanguage = TranscriptCheck.misdetected(line.text, enabled: enabled) != nil
                fixes.append(Fix(index: index, text: text, language: language, languageFixed: wasOtherLanguage))
                #if !NO_DIAGNOSTICS
                if showChanges {
                    print("[\(Recorder.timestamp(line.start))] (\(String(format: "%.2f", line.confidence))) \(line.text)\n    ⇒ (\(language.rawValue)) \(text)")
                }
                #endif
            }
        }
        Log.write(String(format: "language review: %d lines changed, %.1f s in all", fixes.count, Date().timeIntervalSince(began)))
        return fixes
    }
}

/// Whisper large-v3 turbo for the language review, kept in Wingman's own
/// Application Support folder (WhisperKit's default, ~/Documents, would
/// bring up a Documents permission prompt). Loaded for the review only.
enum WhisperModel {
    static let variant = "large-v3-v20240930_turbo"
    static let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Wingman/huggingface", isDirectory: true)
    private static var folder: URL {
        base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-\(variant)", isDirectory: true)
    }

    static var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("AudioEncoder.mlmodelc").path)
    }

    /// Whisper's word list, fetched separately the first time it loads.
    static var hasTokenizer: Bool {
        FileManager.default.fileExists(
            atPath: base.appendingPathComponent("models/openai/whisper-large-v3/tokenizer.json").path)
    }

    /// GPU rather than the Neural Engine: macOS re-compiled the model for the
    /// Neural Engine on every load (~110 s each time on this M4), which is far
    /// more than the review itself takes. WINGMAN_WHISPER_ANE=1 compares.
    static var compute: ModelComputeOptions {
        if ProcessInfo.processInfo.environment["WINGMAN_WHISPER_ANE"] != nil { return ModelComputeOptions() }
        return ModelComputeOptions(melCompute: .cpuAndGPU, audioEncoderCompute: .cpuAndGPU,
                                   textDecoderCompute: .cpuAndGPU, prefillCompute: .cpuOnly)
    }

    static func load() async throws -> WhisperKit {
        try await WhisperDownload.shared.ensure()
        // A downloaded model loads without going online.
        let config = isDownloaded
            ? WhisperKitConfig(model: variant, downloadBase: base, modelFolder: folder.path, computeOptions: compute,
                               download: false)
            : WhisperKitConfig(model: variant, downloadBase: base, computeOptions: compute)
        return try await WhisperKit(config)
    }
}

/// One Whisper download at a time: the one right after setup and a review
/// that starts meanwhile share it rather than writing the same files twice.
actor WhisperDownload {
    static let shared = WhisperDownload()
    private var task: Task<Void, Error>?

    func ensure() async throws {
        guard !WhisperModel.isDownloaded else { return }
        if let task { return try await task.value }
        let download = Task {
            _ = try await WhisperKit.download(variant: WhisperModel.variant, downloadBase: WhisperModel.base)
        }
        task = download
        defer { task = nil }
        try await download.value
    }
}
