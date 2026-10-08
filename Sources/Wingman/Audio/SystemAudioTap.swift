import AVFoundation
import AudioToolbox
import CoreAudio

/// Captures everything the Mac plays (the other side of a call) using a
/// Core Audio process tap, delivered as 16 kHz mono samples.
///
/// macOS asks for "System Audio Recording" permission the first time. If it is
/// denied, the tap still runs but delivers silence.
///
/// The sample rate can change underneath a running capture — notably when a
/// call app starts using AirPods' microphone and macOS switches them to
/// headset mode at a lower rate. Assuming the old rate plays the call back at
/// the wrong speed (which transcribes as gibberish), so the capture restarts
/// itself whenever the rate changes, and also if the amount of audio arriving
/// stops matching the rate it was set up for. It also restarts if audio stops
/// arriving altogether, or a restart fails, until `stop` is called.
final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "wingman.systemaudio", qos: .userInitiated)
    /// Diagnostics: how many audio callbacks arrived, and how many produced samples.
    private let counters = TapCounters()
    var callbacks: Int { counters.callbacks }
    var converted: Int { counters.converted }
    private(set) var formatDescription = ""
    /// How many times the capture restarted itself.
    private(set) var restarts = 0

    private var onSamples: (([Float]) -> Void)?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    /// Between `start` and `stop`: keep capture alive.
    private var active = false
    private var restartPending = false
    private var restartDeferred = false
    private var recentRestarts: [Date] = []
    /// A rate measured from the incoming audio, used when the device reports a wrong one.
    private var measuredRate: Double?
    private var rateCheck: RateCheck?
    /// The rate audio was last measured arriving at, for diagnostics.
    var lastMeasuredRate: Double { rateCheck?.lastMeasured ?? 0 }
    private var watchdog: DispatchSourceTimer?
    private var lastCallbacks = 0
    private var lastProgress = ProcessInfo.processInfo.systemUptime

    func start(onSamples: @escaping ([Float]) -> Void) throws {
        self.onSamples = onSamples
        active = true
        do {
            try startCapture(onSamples: onSamples)
        } catch {
            stop()
            throw error
        }
        startWatchdog()
    }

    func stop() {
        active = false
        watchdog?.cancel()
        watchdog = nil
        teardown()
    }

    private func startCapture(onSamples: @escaping ([Float]) -> Void) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Wingman"
        description.muteBehavior = .unmuted
        description.isPrivate = true

        try check(AudioHardwareCreateProcessTap(description, &tapID), "Creating the system audio tap")

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd), "Reading the tap format")
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32
        else { throw CaptureError.unsupportedFormat("system audio (\(asbd))") }
        let channels = Int(max(asbd.mChannelsPerFrame, 1))

        let (outputID, outputUID) = try Self.defaultOutputDevice()
        // The output device clocks the capture device. But a headset (AirPods,
        // a USB headset) is one device with a microphone too, and as part of the
        // capture device its mic would be captured as well — your voice mixed
        // into "Them", and AirPods pushed into headset mode. With such an output,
        // only the tap goes in.
        let tapOnly = Self.forceTapOnly || Self.hasInput(outputID)
        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Wingman Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        if !tapOnly {
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                  "Creating the capture device")

        // Audio arrives at the capture device's running rate, which can differ
        // from the tap's nominal format (e.g. AirPods in headset mode).
        let reported = Self.nominalSampleRate(of: aggregateID) ?? Self.nominalSampleRate(of: outputID) ?? asbd.mSampleRate
        let rate = measuredRate ?? reported
        guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let resampler = Resampler(from: monoFormat)
        else { throw CaptureError.unsupportedFormat("system audio at \(rate) Hz") }

        formatDescription = "\(rate) Hz, \(channels) ch (tap \(asbd.mSampleRate) Hz)"
        Log.write("system audio start: using \(Int(rate)) Hz — tap \(Int(asbd.mSampleRate)) Hz, capture device \(Self.nominalSampleRate(of: aggregateID).map { "\(Int($0))" } ?? "?") Hz, output \(Self.nominalSampleRate(of: outputID).map { "\(Int($0))" } ?? "?") Hz (\(AudioDeviceMonitor.defaultOutputName() ?? "?")), \(channels) ch\(measuredRate != nil ? ", from measurement" : "")\(tapOnly ? (Self.forceTapOnly ? ", tap only (forced)" : ", tap only (output has a mic)") : "")")
        watchForRateChanges(tap: tapID, aggregate: aggregateID, output: outputID)
        let rateCheck = RateCheck(expectedRate: rate, tolerance: measuredRate == nil ? 0.15 : 0.05)
        self.rateCheck = rateCheck
        let counters = self.counters
        let layoutLogged = LockedFlag()
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, inputData, _, _, _ in
            counters.countCallback()
            if !layoutLogged.value {
                layoutLogged.set(true)
                // What the capture device delivers: only the tap's buffer is expected.
                let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
                Log.write("system audio buffers: " + buffers.map { "\($0.mNumberChannels) ch" }.joined(separator: ", "))
            }
            let mono = Self.downmix(inputData, channels: channels)
            if let actual = rateCheck.add(frames: mono.count) { self?.scheduleRestart(measured: actual) }
            guard !mono.isEmpty,
                  let buffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(mono.count))
            else { return }
            mono.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: mono.count) }
            buffer.frameLength = AVAudioFrameCount(mono.count)
            let samples = resampler.convert(buffer)
            if !samples.isEmpty {
                counters.countConverted()
                onSamples(samples)
            }
        }, "Attaching to the capture device")
        try check(AudioDeviceStart(aggregateID, procID), "Starting system audio capture")
    }

    /// Removes whatever `startCapture` created, also after it failed partway.
    private func teardown() {
        for (object, address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
        }
        listeners = []
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
            procID = nil
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - Rate changes

    private func watchForRateChanges(tap: AudioObjectID, aggregate: AudioObjectID, output: AudioObjectID) {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleRestart() }
        let watched: [(AudioObjectID, AudioObjectPropertySelector)] = [
            (tap, kAudioTapPropertyFormat),
            (aggregate, kAudioDevicePropertyNominalSampleRate),
            (output, kAudioDevicePropertyNominalSampleRate),
        ]
        for (object, selector) in watched {
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            if AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr {
                listeners.append((object, address, block))
            }
        }
    }

    /// Rebuilds the capture with the current format. Runs on the main queue,
    /// a moment after the change so macOS has finished switching.
    private func scheduleRestart(measured: Double? = nil, why: String = "a rate change") {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, !self.restartPending, let onSamples = self.onSamples else { return }
            // Never loop: at most 3 restarts in 20 seconds. A restart over the
            // limit is postponed, not dropped, so capture can't stay broken.
            let now = Date()
            self.recentRestarts = self.recentRestarts.filter { now.timeIntervalSince($0) < 20 }
            if let oldest = self.recentRestarts.first, self.recentRestarts.count >= 3 {
                guard !self.restartDeferred else { return }
                self.restartDeferred = true
                let wait = 20 - now.timeIntervalSince(oldest) + 0.1
                Log.write("postponing system audio restart by \(Int(wait.rounded(.up))) s (3 in the last 20 s)")
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                    self?.restartDeferred = false
                    self?.scheduleRestart(measured: measured, why: why)
                }
                return
            }
            self.recentRestarts.append(now)
            // A reported change: trust the device again. A measured mismatch: use the measurement.
            self.measuredRate = measured
            self.restartPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self else { return }
                self.restartPending = false
                guard self.active else { return }
                self.teardown()
                self.restarts += 1
                do {
                    try self.startCapture(onSamples: onSamples)
                    Log.write("system audio restarted after \(why) (\(self.formatDescription))")
                } catch {
                    // Leave nothing half-built; the watchdog tries again shortly.
                    self.teardown()
                    Log.write("system audio restart failed: \(Log.describe(error))")
                }
                self.lastProgress = ProcessInfo.processInfo.systemUptime
            }
        }
    }

    /// Restarts capture when audio stops arriving for 3 s while something is
    /// playing — a capture device that died with an output change, or a restart
    /// that failed. With the built-in speakers the IO callback runs even in
    /// silence, but with AirPods it pauses whenever nothing plays, so silence
    /// alone isn't a failure. A tap that hasn't delivered anything yet is left
    /// to the recorder's start-up check, which handles the permission prompt.
    private func startWatchdog() {
        watchdog?.cancel()
        lastCallbacks = counters.callbacks
        lastProgress = ProcessInfo.processInfo.systemUptime
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.active, !self.restartPending, !self.restartDeferred else { return }
            let count = self.counters.callbacks
            let now = ProcessInfo.processInfo.systemUptime
            if count != self.lastCallbacks {
                self.lastCallbacks = count
                self.lastProgress = now
            } else if count > 0, now - self.lastProgress > 3 {
                self.lastProgress = now
                guard !CallDetector.processesPlayingAudio().isEmpty else { return }
                Log.write("system audio stopped arriving; restarting capture")
                // Keep a measured rate: the device may still report a wrong one.
                self.scheduleRestart(measured: self.measuredRate, why: "audio stopped arriving")
            }
        }
        timer.resume()
        watchdog = timer
    }

    /// Diagnostics: leave the output device out even when it has no mic.
    nonisolated(unsafe) static var forceTapOnly = false

    /// Whether a device has input streams — a microphone, as on AirPods or a headset.
    private static func hasInput(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private static func nominalSampleRate(of device: AudioObjectID) -> Double? {
        guard device != kAudioObjectUnknown else { return nil }
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }
        return rate
    }

    /// Averages all channels of a Float32 buffer list into one, whether the
    /// device delivers them interleaved in one buffer or one buffer per channel.
    private static func downmix(_ list: UnsafePointer<AudioBufferList>, channels: Int) -> [Float] {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        var mono: [Float] = []
        var sources = 0
        for buffer in buffers {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let stride = Int(max(buffer.mNumberChannels, 1))
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * stride)
            if mono.isEmpty { mono = [Float](repeating: 0, count: frames) }
            let count = min(frames, mono.count)
            for frame in 0..<count {
                var sum: Float = 0
                for channel in 0..<stride { sum += data[frame * stride + channel] }
                mono[frame] += sum
            }
            sources += stride
        }
        if sources > 1 {
            let scale = 1 / Float(sources)
            for i in mono.indices { mono[i] *= scale }
        }
        return mono
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw CaptureError.coreAudio(step, status) }
    }

    private static func defaultOutputDevice() throws -> (AudioObjectID, String) {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr else { throw CaptureError.coreAudio("Finding the output device", status) }

        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard status == noErr, let uid else { throw CaptureError.coreAudio("Reading the output device", status) }
        return (deviceID, uid.takeRetainedValue() as String)
    }
}

/// Callback counts, written on the audio queue and read on the main one.
final class TapCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCallbacks = 0
    private var storedConverted = 0

    var callbacks: Int { lock.withLock { storedCallbacks } }
    var converted: Int { lock.withLock { storedConverted } }
    func countCallback() { lock.withLock { storedCallbacks += 1 } }
    func countConverted() { lock.withLock { storedConverted += 1 } }
}

/// Compares how much audio arrives with the rate the capture was set up for.
/// A large, sustained mismatch means the rate changed without notice. Pauses
/// don't count — AirPods stop sending audio while nothing plays — and two
/// checks in a row must agree before the device's own rate is overridden.
final class RateCheck: @unchecked Sendable {
    private let expectedRate: Double
    private let tolerance: Double
    private let now: () -> UInt64
    private var frames = 0
    private var windowStart: UInt64 = 0
    private var lastCallback: UInt64 = 0
    private var flagged = false
    private var checks = 0
    /// The previous window's mismatch, snapped: a second one that agrees confirms it.
    private var candidate: Double?
    /// Most recent measurement, for diagnostics.
    private(set) var lastMeasured: Double = 0
    private static let window: Double = 3       // seconds per check
    /// Longer than any normal gap between callbacks: audio stopped, not slowed.
    private static let pause: Double = 0.5

    /// `tolerance` is the mismatch that counts: 15 % against the device's own
    /// rate; tighter after a restart at a measured rate, so a wrong measurement
    /// gets corrected.
    init(expectedRate: Double, tolerance: Double = 0.15,
         now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.expectedRate = expectedRate
        self.tolerance = tolerance
        self.now = now
    }

    private static let commonRates: [Double] = [8_000, 11_025, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 88_200, 96_000]

    /// Called on the audio queue. Returns the actual rate (snapped to a common
    /// one) once, when the incoming audio clearly doesn't match the expected rate.
    func add(frames count: Int) -> Double? {
        let now = self.now()
        defer { lastCallback = now }
        // First callback, or the first after a pause: start measuring afresh.
        if windowStart == 0 || Double(now - lastCallback) / 1e9 > Self.pause {
            windowStart = now
            frames = 0
            return nil
        }
        frames += count
        let elapsed = Double(now - windowStart) / 1e9
        guard elapsed >= Self.window else { return nil }
        let measured = Double(frames) / elapsed
        frames = 0
        windowStart = now
        checks += 1
        if checks <= 2 { Log.write("system audio arriving at ~\(Int(measured)) Hz (expected \(Int(expectedRate)) Hz)") }
        lastMeasured = measured
        guard !flagged, abs(measured / expectedRate - 1) > tolerance else {
            candidate = nil
            return nil
        }
        let snapped = Self.commonRates.min { abs($0 - measured) < abs($1 - measured) } ?? measured
        guard candidate == snapped else {
            candidate = snapped  // wait for the next window to agree
            return nil
        }
        flagged = true
        Log.write("system audio arriving at ~\(Int(measured)) Hz, expected \(Int(expectedRate)) Hz; switching to \(Int(snapped)) Hz")
        return snapped
    }
}
