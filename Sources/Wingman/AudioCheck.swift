import Foundation

/// `Wingman audiocheck [--voice-processing] [--seconds N] [--mic-only] [--timeline]` starts
/// the microphone and system-audio capture for a few seconds and reports what
/// each one heard. Diagnoses device problems without going through the UI.
/// `--timeline` prints the microphone level every second, e.g. to see whether
/// another app starting its own capture changes what this one hears.
/// `--voice-processing` opens the mic the way Wingman no longer does — it makes
/// a call app sharing the mic go silent, so never use it during a call.
/// `--no-mic` checks call audio only; `--tap-only` builds the capture device
/// without the output device (as used with headsets), to compare.
enum AudioCheck {
    static func run(_ args: [String]) async -> Int32 {
        let echo = args.contains("--voice-processing")
        let seconds = args.firstIndex(of: "--seconds").flatMap { Double(args[safe: $0 + 1] ?? "") } ?? 5
        Log.write("audiocheck: output \(AudioDeviceMonitor.defaultOutputName() ?? "?"), input \(AudioDeviceMonitor.defaultInputName() ?? "?")")

        let micMeter = Meter()
        let tapMeter = Meter()
        let mic = MicCapture()
        let tap = SystemAudioTap()
        let micOnly = args.contains("--mic-only")
        SystemAudioTap.forceTapOnly = args.contains("--tap-only")

        if !args.contains("--no-mic") {
            do {
                let mode = try mic.start(echoCancellation: echo, onSamples: micMeter.add)
                print("Microphone: started (\(mode.rawValue))")
            } catch {
                print("Microphone: FAILED — \(error.localizedDescription)")
            }
        }
        if !micOnly {
            do {
                try tap.start(onSamples: tapMeter.add)
                print("System audio: started")
            } catch {
                print("System audio: FAILED — \(error.localizedDescription)")
            }
        }

        if args.contains("--timeline") {
            let start = Date()
            var shown = 0
            while Date().timeIntervalSince(start) < seconds {
                try? await Task.sleep(for: .milliseconds(250))
                for (second, rms) in micMeter.seconds.dropFirst(shown) {
                    print(String(format: "mic %6.2f s  rms %.4f  at %@", Double(second), rms,
                                 Date().formatted(date: .omitted, time: .standard)))
                    shown += 1
                }
            }
        } else {
            try? await Task.sleep(for: .seconds(seconds))
        }
        mic.stop()
        tap.stop()
        print("Microphone heard   \(micMeter.summary)")
        print("System audio heard \(tapMeter.summary)")
        print("System audio format \(tap.formatDescription); callbacks \(tap.callbacks), converted \(tap.converted), restarts \(tap.restarts), last measured \(Int(tap.lastMeasuredRate)) Hz")
        if let i = args.firstIndex(of: "--save"), i + 1 < args.count {
            try? AudioExtractor.write(tapMeter.samples, to: URL(fileURLWithPath: args[i + 1]))
            print("Saved call audio to \(args[i + 1])")
        }
        return 0
    }
}

private final class Meter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var peak: Float = 0
    private var sumSquares: Double = 0
    private var kept: [Float] = []

    var samples: [Float] {
        lock.lock()
        defer { lock.unlock() }
        return kept
    }

    func add(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        kept += samples
        count += samples.count
        for s in samples {
            peak = max(peak, abs(s))
            sumSquares += Double(s * s)
        }
    }

    /// RMS of each completed second of audio, in order.
    var seconds: [(Int, Double)] {
        lock.lock()
        defer { lock.unlock() }
        return stride(from: 0, to: kept.count - 15_999, by: 16_000).map { start in
            let slice = kept[start..<(start + 16_000)]
            let sum = slice.reduce(0.0) { $0 + Double($1 * $1) }
            return (start / 16_000, (sum / 16_000).squareRoot())
        }
    }

    var summary: String {
        lock.lock()
        defer { lock.unlock() }
        let rms = count > 0 ? (sumSquares / Double(count)).squareRoot() : 0
        return String(format: "%.1f s of audio, peak %.3f, rms %.4f", Double(count) / 16_000, peak, rms)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
