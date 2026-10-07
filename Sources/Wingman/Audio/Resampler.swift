import AVFoundation

/// Converts arbitrary PCM buffers to 16 kHz mono Float32, the format every
/// speech engine here expects.
final class Resampler {
    static let sampleRate: Double = 16_000
    static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    /// How several channels become one: AVAudioConverter's downmix, only the
    /// first channel (voice-processed mic input, where only channel 0 is the
    /// cleaned signal), or the average of all channels. The converter's downmix
    /// turns discrete layouts — a raw mic array, many audio interfaces — into
    /// silence, so microphones use the average.
    enum Channels { case downmix, first, average }
    private let channels: Channels
    private let channelCount: Int

    convenience init?(from format: AVAudioFormat, firstChannelOnly: Bool = false) {
        self.init(from: format, channels: firstChannelOnly ? .first : .downmix)
    }

    init?(from format: AVAudioFormat, channels: Channels) {
        // Only deinterleaved Float32 (what AVAudioEngine delivers) is mixed by hand.
        let byHand = format.channelCount > 1 && format.commonFormat == .pcmFormatFloat32 && !format.isInterleaved
        self.channels = byHand ? channels : .downmix
        channelCount = Int(format.channelCount)
        let source: AVAudioFormat
        if self.channels != .downmix {
            guard let mono = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false)
            else { return nil }
            source = mono
        } else {
            source = format
        }
        guard let converter = AVAudioConverter(from: source, to: Self.outputFormat) else { return nil }
        converter.downmix = true
        self.converter = converter
        self.inputFormat = source
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
        var input = buffer
        if channels != .downmix {
            guard let mono = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: buffer.frameLength),
                  let src = buffer.floatChannelData, let dst = mono.floatChannelData?[0]
            else { return [] }
            let frames = Int(buffer.frameLength)
            let used = channels == .first ? 1 : min(channelCount, Int(buffer.format.channelCount))
            dst.update(from: src[0], count: frames)
            if used > 1 {
                for channel in 1..<used {
                    for i in 0..<frames { dst[i] += src[channel][i] }
                }
                let scale = 1 / Float(used)
                for i in 0..<frames { dst[i] *= scale }
            }
            mono.frameLength = buffer.frameLength
            input = mono
        }

        let ratio = Self.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: capacity) else { return [] }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, let data = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
    }
}
