import Foundation

/// How capture lets go of its audio devices when the main thread is stuck.
///
/// A recording holds two devices macOS shares with the call: the microphone
/// engine's (on a headset in a call, the same Bluetooth device the call app
/// uses) and the call-audio tap's. When a hung Wingman is force-quit, macOS
/// tears those down abruptly and the call's audio breaks (seen on the field
/// Mac with a Bluetooth headset: "Overload possibly due to client timeout").
/// So each capture registers how to release its device, callable from any
/// thread, and `MainThreadWatchdog` calls them when the main thread has been
/// blocked for a while during a recording. The recorder rebuilds capture once
/// the main thread is back.
final class AudioEmergencyStop: @unchecked Sendable {
    static let shared = AudioEmergencyStop()

    private let lock = NSLock()
    private var stops: [UUID: (name: String, stop: @Sendable () -> Void)] = [:]

    /// `stop` must be safe to call from a background thread while the main
    /// thread is blocked. Returns the token to `unregister` with.
    func register(_ name: String, stop: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        lock.withLock { stops[id] = (name, stop) }
        return id
    }

    func unregister(_ id: UUID?) {
        guard let id else { return }
        lock.withLock { _ = stops.removeValue(forKey: id) }
    }

    var isEmpty: Bool { lock.withLock { stops.isEmpty } }

    /// Runs every registered stop once, on the calling thread, and forgets
    /// them. Returns what was stopped ("microphone", "call audio").
    @discardableResult
    func stopAll() -> [String] {
        let all = lock.withLock {
            defer { stops.removeAll() }
            return Array(stops.values)
        }
        for entry in all { entry.stop() }
        return all.map(\.name).sorted()
    }
}
