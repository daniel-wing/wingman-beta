import Foundation

/// `Wingman devicewatch [seconds]` prints every default audio device change.
enum DeviceWatch {
    static func run(_ args: [String]) async -> Int32 {
        let seconds = args.first.flatMap(Double.init) ?? 15
        print("Watching for \(Int(seconds)) s — output: \(AudioDeviceMonitor.defaultOutputName() ?? "?"), input: \(AudioDeviceMonitor.defaultInputName() ?? "?")")
        let monitor = AudioDeviceMonitor {
            print("Changed — output: \(AudioDeviceMonitor.defaultOutputName() ?? "?"), input: \(AudioDeviceMonitor.defaultInputName() ?? "?")")
        }
        try? await Task.sleep(for: .seconds(seconds))
        monitor.stop()
        return 0
    }
}
