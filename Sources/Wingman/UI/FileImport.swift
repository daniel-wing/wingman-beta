import AppKit
import UniformTypeIdentifiers

/// Picks a recording or video file and transcribes it.
@MainActor
enum FileImport {
    static let types: [UTType] = [.audio, .movie, .mpeg4Movie, .quickTimeMovie, .mpeg4Audio, .mp3, .wav]

    static func choose(for recorder: Recorder) {
        let panel = NSOpenPanel()
        panel.title = "Transcribe a Recording"
        panel.message = "Choose a meeting recording or video. Wingman reads its audio on this Mac."
        panel.prompt = "Transcribe"
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await recorder.transcribeFile(url) }
    }
}
