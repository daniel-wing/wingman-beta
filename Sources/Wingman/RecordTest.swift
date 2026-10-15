// Registered only in builds with the diagnostic tools (main.swift).
#if !NO_DIAGNOSTICS && !APP_STORE
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
        await recorder.start()
        recorder.current?.meetingName = "recordtest"
        recorder.current?.applyMeetingName()
        if let error = recorder.lastError {
            print("Start failed: \(error)")
            return 1
        }
        print("Recording for \(Int(seconds)) s…")
        // `--join S J`: split S s in as a new call window would, Join with
        // Previous J s later, stop at the end: one note, all the audio.
        if let i = args.firstIndex(of: "--join"), let at = args[safe: i + 1].flatMap(Double.init),
           let back = args[safe: i + 2].flatMap(Double.init) {
            try? await Task.sleep(for: .seconds(at))
            let first = recorder.current
            recorder.splitAsNewCall()
            let second = recorder.current
            let secondNote = second?.currentNote
            print("Split at \(Int(at)) s: new note \(secondNote?.lastPathComponent ?? "?")")
            try? await Task.sleep(for: .seconds(back))
            if let second { recorder.join(second) }
            print("Joined at \(Int(at + back)) s; current is the first note again: \(recorder.current === first)")
            try? await Task.sleep(for: .seconds(seconds - at - back))
            let stopped = await recorder.stop()
            while recorder.busy { try? await Task.sleep(for: .milliseconds(200)) }
            await stopped?.waitUntilDone()
            let note = stopped?.currentNote
            print("Note: \(note?.lastPathComponent ?? "none"), \(stopped?.lines.count ?? 0) lines")
            if let note, let text = try? String(contentsOf: note, encoding: .utf8) {
                print(text.split(separator: "\n").filter { $0.hasPrefix("**Duration:**") }.joined())
            }
            print("Second note still on disk: \(secondNote.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)")
            print("Warning: \(stopped?.warning ?? "none")")
            return 0
        }
        // `--split N`: start a new note N s in, as a new call would.
        if let i = args.firstIndex(of: "--split"), let at = args[safe: i + 1].flatMap(Double.init) {
            try? await Task.sleep(for: .seconds(at))
            let first = recorder.current
            recorder.splitNow()
            print("Split at \(Int(at)) s: new note \(recorder.current?.currentNote?.lastPathComponent ?? "?")")
            try? await Task.sleep(for: .seconds(seconds - at))
            let notice = recorder.current?.notice
            let second = await recorder.stop()
            for meeting in [first, second].compactMap({ $0 }) {
                await meeting.waitUntilDone()
                print("— \(meeting.currentNote?.lastPathComponent ?? "?"): \(meeting.lines.count) lines")
                for line in meeting.lines where line.isFinal {
                    print("  [\(Recorder.timestamp(line.start))] \(meeting.displayName(line)): \(line.text)")
                }
            }
            print("Notice: \(notice ?? "none")")
            return 0
        }
        try? await Task.sleep(for: .seconds(seconds))
        let notice = recorder.current?.notice ?? recorder.notice
        let meeting = await recorder.stop()
        await meeting?.waitUntilDone()
        print("Notice: \(notice ?? "none")")
        print("Warning: \(meeting?.warning ?? recorder.warning ?? "none")")
        for line in meeting?.lines ?? [] where line.isFinal {
            print("[\(Recorder.timestamp(line.start))] \(meeting!.displayName(line)): \(line.text)")
        }
        print("Note: \(meeting?.currentNote?.path ?? "none")")
        return 0
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
#endif
