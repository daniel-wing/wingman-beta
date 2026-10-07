import AVFoundation

/// Captures the default microphone as 16 kHz mono samples.
///
/// Recordings use the plain microphone. `echoCancellation` (Apple's voice
/// processing) is kept only for diagnostics: switching it on reconfigures the
/// built-in mic, and a call app sharing the mic (Teams) then sends silence —
/// the other people stop hearing you. Never use it while a call may be on.
/// Voice processing also refuses to start on some device setups (error
/// -10875), so `start` tries two graph layouts before falling back to plain.
final class MicCapture {
    enum Mode: String {
        case echoCancelled
        case plain
    }

    private var engine = AVAudioEngine()
    private var configObserver: NSObjectProtocol?
    private var startedAt = Date()
    /// Counts engine starts, so a delayed re-check only looks at its own one.
    private var generation = 0
    private var recheckScheduled = false
    /// Called (on the main queue) when macOS reconfigures the mic's audio
    /// device and the engine stops, e.g. AirPods taking over as the input.
    var onInterrupted: (() -> Void)?

    /// Returns whether echo cancellation ended up active.
    @discardableResult
    func start(echoCancellation: Bool, onSamples: @escaping ([Float]) -> Void) throws -> Mode {
        if echoCancellation {
            for routeThroughMixer in [false, true] {
                do {
                    try startEngine(voiceProcessing: true, routeThroughMixer: routeThroughMixer, onSamples: onSamples)
                    return .echoCancelled
                } catch {
                    Log.write("echo-cancelled mic failed (routeThroughMixer=\(routeThroughMixer)): \(error)")
                    reset()
                }
            }
            // Turning voice processing off reconfigures the audio device; give it a moment.
            Thread.sleep(forTimeInterval: 0.3)
        }
        try startEngine(voiceProcessing: false, routeThroughMixer: false, onSamples: onSamples)
        return .plain
    }

    func stop() {
        reset()
    }

    private func startEngine(
        voiceProcessing: Bool, routeThroughMixer: Bool, onSamples: @escaping ([Float]) -> Void
    ) throws {
        let input = engine.inputNode
        if voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
            // Keep other apps (the meeting itself) at full volume.
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(
                enableAdvancedDucking: false, duckingLevel: .min)
        }

        let format = input.outputFormat(forBus: 0)
        // Several channels are averaged by hand: while another app is using the
        // mic, the built-in mic can show up as a 3-channel array, which
        // AVAudioConverter's downmix turns into silence. (Voice processing puts
        // the cleaned signal in channel 0 only.)
        guard format.sampleRate > 0, format.channelCount > 0,
              let resampler = Resampler(from: format, channels: voiceProcessing ? .first : .average)
        else { throw CaptureError.unsupportedFormat("microphone \(format)") }

        if voiceProcessing {
            // Voice processing refuses to initialize (-10875, "client-side input
            // and output formats do not match") unless its output side uses the
            // same format as the mic side.
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
            if routeThroughMixer {
                // Some setups only initialize voice processing when the input is
                // part of a rendering graph; keep it silent.
                engine.connect(input, to: engine.mainMixerNode, format: format)
                engine.mainMixerNode.outputVolume = 0
            }
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            let samples = resampler.convert(buffer)
            if !samples.isEmpty { onSamples(samples) }
        }
        engine.prepare()
        try engine.start()
        Log.write("mic started: \(voiceProcessing ? "voice processing" : "plain"), \(Int(format.sampleRate)) Hz, \(format.channelCount) ch")
        startedAt = Date()
        generation += 1
        recheckScheduled = false
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Starting voice processing reconfigures the device by itself; reacting
            // to that would restart the mic forever. Only a real interruption —
            // the engine actually stopped, after it had settled — counts.
            let settled = Date().timeIntervalSince(self.startedAt) > 2
            let running = self.engine.isRunning
            if settled && !running {
                self.onInterrupted?()
                return
            }
            Log.write("mic configuration change ignored (\(settled ? "engine still running" : "just started"), running \(running))")
            // Stopped while settling: look again once it has settled, so a real
            // interruption in those first seconds isn't missed for good.
            guard !running, !self.recheckScheduled else { return }
            self.recheckScheduled = true
            let current = self.generation
            let wait = max(0.2, 2.2 - Date().timeIntervalSince(self.startedAt))
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self, self.generation == current, self.configObserver != nil else { return }
                self.recheckScheduled = false
                guard !self.engine.isRunning else { return }
                Log.write("mic engine still stopped after settling; reconnecting")
                self.onInterrupted?()
            }
        }
    }

    private func reset() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if engine.inputNode.isVoiceProcessingEnabled {
            try? engine.inputNode.setVoiceProcessingEnabled(false)
        }
        engine = AVAudioEngine()
    }
}

enum CaptureError: LocalizedError {
    case unsupportedFormat(String)
    case coreAudio(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let what): return "Unsupported audio format for \(what)"
        case .coreAudio(let step, let status): return "\(step) failed (Core Audio error \(status))"
        }
    }
}
