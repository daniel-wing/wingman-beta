import AVFoundation
import Foundation

/// Reads the audio from any recording or video file macOS can open (Teams or
/// Zoom exports, voice memos, MP4, MOV, M4A, MP3, WAV…) as 16 kHz mono samples.
enum AudioExtractor {
    static func samples(from url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioExtractorError("\(url.lastPathComponent) has no audio.")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Resampler.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        guard reader.canAdd(output) else { throw AudioExtractorError("Can't read the audio in \(url.lastPathComponent).") }
        reader.add(output)
        guard reader.startReading() else {
            throw AudioExtractorError(reader.error?.localizedDescription ?? "Can't read \(url.lastPathComponent).")
        }

        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            samples += chunk
        }
        if reader.status == .failed {
            throw AudioExtractorError(reader.error?.localizedDescription ?? "Reading \(url.lastPathComponent) failed.")
        }
        return samples
    }

    /// Writes samples to a 16 kHz mono WAV file.
    static func write(_ samples: [Float], to url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: Resampler.outputFormat.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 16_000 * 60
        for start in stride(from: 0, to: samples.count, by: chunk) {
            let count = min(chunk, samples.count - start)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: Resampler.outputFormat, frameCapacity: AVAudioFrameCount(count)) else { continue }
            samples.withUnsafeBufferPointer {
                buffer.floatChannelData![0].update(from: $0.baseAddress! + start, count: count)
            }
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
        }
    }
}

struct AudioExtractorError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
