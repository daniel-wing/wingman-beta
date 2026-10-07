import FluidAudio
import Foundation
import NaturalLanguage

/// The pass that runs after a meeting, before the note and exports are
/// written. Parakeet can't be restricted to particular languages, so lines
/// that came out in a language the user hasn't enabled (typically Spanish
/// heard as Portuguese) are re-transcribed by Apple's engine locked to the
/// closest enabled language.
enum TranscriptCheck {
    struct Fix {
        let index: Int
        let text: String
        let language: SpokenLanguage
    }

    /// Lines shorter than this are skipped: language detection needs a few words.
    static let minimumWords = 3

    static func fixes(
        for lines: [TranscriptLine], audio: [Speaker: URL], enabled: Set<SpokenLanguage>
    ) async -> [Fix] {
        guard !enabled.isEmpty, enabled.count < SpokenLanguage.allCases.count else { return [] }

        var suspects: [(index: Int, target: SpokenLanguage)] = []
        for (index, line) in lines.enumerated() where line.isFinal {
            guard let target = misdetected(line.text, enabled: enabled) else { continue }
            suspects.append((index, target))
        }
        guard !suspects.isEmpty else { return [] }

        var samples: [Speaker: [Float]] = [:]
        for (speaker, url) in audio {
            samples[speaker] = try? AudioConverter().resampleAudioFile(url)
        }

        var fixes: [Fix] = []
        for suspect in suspects {
            let line = lines[suspect.index]
            guard let track = samples[line.speaker] else { continue }
            let from = max(0, Int(line.start * Resampler.sampleRate))
            let to = min(track.count, Int(line.end * Resampler.sampleRate))
            guard to > from else { continue }
            guard let text = try? await AppleSpeech.transcribe(Array(track[from..<to]), locale: suspect.target.locale),
                  !text.isEmpty
            else { continue }
            fixes.append(Fix(index: suspect.index, text: text, language: suspect.target))
        }
        return fixes
    }

    /// If `text` reads as a supported language the user hasn't enabled,
    /// returns the enabled language it most resembles.
    static func misdetected(_ text: String, enabled: Set<SpokenLanguage>) -> SpokenLanguage? {
        guard text.split(whereSeparator: \.isWhitespace).count >= minimumWords else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = SpokenLanguage.allCases.map(\.nlLanguage)
        recognizer.processString(text)
        guard let detected = recognizer.dominantLanguage,
              let language = SpokenLanguage(rawValue: detected.rawValue),
              !enabled.contains(language)
        else { return nil }

        recognizer.reset()
        recognizer.languageConstraints = enabled.map(\.nlLanguage)
        recognizer.processString(text)
        return recognizer.dominantLanguage.flatMap { SpokenLanguage(rawValue: $0.rawValue) }
    }
}
