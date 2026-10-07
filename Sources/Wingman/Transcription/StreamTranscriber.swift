import AVFoundation
import FluidAudio
import Foundation

enum Speaker: String, Codable {
    case me = "Me"
    case them = "Them"
}

struct TranscriptEvent: Sendable {
    let utteranceID: UUID
    let speaker: Speaker
    /// Seconds since the recording started.
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let isFinal: Bool
    /// The model's confidence in `text`, 0…1.
    var confidence: Float = 1
}

/// Turns one audio stream (mic or system audio) into transcript lines.
///
/// Silero voice-activity detection splits the stream into utterances. While
/// someone is talking, the utterance so far is re-transcribed about once a
/// second so the window can show live (partial) text; when they pause, the
/// whole utterance is transcribed once more and emitted as final.
actor StreamTranscriber {
    private static let chunkSize = 4096                    // 256 ms, Silero's native hop
    private static let partialInterval = 16_000            // re-transcribe every ~1 s of new speech
    /// Force a break in very long monologues, while the utterance still fits the
    /// model's single 15 s window (it can grow by one chunk past this). Longer
    /// audio takes FluidAudio's two-window merge, which can repeat words.
    static let maxUtterance = ASRConstants.maxModelSamples - chunkSize
    private static let vadConfig: VadSegmentationConfig = {
        var config = VadSegmentationConfig.default
        config.minSilenceDuration = 0.5                    // a half-second pause starts a new line
        return config
    }()
    private static let prerollChunks = 2                   // keep ~0.5 s before speech starts

    let speaker: Speaker
    private let engine: ParakeetEngine
    private let vad: VadManager
    private let emit: @Sendable (TranscriptEvent) async -> Void
    private let audioFile: AVAudioFile?

    private var vadState = VadStreamState.initial()
    private var pending: [Float] = []
    private var consumed = 0
    private var preroll: [[Float]] = []

    private var inSpeech = false
    private var utterance: [Float] = []
    private var utteranceStart = 0
    private var utteranceID = UUID()
    private var lastPartialLength = 0
    /// The newest audio, held back from the file so `redactRecent` can still erase it.
    private var unwritten: [Float] = []
    private static let holdBack = 8_000  // 0.5 s

    /// Loudest sample seen; lets the UI warn when system audio is silent (permission missing).
    private(set) var peak: Float = 0

    init(
        speaker: Speaker,
        engine: ParakeetEngine,
        vad: VadManager,
        audioFileURL: URL?,
        emit: @escaping @Sendable (TranscriptEvent) async -> Void
    ) {
        self.speaker = speaker
        self.engine = engine
        self.vad = vad
        self.emit = emit
        self.audioFile = audioFileURL.flatMap {
            try? AVAudioFile(forWriting: $0, settings: Resampler.outputFormat.settings,
                             commonFormat: .pcmFormatFloat32, interleaved: false)
        }
    }

    /// What a stream is fed: audio, or a request to erase the latest audio.
    /// Both travel through one queue, so an erase applies to exactly the audio
    /// that arrived before it.
    enum Feed: Sendable {
        case samples([Float])
        case redact(seconds: Double)
    }

    func take(_ item: Feed) async {
        switch item {
        case .samples(let samples): await feed(samples)
        case .redact(let seconds): redactRecent(seconds: seconds)
        }
    }

    func feed(_ samples: [Float]) async {
        unwritten += samples
        if unwritten.count > Self.holdBack {
            write(Array(unwritten.prefix(unwritten.count - Self.holdBack)))
            unwritten.removeFirst(unwritten.count - Self.holdBack)
        }
        for sample in samples where abs(sample) > peak { peak = abs(sample) }
        pending += samples
        // Walk through with an offset and drop the processed part once: removing
        // each chunk from the front would copy a large backlog over and over.
        var offset = 0
        while pending.count - offset >= Self.chunkSize {
            let chunk = Array(pending[offset..<(offset + Self.chunkSize)])
            offset += Self.chunkSize
            await process(chunk)
        }
        pending.removeFirst(offset)
    }

    /// Silences the most recent `seconds` of audio that hasn't been transcribed
    /// or saved yet — used when the user turns out to have muted a moment ago.
    /// Send it as a `Feed` so it can't overtake audio still on its way.
    func redactRecent(seconds: Double) {
        var remaining = Int(seconds * Resampler.sampleRate)
        func zeroTail(_ buffer: inout [Float]) {
            let n = min(remaining, buffer.count)
            guard n > 0 else { return }
            for i in (buffer.count - n)..<buffer.count { buffer[i] = 0 }
        }
        let budget = remaining
        zeroTail(&unwritten)
        // `pending` and `utterance` hold the same recent audio in transcription order:
        // newest in `pending`, older in the utterance (or the pre-roll when not speaking).
        zeroTail(&pending)
        remaining = max(0, budget - pending.count)
        if inSpeech {
            zeroTail(&utterance)
        } else {
            for i in preroll.indices.reversed() where remaining > 0 {
                zeroTail(&preroll[i])
                remaining = max(0, remaining - preroll[i].count)
            }
        }
    }

    /// Flushes whatever is still being said when recording stops.
    func finish() async {
        write(unwritten)
        unwritten.removeAll()
        if inSpeech {
            utterance += pending
            pending.removeAll()
            await finalizeUtterance()
            inSpeech = false
        }
    }

    private func process(_ chunk: [Float]) async {
        var ended = false
        if let result = try? await vad.processStreamingChunk(chunk, state: vadState, config: Self.vadConfig) {
            vadState = result.state
            switch result.event?.kind {
            case .speechStart where !inSpeech:
                beginUtterance()
            case .speechEnd where inSpeech:
                ended = true
            default:
                break
            }
        }

        if inSpeech {
            utterance += chunk
            if ended {
                await finalizeUtterance()
                inSpeech = false
            } else if utterance.count >= Self.maxUtterance {
                await finalizeUtterance()
                beginUtterance(withPreroll: false, at: consumed + chunk.count)
            } else if utterance.count - lastPartialLength >= Self.partialInterval {
                lastPartialLength = utterance.count
                await transcribeCurrent(isFinal: false)
            }
        }

        consumed += chunk.count
        preroll.append(chunk)
        if preroll.count > Self.prerollChunks { preroll.removeFirst() }
    }

    private func beginUtterance(withPreroll: Bool = true, at position: Int? = nil) {
        inSpeech = true
        utteranceID = UUID()
        lastPartialLength = 0
        if withPreroll {
            utterance = preroll.flatMap { $0 }
            utteranceStart = consumed - utterance.count
        } else {
            utterance = []
            utteranceStart = position ?? consumed
        }
    }

    private func finalizeUtterance() async {
        await transcribeCurrent(isFinal: true)
        utterance.removeAll()
    }

    private func transcribeCurrent(isFinal: Bool) async {
        guard !utterance.isEmpty else { return }
        let (text, confidence) = (try? await engine.transcribeScored(utterance)) ?? ("", 0)
        let start = Double(utteranceStart) / Resampler.sampleRate
        let end = start + Double(utterance.count) / Resampler.sampleRate
        await emit(TranscriptEvent(
            utteranceID: utteranceID, speaker: speaker, start: start, end: end, text: text, isFinal: isFinal,
            confidence: confidence))
    }

    private func write(_ samples: [Float]) {
        guard let audioFile, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: Resampler.outputFormat,
                                            frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try? audioFile.write(from: buffer)
    }
}
