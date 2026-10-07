import AppKit
import CoreAudio
import Foundation

/// The apps Wingman watches for calls. Google Meet runs in a browser, so it's
/// never matched by bundle ID: a browser's microphone use becomes a Meet call when
/// its tabs (or the Meet app) show one (`CallTracker`, `MeetInspector`).
enum CallApp: String, CaseIterable, Identifiable, Codable {
    case teams, zoom, meet, browser

    var id: String { rawValue }

    var name: String {
        switch self {
        case .teams: return "Microsoft Teams"
        case .zoom: return "Zoom"
        case .meet: return "Google Meet"
        case .browser: return "Browser calls"
        }
    }

    /// Short form for notifications: "your Teams call".
    var shortName: String {
        switch self {
        case .teams: return "Teams"
        case .zoom: return "Zoom"
        case .meet: return "Google Meet"
        case .browser: return "browser"
        }
    }

    /// "Teams call", "Browser call": for "… detected" and the like.
    var callTitle: String {
        switch self {
        case .teams: return "Teams call"
        case .zoom: return "Zoom call"
        case .meet: return "Google Meet call"
        case .browser: return "Browser call"
        }
    }

    /// The apps listed in Settings and the welcome guide. The App Store build can't
    /// read browser tabs, so Meet calls are browser calls there.
    static var shown: [CallApp] {
        #if APP_STORE
        return [.teams, .zoom, .browser]
        #else
        return allCases
        #endif
    }

    /// Bundle ID prefixes, so helper processes (e.g. "…Chrome.helper") count too.
    var bundlePrefixes: [String] {
        switch self {
        case .teams: return ["com.microsoft.teams"]
        case .zoom: return ["us.zoom."]
        case .meet: return []
        case .browser:
            return ["com.google.Chrome", "com.apple.Safari", "com.apple.WebKit", "com.microsoft.edgemac",
                    "org.mozilla.", "company.thebrowser.", "com.brave.Browser", "com.operasoftware."]
        }
    }

    /// Browsers built on Chromium, whose tab strip shows which tab captures the mic.
    static let chromiumPrefixes = ["com.google.Chrome", "com.microsoft.edgemac", "company.thebrowser.",
                                   "com.brave.Browser", "com.operasoftware."]

    static func matching(bundleID: String) -> CallApp? {
        allCases.first { app in app.bundlePrefixes.contains { bundleID.hasPrefix($0) } }
    }

    /// The browser prefix a bundle ID belongs to ("com.google.Chrome" for its helpers).
    static func browserFamily(of bundleID: String) -> String? {
        CallApp.browser.bundlePrefixes.first { bundleID.hasPrefix($0) }
    }
}

/// What to do when a call app starts using the microphone.
enum AutoRecordPolicy: String, CaseIterable, Identifiable, Codable {
    case automatic, ask, off

    var id: String { rawValue }

    var name: String {
        switch self {
        case .automatic: return "Record automatically"
        case .ask: return "Ask me first"
        case .off: return "Off"
        }
    }
}

/// Watches which apps are using the microphone (Core Audio process objects,
/// macOS 14.4+) and reports when a call app starts or stops a call.
///
/// A call "starts" once the app has held the mic for a few seconds, so a quick
/// device test doesn't count, and "ends" once it has let go for a few seconds,
/// so a brief mute/unmute glitch doesn't split the meeting.
@MainActor
final class CallDetector {
    typealias Event = CallTracker.Event
    /// Reads a browser's windows for Meet calls; nil where that isn't possible (the
    /// App Store build), so every browser call stays a browser call.
    typealias Inspector = @Sendable (_ browserPID: pid_t, _ family: String) async -> BrowserScan

    private static let pollInterval: Duration = .seconds(1)

    private let onEvent: (Event) -> Void
    private let inspect: Inspector?
    private var task: Task<Void, Never>?
    private var tracker = CallTracker()
    private var sequence = 0

    init(inspect: Inspector? = nil, onEvent: @escaping (Event) -> Void) {
        self.inspect = inspect
        self.onEvent = onEvent
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Whether a session is still going (it started and hasn't ended).
    func isActive(_ session: CallSession) -> Bool { tracker.isActive(session.id) }

    /// The session's latest state (its evidence may have improved).
    func current(_ session: CallSession) -> CallSession? { tracker.session(session.id) }

    private func poll() async {
        var observation = MicObservation()
        var browserPIDs: [String: (pid: pid_t, family: String)] = [:]
        for process in Self.microphoneProcesses() {
            guard let app = CallApp.matching(bundleID: process.bundleID) else { continue }
            guard app == .browser, let family = CallApp.browserFamily(of: process.bundleID) else {
                observation.apps.insert(app)
                continue
            }
            let pid = Self.browserPID(for: process, family: family)
            browserPIDs["\(family)|\(pid)"] = (pid, family)
        }
        for (key, browser) in browserPIDs {
            if let inspect, CallApp.chromiumPrefixes.contains(browser.family) {
                observation.browsers[key] = await inspect(browser.pid, browser.family)
            } else {
                observation.browsers[key] = .unavailable
            }
        }
        sequence += 1
        for event in tracker.update(observation, at: Date(), sequence: sequence) { onEvent(event) }
    }

    /// The browser a capturing process belongs to: Chrome records in a helper whose
    /// parent is the browser itself; otherwise the process is taken as the browser.
    private static func browserPID(for process: AudioProcess, family: String) -> pid_t {
        if let parent = ProcessTree.parentPID(of: process.pid),
           let id = NSRunningApplication(processIdentifier: parent)?.bundleIdentifier,
           id.hasPrefix(family), !id.contains(".helper"), !id.contains(".app.") {
            return parent
        }
        return process.pid
    }

    /// Bundle IDs of processes currently capturing from an input device, not counting Wingman.
    nonisolated static func processesUsingMicrophone() -> [String] {
        microphoneProcesses().map(\.bundleID)
    }

    /// Processes currently capturing from an input device, with their pids.
    nonisolated static func microphoneProcesses() -> [AudioProcess] {
        processes(running: kAudioProcessPropertyIsRunningInput)
    }

    /// Bundle IDs of processes currently playing audio, not counting Wingman.
    nonisolated static func processesPlayingAudio() -> [String] {
        processes(running: kAudioProcessPropertyIsRunningOutput).map(\.bundleID)
    }

    /// A process Core Audio reports as using a device: its bundle ID ("pid:<n>"
    /// when it has none) and process ID.
    struct AudioProcess: Equatable, Sendable {
        let bundleID: String
        let pid: pid_t
    }

    private nonisolated static func processes(running selector: AudioObjectPropertySelector) -> [AudioProcess] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return [] }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        return processes.compactMap { process in
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(process, &runningAddress, 0, nil, &runningSize, &running) == noErr,
                  running != 0 else { return nil }

            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = runningAddress
            pidAddress.mSelector = kAudioProcessPropertyPID
            if AudioObjectGetPropertyData(process, &pidAddress, 0, nil, &pidSize, &pid) == noErr, pid == ownPID {
                return nil
            }

            var bundle: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var bundleAddress = runningAddress
            bundleAddress.mSelector = kAudioProcessPropertyBundleID
            guard AudioObjectGetPropertyData(process, &bundleAddress, 0, nil, &bundleSize, &bundle) == noErr,
                  let bundle else { return AudioProcess(bundleID: "pid:\(pid)", pid: pid) }
            return AudioProcess(bundleID: bundle.takeRetainedValue() as String, pid: pid)
        }
    }
}
