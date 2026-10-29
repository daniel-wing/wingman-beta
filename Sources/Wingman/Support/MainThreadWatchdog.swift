import AppKit
import Foundation

/// Notices when the main thread stops responding and says so in wingman.log,
/// so a hang leaves evidence even when macOS doesn't sample it (spindump often
/// doesn't, and a force quit leaves no crash report).
///
/// The main thread checks in twice a second — also during a window's live
/// resize, which runs the run loop in its event-tracking mode — and leaves a
/// few facts behind (which window is in front, whether it's being resized, how
/// many lines the transcript has). A background thread checks the time since
/// the last check-in: blocked for 5 s, it logs those facts with the memory in
/// use, again at 10, 30, 60 s and every minute after, and once more when the
/// main thread is back. No meeting content: only window identifiers and counts.
///
/// Blocked for `releaseAudioAfter` seconds while recording, it also releases
/// the audio devices (`AudioEmergencyStop`), so force-quitting the hung app
/// can't break the call's audio; `onResumedAfterRelease` then has the recorder
/// rebuild capture.
final class MainThreadWatchdog: @unchecked Sendable {
    struct Context: Equatable {
        /// The key window's identifier ("transcript", "meetings"…), or "none".
        var window = "none"
        var liveResize = false
        var lines = 0
        var recording = false
        /// Each meeting window's state: "visible", "covered", "minimized",
        /// "hidden" or "other space"; "none" without one.
        var meetingWindow = "none"
    }

    static let releaseAudioAfter: Double = 20

    /// Called on the main thread when it responds again after the audio was
    /// released, with how long it was blocked.
    @MainActor var onResumedAfterRelease: ((Double) -> Void)?

    static let shared = MainThreadWatchdog()

    private let lock = NSLock()
    private var lastBeat = DispatchTime.now()
    private var context = Context()
    private var reportedAt: Double = 0
    private var releasedAudio = false
    private var timer: Timer?
    private var checker: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "wingman.watchdog", qos: .utility)

    /// The thresholds (seconds blocked) at which a hang is logged.
    static let reportAt: [Double] = [5, 10, 30, 60]

    @MainActor
    func start(context: @escaping @MainActor () -> Context) {
        guard timer == nil else { return }
        let beat = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.beat(context()) }
        }
        // `.common` includes event tracking: a live resize isn't a hang.
        RunLoop.main.add(beat, forMode: .common)
        timer = beat
        self.beat(context())

        let checker = DispatchSource.makeTimerSource(queue: queue)
        checker.schedule(deadline: .now() + 1, repeating: 1)
        checker.setEventHandler { [weak self] in self?.check() }
        checker.resume()
        self.checker = checker
    }

    private func beat(_ now: Context) {
        lock.lock()
        let blockedFor = Double(DispatchTime.now().uptimeNanoseconds - lastBeat.uptimeNanoseconds) / 1e9
        let wasReported = reportedAt > 0
        let wasReleased = releasedAudio
        lastBeat = .now()
        context = now
        reportedAt = 0
        releasedAudio = false
        lock.unlock()
        if wasReported {
            Log.write(String(format: "main thread responding again after %.0f s", blockedFor))
        }
        if wasReleased { MainActor.assumeIsolated { onResumedAfterRelease?(blockedFor) } }
    }

    private func check() {
        lock.lock()
        let blocked = Double(DispatchTime.now().uptimeNanoseconds - lastBeat.uptimeNanoseconds) / 1e9
        let facts = context
        let next = Self.nextReport(after: reportedAt)
        let due = blocked >= next
        if due { reportedAt = next }
        let release = Self.shouldReleaseAudio(blocked: blocked, recording: facts.recording, alreadyReleased: releasedAudio)
        if release { releasedAudio = true }
        lock.unlock()
        if due {
            Log.write(String(format: "main thread blocked for %.0f s — key window %@%@, meeting window %@, %d transcript lines, %@, memory %@",
                             blocked, facts.window, facts.liveResize ? " (being resized)" : "", facts.meetingWindow, facts.lines,
                             facts.recording ? "recording" : "not recording", Self.memoryInUse()))
        }
        if release {
            let stopped = AudioEmergencyStop.shared.stopAll()
            Log.write(String(format: "main thread blocked for %.0f s while recording: released %@ so the call isn't disturbed",
                             blocked, stopped.isEmpty ? "nothing (no capture running)" : stopped.joined(separator: " and ")))
        }
    }

    /// Once per hang, after `releaseAudioAfter` seconds, only while recording.
    static func shouldReleaseAudio(blocked: Double, recording: Bool, alreadyReleased: Bool) -> Bool {
        recording && !alreadyReleased && blocked >= releaseAudioAfter
    }

    /// 5, 10, 30, 60 s, then every minute.
    static func nextReport(after last: Double) -> Double {
        reportAt.first { $0 > last } ?? (last + 60)
    }

    /// The process's memory footprint, as Activity Monitor shows it.
    static func memoryInUse() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return "unknown" }
        return ByteCountFormatter.string(fromByteCount: Int64(info.phys_footprint), countStyle: .memory)
    }

    /// What the main thread knows right now, for the next report.
    @MainActor
    static func currentContext(lines: Int, recording: Bool) -> Context {
        let key = NSApp.keyWindow
        let meetings = NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix("meeting") == true }
        return Context(window: key?.identifier?.rawValue ?? (key == nil ? "none" : "other"),
                       liveResize: NSApp.windows.contains { $0.inLiveResize }, lines: lines, recording: recording,
                       meetingWindow: meetings.isEmpty ? "none" : meetings.map(state(of:)).joined(separator: ", "))
    }

    @MainActor
    private static func state(of window: NSWindow) -> String {
        if window.isMiniaturized { return "minimized" }
        if !window.isVisible { return "hidden" }
        if !window.isOnActiveSpace { return "other space" }
        return window.occlusionState.contains(.visible) ? "visible" : "covered"
    }
}
