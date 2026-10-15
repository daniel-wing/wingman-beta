import AVFoundation
import Foundation

/// `Wingman voicerecover <note.md>… [--samples]`: what the voice search would
/// find in older meetings, with its numbers, for checking the rules on real
/// meetings. Read-only: nothing is kept or learned. Speakers are printed by
/// number and kind, not name. With `--samples`, each offered voice's sample is
/// written to a temporary folder to listen to (delete it after).
enum VoiceRecoverTool {
    static func run(_ args: [String]) async -> Int32 {
        let samples = args.contains("--samples")
        let notes = args.filter { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        guard !notes.isEmpty else {
            print("Usage: Wingman voicerecover <meeting note .md>… [--samples]")
            return 2
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wingman-voice-samples-\(UUID().uuidString.prefix(8))")
        var offered = 0, total = 0
        for (n, url) in notes.enumerated() {
            guard let data = try? Data(contentsOf: url), let audio = VoiceRecovery.callAudio(for: url) else {
                print("meeting \(n + 1): no note or no call audio (-them.m4a / -them.wav)")
                continue
            }
            let note = MeetingNote.parse(data)
            let you: Set<String> = ["Me", UserDefaults.standard.string(forKey: "myName") ?? ""]
            let clock = Date()
            do {
                let separated = try await SpeakerSeparation().separate(audio)
                let seconds = Date().timeIntervalSince(clock)
                let length = (try? AVAudioFile(forReading: audio)).map { Double($0.length) / $0.fileFormat.sampleRate } ?? 0
                let spans = VoiceRecovery.spans(note, isMe: you.contains)
                let assigned = VoiceRecovery.assign(turns: separated.turns, spans: spans, you: you)
                print(String(format: "meeting %d: %.0f min of call audio, %d voices found, search took %.0f s (%.0f s per hour)",
                             n + 1, length / 60, separated.voiceprints.count, seconds, length > 0 ? seconds / length * 3600 : 0))
                for (i, speaker) in note.speakers.enumerated() {
                    guard let (outcome, x) = assigned[speaker] else { continue }
                    total += 1
                    let kind = MeetingNote.kind(of: speaker)
                    var line = String(format: "  speaker %d (%@): estimated %.0f s, found %.0f s, best voice %.0f s = %.0f%% of theirs, they have %.0f%% of it → ",
                                      i + 1, "\(kind)", x.estimated, x.found, x.best, x.bestShare * 100, x.exclusivity * 100)
                    if case .offer(_, let sample) = outcome {
                        offered += 1
                        line += "OFFER"
                        if samples {
                            let file = folder.appendingPathComponent("meeting\(n + 1)-speaker\(i + 1).wav")
                            if (try? writeSample(audio, sample, to: file)) != nil { line += " (sample: \(file.lastPathComponent))" }
                        }
                    } else {
                        line += outcome.reason
                    }
                    print(line)
                }
            } catch {
                print("meeting \(n + 1): speaker separation failed (\(error.localizedDescription))")
            }
        }
        print("\(offered) of \(total) speakers would be offered")
        if samples, offered > 0 { print("samples in \(folder.path) — delete the folder when done") }
        return 0
    }

    private static func writeSample(_ audio: URL, _ span: VoiceRecovery.Span, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let input = try AVAudioFile(forReading: audio)
        let format = input.processingFormat
        input.framePosition = AVAudioFramePosition(span.start * format.sampleRate)
        let frames = AVAudioFrameCount(span.duration * format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        try input.read(into: buffer, frameCount: frames)
        let output = try AVAudioFile(forWriting: file, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        try output.write(from: buffer)
    }
}
