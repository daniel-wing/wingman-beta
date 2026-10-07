import CoreAudio
import Foundation

/// Calls back when the default microphone or speakers change — AirPods
/// connecting, headphones unplugged, a different output picked in Control
/// Center. Bursts of changes (macOS often switches input and output a few
/// hundred milliseconds apart) are collapsed into one callback.
final class AudioDeviceMonitor {
    private static let selectors = [
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDefaultSystemOutputDevice,
    ]

    private let queue = DispatchQueue(label: "wingman.devicemonitor")
    private let onChange: () -> Void
    private var listener: AudioObjectPropertyListenerBlock?
    private var pending: DispatchWorkItem?

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        queue.setSpecific(key: Self.onQueue, value: true)
        Self.useOwnNotificationThread()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.schedule() }
        listener = block
        for selector in Self.selectors {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        }
    }

    deinit { stop() }

    /// Core Audio delivers property notifications through the main run loop
    /// unless told otherwise, so command-line runs (which don't run one) never
    /// hear about device changes. A NULL run loop makes it use its own thread.
    private static let useOwnNotificationThread: () -> Void = {
        var runLoop: CFRunLoop? = nil
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyRunLoop,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        withUnsafeMutablePointer(to: &runLoop) { pointer in
            _ = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                           UInt32(MemoryLayout<CFRunLoop?>.size), pointer)
        }
        return {}
    }()

    func stop() {
        guard let listener else { return }
        for selector in Self.selectors {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        }
        self.listener = nil
        // `pending` belongs to the queue the listener runs on (which may be
        // this one, if the last reference went away inside a callback).
        let cancel = { [self] in
            pending?.cancel()
            pending = nil
        }
        if DispatchQueue.getSpecific(key: Self.onQueue) == true { cancel() } else { queue.sync(execute: cancel) }
    }

    private static let onQueue = DispatchSpecificKey<Bool>()

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async { self?.onChange() }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    /// Name of the current default output, e.g. "AirPods Pro".
    static func defaultOutputName() -> String? {
        deviceName(kAudioHardwarePropertyDefaultOutputDevice)
    }

    static func defaultInputName() -> String? {
        deviceName(kAudioHardwarePropertyDefaultInputDevice)
    }

    private static func deviceName(_ selector: AudioObjectPropertySelector) -> String? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = address(selector)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return nil }
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioObjectPropertyName
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }
}

/// Keeps a stream's sample count in step with the clock. If capture pauses —
/// while reconnecting after a device change — the gap is filled with silence,
/// so later lines keep correct timestamps and the mic and call-audio tracks
/// stay aligned for speaker separation and echo filtering.
///
/// The clock is time awake (`systemUptime`), not wall-clock time: while the
/// Mac sleeps nothing is captured on either track, so there's nothing to fill.
final class ClockAligner: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: () -> TimeInterval
    private let start: TimeInterval
    private var delivered = 0
    /// Time no longer filled in, after a gap longer than `maxGap`.
    private var skipped = 0
    private let sink: ([Float]) -> Void
    /// Gaps shorter than this are normal buffering jitter and left alone.
    private let tolerance = Int(Resampler.sampleRate / 2)
    /// A longer gap is filled only up to this much, so memory stays bounded
    /// (an hour of silence is ~230 MB while it's processed). Beyond it the track
    /// would fall out of step with the other one, but with sleep not counted
    /// and dead capture restarted within seconds, that takes an hour-long outage.
    static let maxGap = Int(Resampler.sampleRate) * 3600
    private static let piece = Int(Resampler.sampleRate)

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sink: @escaping ([Float]) -> Void) {
        self.clock = clock
        self.start = clock()
        self.sink = sink
    }

    func push(_ samples: [Float]) {
        lock.lock()
        let expected = Int((clock() - start) * Resampler.sampleRate) - skipped
        var gap = expected - samples.count - delivered
        if gap > Self.maxGap {
            Log.write("audio gap of \(gap / Self.piece) s; filling only \(Self.maxGap / Self.piece) s")
            skipped += gap - Self.maxGap
            gap = Self.maxGap
        }
        let padding = gap > tolerance ? gap : 0
        delivered += padding + samples.count
        lock.unlock()
        // Silence in one-second pieces: one huge buffer would stall transcription.
        var left = padding
        while left > 0 {
            let n = min(left, Self.piece)
            sink([Float](repeating: 0, count: n))
            left -= n
        }
        sink(samples)
    }
}
