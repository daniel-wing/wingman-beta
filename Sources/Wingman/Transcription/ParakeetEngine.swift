import FluidAudio
import Foundation

/// Local Parakeet speech recognition (25 European languages, detected
/// automatically), running on the Apple Neural Engine via FluidAudio. Live
/// transcription uses Ultra (moondream's post-training of v3): on the user's
/// real Spanish/English calls v3 wrote ~1 in 10 Spanish sentences as made-up
/// English, Ultra none, keeping English terms.
actor ParakeetEngine {
    enum Version: String, CaseIterable {
        case ultra, v3

        var fluid: AsrModelVersion {
            switch self {
            case .ultra: return .ultra
            case .v3: return .v3
            }
        }
    }

    private let version: Version
    private var manager: AsrManager?

    init(version: Version = .ultra) {
        self.version = version
    }

    private var downloading: Task<Void, Error>?
    private var loading: Task<AsrManager, Error>?

    /// Whether the model is on this Mac already.
    nonisolated var isDownloaded: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version.fluid), version: version.fluid)
    }

    /// Downloads the model if it isn't on this Mac yet, without loading it.
    /// Callers at the same time share one download.
    func download() async throws {
        guard !isDownloaded else { return }
        if let downloading { return try await downloading.value }
        let task = Task { _ = try await AsrModels.download(version: version.fluid) }
        downloading = task
        defer { downloading = nil }
        try await task.value
    }

    /// Downloads the model on first use (cached afterwards) and loads it.
    func load() async throws {
        guard manager == nil else { return }
        if let loading {
            manager = try await loading.value
            return
        }
        let task = Task { () -> AsrManager in
            try await download()
            let models = try await AsrModels.downloadAndLoad(version: version.fluid)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
        loading = task
        defer { loading = nil }
        manager = try await task.value
    }

    /// Restricts output to the Latin alphabet. Parakeet occasionally renders
    /// short or unclear Spanish/Portuguese as Cyrillic; FluidAudio's language
    /// hint only filters by alphabet, so any Latin-script language selects it
    /// without biasing which of English/Spanish/Portuguese is recognized.
    var latinOnly = true

    func setLatinOnly(_ value: Bool) { latinOnly = value }

    func transcribe(_ samples: [Float]) async throws -> String {
        try await transcribeScored(samples).text
    }

    /// Text plus the model's confidence (0…1) in it.
    func transcribeScored(_ samples: [Float]) async throws -> (text: String, confidence: Float) {
        try await load()
        guard let manager else { return ("", 0) }
        // The model needs at least one second of audio; pad short clips with silence.
        var audio = samples
        let minimum = Int(Resampler.sampleRate)
        if audio.count < minimum {
            audio += [Float](repeating: 0, count: minimum - audio.count)
        }
        var state = TdtDecoderState.make()
        let result = try await manager.transcribe(audio, decoderState: &state, language: latinOnly ? .spanish : nil)
        return (result.text.trimmingCharacters(in: .whitespacesAndNewlines), result.confidence)
    }
}
