#if !APP_STORE
import AppKit
import Observation

/// While the screen is shared in the Teams call being recorded, Wingman's own
/// windows (the Wingman window, Settings) step aside too, not only the Live
/// Transcript: a whole-screen share would show them. They're made invisible
/// where they are rather than closed or moved, so they come back exactly as
/// they were when sharing ends. Clicking Wingman (the menu bar, the Dock)
/// brings them back for the rest of that share: maybe it's the window being shared.
@MainActor
final class SharingCurtain {
    private let recorder: Recorder
    private let sharing: () -> Bool
    private let prefs = LivePrefs.shared
    /// The windows made invisible, with how they were.
    private var hidden: [(window: NSWindow, alpha: CGFloat, ignoredMouse: Bool)] = []
    /// Wingman was brought forward during this share: leave its windows alone until it ends.
    private var shownDuringShare = false
    private var activation: NSObjectProtocol?
    private var keyWindow: NSObjectProtocol?

    init(recorder: Recorder, sharing: @escaping () -> Bool) {
        self.recorder = recorder
        self.sharing = sharing
    }

    func start() {
        _ = Self.launched
        observe()
        #if !NO_DIAGNOSTICS
        let pretend = UserDefaults.standard.double(forKey: "WingmanPretendSharing")
        if pretend > 0 {
            for delay in [10.05, 10.05 + pretend] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    Log.write("pretend sharing \(Self.pretendSharing ? "starts" : "ends")")
                    self?.evaluate()
                }
            }
        }
        #endif
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wingmanActivated() }
        }
        // Opening a window of Wingman's while it's already the active app
        // (Open Wingman, Settings…) doesn't activate it again: a hidden window
        // becoming key is the sign instead.
        keyWindow = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                           object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let window = note.object as? NSWindow,
                      self.hidden.contains(where: { $0.window === window }) else { return }
                self.wingmanActivated()
            }
        }
    }

    private func observe() {
        evaluate()
        withObservationTracking {
            _ = sharing()
            _ = recorder.isRecording
            _ = prefs.hideWhileSharing
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.observe() }
        }
    }

    private var sharingNow: Bool {
        prefs.hideWhileSharing && ((recorder.isRecording && sharing()) || Self.pretendSharing)
    }

    /// Development: `-WingmanPretendSharing N` acts as if the screen were
    /// shared from 10 s after launch for N seconds, recording or not, to check
    /// what hides without a Teams call.
    static var pretendSharing: Bool {
        #if NO_DIAGNOSTICS
        false
        #else
        let seconds = UserDefaults.standard.double(forKey: "WingmanPretendSharing")
        let elapsed = Date().timeIntervalSince(launched)
        return seconds > 0 && elapsed >= 10 && elapsed < 10 + seconds
        #endif
    }
    private static let launched = Date()

    private func evaluate() {
        if sharingNow {
            // Wingman in front (the setting just turned on in Settings, say):
            // someone is using its windows, so they stay for this share.
            if hidden.isEmpty, !shownDuringShare, NSApp.isActive { shownDuringShare = true }
            if !shownDuringShare, hidden.isEmpty { hide() }
        } else {
            shownDuringShare = false
            restore()
        }
    }

    private func wingmanActivated() {
        guard sharingNow, !hidden.isEmpty else { return }
        shownDuringShare = true
        restore()
        Log.write("screen sharing: Wingman brought forward, its windows shown")
    }

    private func hide() {
        for window in NSApp.windows where Self.shouldHide(window) {
            hidden.append((window, window.alphaValue, window.ignoresMouseEvents))
            window.alphaValue = 0
            window.ignoresMouseEvents = true
        }
        if !hidden.isEmpty { Log.write("screen sharing: \(hidden.count) Wingman window(s) hidden") }
    }

    private func restore() {
        guard !hidden.isEmpty else { return }
        for entry in hidden {
            entry.window.alphaValue = entry.alpha
            entry.window.ignoresMouseEvents = entry.ignoredMouse
        }
        hidden = []
    }

    /// Ordinary titled windows on screen. Not the Live Transcript (it hides
    /// itself, and its setting can differ), menus, popovers or the menu-bar icon.
    private static func shouldHide(_ window: NSWindow) -> Bool {
        window.isVisible && window.styleMask.contains(.titled) && window.level == .normal
            && window.identifier?.rawValue != "live-transcript" && !(window is NSPanel)
    }
}
#endif
