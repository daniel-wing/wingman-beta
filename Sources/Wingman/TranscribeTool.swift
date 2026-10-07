import Foundation

/// `Wingman transcribe <file>` transcribes a recording through the app's
/// recorder and prints the result (the note is saved like any meeting).
enum TranscribeTool {
    @MainActor
    static func run(_ args: [String]) async -> Int32 {
        guard let path = args.first else {
            print("Usage: Wingman transcribe <recording or video file>")
            return 2
        }
        let recorder = Recorder()
        let started = Date()
        await recorder.transcribeFile(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        if let error = recorder.lastError {
            print(error)
            return 1
        }
        print(String(format: "Done in %.1f s", Date().timeIntervalSince(started)))
        for line in recorder.lines where line.isFinal {
            print("[\(Recorder.timestamp(line.start))] \(recorder.displayName(line)): \(line.text)")
        }
        print("Note: \(recorder.currentNote?.path ?? "none")")
        return 0
    }
}
