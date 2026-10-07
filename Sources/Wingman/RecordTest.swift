import Foundation

/// `Wingman recordtest [seconds]` runs a real recording through the app's
/// recorder for a fixed time, then prints the transcript and any device-change
/// notices. Used to test capture end to end (e.g. switching outputs mid-way)
/// without clicking through the UI. Saves a note like a normal recording.
enum RecordTest {
    @MainActor
    static func run(_ args: [String]) async -> Int32 {
        let seconds = args.first.flatMap(Double.init) ?? 20
        let recorder = Recorder()
        recorder.meetingName = "recordtest"
        await recorder.start()
        if let error = recorder.lastError {
            print("Start failed: \(error)")
            return 1
        }
        print("Recording for \(Int(seconds)) s…")
        try? await Task.sleep(for: .seconds(seconds))
        let notice = recorder.notice
        await recorder.stop()
        print("Notice: \(notice ?? "none")")
        print("Warning: \(recorder.warning ?? "none")")
        for line in recorder.lines where line.isFinal {
            print("[\(Recorder.timestamp(line.start))] \(recorder.displayName(line)): \(line.text)")
        }
        print("Note: \(recorder.currentNote?.path ?? "none")")
        return 0
    }
}
