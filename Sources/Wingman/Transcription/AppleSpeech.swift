import AVFoundation
import Foundation
import Speech

/// Apple's on-device speech engine (macOS 26). Unlike Parakeet it must be told
/// the language, which is exactly what makes it useful for re-checking a line
/// that Parakeet heard in the wrong language.
enum AppleSpeech {
    static func transcribe(_ url: URL, locale requested: Locale) async throws -> String {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw AppleSpeechError("Apple's engine doesn't support \(requested.identifier)")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        // Downloads the language model the first time a language is used.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let collector = Task {
            var parts: [String] = []
            for try await result in transcriber.results where result.isFinal {
                parts.append(String(result.text.characters))
            }
            return parts.joined(separator: " ")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)
        _ = try await analyzer.analyzeSequence(from: file)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Transcribes 16 kHz mono samples (via a short temporary file).
    static func transcribe(_ samples: [Float], locale: Locale) async throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wingman-clip-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: Resampler.outputFormat.settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: Resampler.outputFormat,
                                                frameCapacity: AVAudioFrameCount(samples.count))
            else { return "" }
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            try file.write(from: buffer)
        }  // closes the file before reading it back
        return try await transcribe(url, locale: locale)
    }
}

struct AppleSpeechError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
