import AVFoundation
import Foundation

/// Mixes the mic and call-audio tracks into one compressed file that plays
/// anywhere (QuickTime, a phone, a browser). The tracks start together and are
/// kept aligned while recording, so mixing is a sample-by-sample sum.
enum AudioMix {
    /// AAC at 16 kHz mono, 32 kbit/s: clear speech at about 0.25 MB per minute.
    static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: Resampler.sampleRate,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
    ]

    static func mix(_ tracks: [URL], to output: URL) throws {
        let inputs = try tracks.map { try AVAudioFile(forReading: $0) }
        guard !inputs.isEmpty else { return }
        let format = Resampler.outputFormat
        guard inputs.allSatisfy({ $0.processingFormat.sampleRate == format.sampleRate && $0.processingFormat.channelCount == 1 })
        else { throw AudioMixError("Tracks aren't 16 kHz mono") }

        try? FileManager.default.removeItem(at: output)
        let out = try AVAudioFile(forWriting: output, settings: settings,
                                  commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk: AVAudioFrameCount = 16_000 * 4
        let buffers = inputs.map { _ in AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)! }
        guard let mixed = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return }
        // Two voices rarely peak at the same instant; a little headroom plus a
        // clamp keeps the sum from clipping without making quiet speech quieter.
        let gain: Float = inputs.count > 1 ? 0.8 : 1

        while true {
            var frames: AVAudioFrameCount = 0
            for (file, buffer) in zip(inputs, buffers) {
                buffer.frameLength = 0
                if file.framePosition < file.length { try file.read(into: buffer, frameCount: chunk) }
                frames = max(frames, buffer.frameLength)
            }
            guard frames > 0 else { break }
            let dst = mixed.floatChannelData![0]
            for i in 0..<Int(frames) {
                var sum: Float = 0
                for buffer in buffers where i < Int(buffer.frameLength) {
                    sum += buffer.floatChannelData![0][i]
                }
                dst[i] = min(1, max(-1, sum * gain))
            }
            mixed.frameLength = frames
            try out.write(from: mixed)
        }
    }
}

struct AudioMixError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
