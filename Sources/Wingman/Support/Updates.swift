#if !APP_STORE
import AppKit
import Observation
import Sparkle

/// Automatic updates with Sparkle (direct-download build only; the App Store does
/// its own). About once a day Wingman reads the update feed attached to the public
/// repo's latest release, downloads a newer version in the background, checks that
/// it's signed with the project's update key (SUPublicEDKey in Info.plist), and
/// installs it when Wingman quits — or right away from the menu, never during a
/// recording. Settings → About can switch it off.
@MainActor
@Observable
final class Updates: NSObject {
    /// Checking and installing on their own (Settings → About).
    var automatic: Bool {
        didSet {
            controller?.updater.automaticallyChecksForUpdates = automatic
            controller?.updater.automaticallyDownloadsUpdates = automatic
        }
    }
    /// The version downloaded and waiting for Wingman to quit, if any.
    private(set) var ready: String?

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private let recorder: Recorder
    @ObservationIgnored private var installNow: (() -> Void)?

    init(recorder: Recorder) {
        self.recorder = recorder
        automatic = false
        super.init()
        // A build without the update key (a contributor's own build) doesn't update.
        guard Self.configured else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        automatic = controller.updater.automaticallyChecksForUpdates
    }

    /// Whether this build can update itself: it's an app bundle with the update key.
    static var configured: Bool {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        return !key.isEmpty && Bundle.main.bundleURL.pathExtension == "app"
    }

    var available: Bool { controller != nil }

    /// "Check for Updates…": Sparkle's own window says what it found.
    func checkNow() {
        controller?.checkForUpdates(nil)
    }

    /// Installs the downloaded update and reopens Wingman (not while recording).
    func installAndRestart() {
        guard !recorder.isRecording, let installNow else { return }
        Log.write("installing update \(ready ?? "?") now")
        installNow()
    }
}

extension Updates: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        MainActor.assumeIsolated {
            ready = version
            installNow = immediateInstallHandler
        }
        Log.write("update \(version) downloaded; it installs when Wingman quits")
        // The menu offers it ("Restart to Install…"), so Sparkle needn't show anything.
        return true
    }

    /// A relaunch after installing waits for a recording to finish.
    nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                             untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated {
            guard recorder.phase != .idle else { return false }
            Log.write("update waits for the recording to finish")
            Task { @MainActor [recorder] in
                while recorder.phase != .idle { try? await Task.sleep(for: .seconds(5)) }
                installHandler()
            }
            return true
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        // Categories only: "no update", or the kind of failure (offline, bad signature…).
        let nsError = error.map { $0 as NSError }
        if let nsError, nsError.domain == SUSparkleErrorDomain, nsError.code == Int(SUError.noUpdateError.rawValue) {
            Log.write("update check: up to date")
        } else if let nsError {
            Log.write("update check failed: \(nsError.domain) \(nsError.code)")
        }
    }
}

extension Updates: SPUStandardUserDriverDelegate {
    /// Wingman lives in the menu bar: remind gently instead of opening windows.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
#endif
