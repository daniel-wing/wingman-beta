import AVFoundation
import Foundation
import Testing
@testable import Wingman

/// A clock the test moves by hand.
private final class FakeClock: @unchecked Sendable {
    var now: TimeInterval = 1000
}

/// Collects what an aligner delivers.
private final class Sink: @unchecked Sendable {
    var pieces: [[Float]] = []
    var total: Int { pieces.reduce(0) { $0 + $1.count } }
}

@Suite struct ClockAlignerTests {
    private let rate = 16_000

    @Test func steadyAudioIsPassedThrough() {
        let clock = FakeClock(), sink = Sink()
        let aligner = ClockAligner(clock: { clock.now }) { sink.pieces.append($0) }
        for _ in 0..<5 {
            clock.now += 1
            aligner.push([Float](repeating: 0.1, count: rate))
        }
        #expect(sink.total == 5 * rate)
    }

    @Test func gapIsFilledWithSilenceInOneSecondPieces() {
        let clock = FakeClock(), sink = Sink()
        let aligner = ClockAligner(clock: { clock.now }) { sink.pieces.append($0) }
        clock.now += 5  // capture paused for ~4 s
        aligner.push([Float](repeating: 0.1, count: rate))
        #expect(sink.total == 5 * rate)
        #expect(sink.pieces.allSatisfy { $0.count <= rate })
        #expect(sink.pieces.last?.first == 0.1)
    }

    @Test func hugeGapIsCappedAndNotRefilled() {
        let clock = FakeClock(), sink = Sink()
        let aligner = ClockAligner(clock: { clock.now }) { sink.pieces.append($0) }
        clock.now += 3 * 3600
        aligner.push([Float](repeating: 0.1, count: rate))
        #expect(sink.total == ClockAligner.maxGap + rate)
        // Afterwards the skipped time doesn't come back as more silence.
        sink.pieces = []
        clock.now += 1
        aligner.push([Float](repeating: 0.1, count: rate))
        #expect(sink.total == rate)
    }

    @Test func smallJitterIsLeftAlone() {
        let clock = FakeClock(), sink = Sink()
        let aligner = ClockAligner(clock: { clock.now }) { sink.pieces.append($0) }
        clock.now += 1.3  // 0.3 s late: under the half-second tolerance
        aligner.push([Float](repeating: 0.1, count: rate))
        #expect(sink.total == rate)
    }
}

@Suite struct RateCheckTests {
    /// Feeds `seconds` of audio arriving at `actual` Hz in 10 ms callbacks.
    private func run(expected: Double, actual: Double, seconds: Double) -> [Double] {
        var nanos: UInt64 = 1_000_000_000
        let check = RateCheck(expectedRate: expected) { nanos }
        var flagged: [Double] = []
        let frames = Int(actual / 100)
        for _ in 0..<Int(seconds * 100) {
            nanos += 10_000_000
            if let rate = check.add(frames: frames) { flagged.append(rate) }
        }
        return flagged
    }

    @Test func matchingRateIsQuiet() {
        #expect(run(expected: 48_000, actual: 48_000, seconds: 10).isEmpty)
    }

    @Test func mismatchIsReportedOnceSnappedToACommonRate() {
        // AirPods switching to headset mode: audio arrives at 24 kHz, not 48.
        #expect(run(expected: 48_000, actual: 23_900, seconds: 10) == [24_000])
    }

    /// Feeds 10 ms callbacks at `rate`, with pauses: (after seconds, for seconds).
    private func runWithPauses(expected: Double, rate: Double, seconds: Double, pauses: [(Double, Double)],
                               tolerance: Double = 0.15) -> [Double] {
        var nanos: UInt64 = 1_000_000_000
        let check = RateCheck(expectedRate: expected, tolerance: tolerance) { nanos }
        var flagged: [Double] = []
        var t = 0.0
        while t < seconds {
            for (at, length) in pauses where t < at && t + 0.01 >= at { nanos += UInt64(length * 1e9) }
            nanos += 10_000_000
            t += 0.01
            if let found = check.add(frames: Int(rate / 100)) { flagged.append(found) }
        }
        return flagged
    }

    @Test func pausesInTheAudioArentARateChange() {
        // The review's case: 10 s with no callbacks (AirPods, nothing playing).
        #expect(runWithPauses(expected: 48_000, rate: 48_000, seconds: 20, pauses: [(2, 10)]).isEmpty)
        // A short stall late in a window, which locked in 44.1 kHz before.
        #expect(runWithPauses(expected: 48_000, rate: 48_000, seconds: 20, pauses: [(2.7, 0.6), (8.5, 0.6)]).isEmpty)
    }

    @Test func aWrongMeasuredRateGetsCorrected() {
        // Restarted at a measured 44.1 kHz while the audio really is 48 kHz.
        #expect(runWithPauses(expected: 44_100, rate: 48_000, seconds: 10, pauses: [], tolerance: 0.05) == [48_000])
    }
}

@Suite struct ResamplerTests {
    /// The built-in mic can appear as a raw 3-channel array while a call app
    /// uses it; a plain downmix of that layout comes out silent.
    @Test func rawMicArrayKeepsItsSignal() throws {
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 3))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: false,
                                   channelLayout: layout)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        buffer.frameLength = 4800
        for channel in 0..<3 {
            for i in 0..<4800 { buffer.floatChannelData![channel][i] = 0.5 * sin(Float(i) * 0.05) }
        }
        let resampler = try #require(Resampler(from: format, channels: .average))
        let out = resampler.convert(buffer)
        #expect(out.count > 1000)
        #expect((out.map(abs).max() ?? 0) > 0.4)
    }
}

@Suite struct ResamplerChannelTests {
    private func buffer(channels: Int, signalOn: Set<Int>) throws -> AVAudioPCMBuffer {
        let format: AVAudioFormat
        if channels == 2 {
            format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        } else {
            let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)))
            format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: false, channelLayout: layout)
        }
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        buffer.frameLength = 4800
        for channel in 0..<channels {
            for i in 0..<4800 {
                buffer.floatChannelData![channel][i] = signalOn.contains(channel) ? 0.5 * sin(Float(i) * 0.05) : 0
            }
        }
        return buffer
    }

    private func peak(_ samples: [Float]) -> Float { samples.map(abs).max() ?? 0 }

    @Test func interfaceMicOnSecondInputIsHeard() throws {
        // A 2-input USB interface with the mic plugged into input 2.
        let input = try buffer(channels: 2, signalOn: [1])
        let resampler = try #require(Resampler(from: input.format, channels: .average))
        #expect(peak(resampler.convert(input)) > 0.2)
    }

    @Test func fourChannelInterfaceIsHeard() throws {
        let input = try buffer(channels: 4, signalOn: [2])
        let resampler = try #require(Resampler(from: input.format, channels: .average))
        #expect(peak(resampler.convert(input)) > 0.1)
    }

    @Test func voiceProcessedInputUsesChannelZero() throws {
        let input = try buffer(channels: 3, signalOn: [0])
        let resampler = try #require(Resampler(from: input.format, channels: .first))
        #expect(peak(resampler.convert(input)) > 0.4)
    }
}
