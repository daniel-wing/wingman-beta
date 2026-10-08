import AppKit
import AVFoundation
import Foundation
import Observation

/// Current state of each permission Wingman uses, with a way to ask for each.
@MainActor
@Observable
final class Permissions {
    enum State: Equatable {
        case unknown, granted, denied, waiting
    }

    private(set) var microphone: State = .unknown
    private(set) var systemAudio: State = .unknown
    private(set) var calendar: State = .unknown
    private(set) var notifications: State = .unknown
    /// Accessibility: only for following the mute in Teams/Zoom (not in App Store builds).
    private(set) var accessibility: State = .unknown

    private let notifier: Notifier

    init(notifier: Notifier) {
        self.notifier = notifier
    }

    func refresh() async {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .granted
        case .denied, .restricted: microphone = .denied
        default: microphone = .unknown
        }
        // macOS has no public API for this one; remembered from the last successful check.
        if systemAudio == .unknown, UserDefaults.standard.bool(forKey: "systemAudioConfirmed") { systemAudio = .granted }
        #if !APP_STORE
        if accessibility != .waiting { accessibility = AXIsProcessTrusted() ? .granted : .unknown }
        #endif
        calendar = CalendarLookup.isAuthorized ? .granted : (CalendarLookup.hasBeenAsked ? .denied : .unknown)
        notifications = await notifier.isAuthorized ? .granted : (await notifier.hasBeenAsked ? .denied : .unknown)
    }

    func requestMicrophone() async {
        microphone = .waiting
        microphone = await AVCaptureDevice.requestAccess(for: .audio) ? .granted : .denied
    }

    /// macOS has no API to read this permission, but a tap only receives audio
    /// once it's allowed, so start one and watch for audio to arrive. A tap
    /// created while the permission prompt is open stays silent after "Allow"
    /// until macOS reconnects it, so restart it every couple of seconds; the
    /// first restart after the answer shows up immediately.
    /// Shown under System audio while waiting, so the delay is explained.
    private(set) var systemAudioNote: String?

    func requestSystemAudio() async {
        systemAudio = .waiting
        systemAudioNote = nil
        defer { if systemAudio != .waiting { systemAudioNote = nil } }
        var tap: SystemAudioTap?
        defer { tap?.stop() }
        for attempt in 0..<120 {  // up to a minute while the macOS prompt is open
            if attempt % 4 == 0 {
                tap?.stop()
                let fresh = SystemAudioTap()
                do {
                    try fresh.start { _ in }
                } catch {
                    systemAudio = .denied
                    UserDefaults.standard.removeObject(forKey: "systemAudioConfirmed")
                    return
                }
                tap = fresh
            }
            if attempt == 6 {
                systemAudioNote = "Waiting for macOS to confirm. This can take a few seconds — Wingman plays a soft sound to help it along."
            }
            // macOS sometimes applies the answer only once audio is playing, so
            // after a few seconds play a quiet sound every few seconds.
            if attempt >= 6, attempt % 8 == 6 { Self.playNudge() }
            try? await Task.sleep(for: .milliseconds(500))
            if let tap, tap.callbacks > 0 {
                systemAudio = .granted
                UserDefaults.standard.set(true, forKey: "systemAudioConfirmed")
                return
            }
        }
        systemAudio = .denied
        UserDefaults.standard.removeObject(forKey: "systemAudioConfirmed")
    }

    private static func playNudge() {
        guard let sound = NSSound(named: "Pop")?.copy() as? NSSound else { return }
        sound.volume = 0.3
        sound.play()
    }

    func requestCalendar() async {
        calendar = .waiting
        calendar = await CalendarLookup.requestAccess() ? .granted : .denied
    }

    #if !APP_STORE
    /// Shows macOS's Accessibility prompt, then waits for the user to switch
    /// Wingman on in System Settings (macOS sends no callback when they do).
    func requestAccessibility() async {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            accessibility = .granted
            return
        }
        accessibility = .waiting
        for _ in 0..<90 {
            try? await Task.sleep(for: .seconds(1))
            if AXIsProcessTrusted() {
                accessibility = .granted
                return
            }
        }
        accessibility = .denied
    }
    #endif

    func requestNotifications() async {
        notifications = .waiting
        notifications = await notifier.requestAccess() ? .granted : .denied
    }
}
