#if !APP_STORE
import AppKit
import ApplicationServices
import Foundation
import Observation

/// Follows the user's mute in Teams and Zoom, so muting there (button,
/// ⌘⇧M / ⌘⇧A, or an AirPods press) also stops Wingman transcribing them.
///
/// Neither app offers a usable signal, so this reads their mute control
/// through the macOS Accessibility API — Teams' toolbar button ("Mute (⌘ ⇧ M)"
/// / "Unmute (⌘ ⇧ M)") and Zoom's Meeting menu ("Mute audio" / "Unmute audio").
/// It reads labels and never clicks or types; the one thing it sets is
/// Teams' "build your accessibility tree" switch (AXManualAccessibility), when
/// the button can't be found otherwise. Calls in a browser can't be followed.
/// Accessibility isn't allowed in Mac App Store apps, so this is compiled out there.
///
/// If the control can't be read (permission missing, or the app's UI changed),
/// Wingman keeps transcribing and says so, rather than guessing.
@MainActor
@Observable
final class CallMuteMonitor {
    enum Status: Equatable {
        case off
        case needsPermission
        case waitingForCall
        case following(CallApp, muted: Bool)
        case cantRead(CallApp)
        /// Google Meet and other browser calls: following their mute isn't available.
        case notSupported(CallApp)

        var description: String {
            switch self {
            case .off: return "Off"
            case .needsPermission: return "Needs Accessibility permission"
            case .waitingForCall: return "Waiting for a Teams or Zoom call"
            case .following(let app, let muted): return "Following \(app.shortName) — \(muted ? "muted" : "unmuted")"
            case .cantRead(let app): return "Can't read \(app.shortName)'s mute button"
            case .notSupported(let app): return app == .meet ? "Can't follow mute in Google Meet yet" : "Can't follow mute in browser calls"
            }
        }
    }

    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "followCallMute")
            Log.write("follow call mute \(enabled ? "on" : "off")")
        }
    }
    private(set) var status: Status = .off
    /// Tells the user when following stops working (a lasting problem, once per
    /// recording), since the transcript window is usually closed during a call;
    /// called with nil when it works again.
    var onProblem: ((String?) -> Void)?
    /// When the current problem started, and which recording was told about one.
    private var problemSince: Date?
    private var toldRecording: Date?
    private static let tellAfter: TimeInterval = 10

    private let recorder: Recorder
    private let probe = AXProbe()
    private var loop: Task<Void, Never>?
    private var target: CallApp?
    private var misses = 0
    /// The control was read at least once in this call (so a miss means it was lost).
    private var foundInCall = false
    private var reportedLabels: Set<String> = []

    init(recorder: Recorder) {
        self.recorder = recorder
        enabled = UserDefaults.standard.bool(forKey: "followCallMute")
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let pause = await self.tick()
                try? await Task.sleep(for: pause)
            }
        }
    }

    // MARK: - Loop

    private func tick() async -> Duration {
        guard enabled, recorder.isRecording else {
            settle(enabled ? .waitingForCall : .off, problem: nil)
            return .seconds(1)
        }
        guard let app = callApp() else {
            if let app = recorder.callApp, app == .meet || app == .browser {
                // Nothing to fix, so a calm note rather than a problem or a notification.
                let note = app == .meet
                    ? "Wingman can't follow your Google Meet mute yet. When you mute in Meet, mute Wingman too (menu bar or its shortcut)."
                    : "Wingman can't follow your mute in a browser call. When you mute there, mute Wingman too (menu bar or its shortcut)."
                settle(.notSupported(app), problem: nil, note: note)
            } else {
                settle(.waitingForCall, problem: nil)
            }
            return .seconds(1)
        }
        guard AXIsProcessTrusted() else {
            settle(.needsPermission, problem: "Wingman isn't following your mute in Teams or Zoom: it needs Accessibility permission (Settings → Calls). Use Wingman's own mute meanwhile.")
            return .seconds(2)
        }
        if app != target {
            target = app
            misses = 0
            foundInCall = false
            await probe.reset()
            // A different call: "Transcribe me anyway" was about the previous one.
            recorder.stopFollowingCallMute(keepOverride: false)
        }

        switch await probe.read(app) {
        case .state(let muted):
            misses = 0
            foundInCall = true
            if status != .following(app, muted: muted) { Log.write("follow call mute: \(Status.following(app, muted: muted).description)") }
            status = .following(app, muted: muted)
            recorder.callMuteNote = nil
            clearProblem()
            recorder.followCallMute(muted ? app : nil)
            return .milliseconds(250)
        case .unknownLabel(let label):
            if reportedLabels.insert(label).inserted {
                Log.write("\(app.shortName) mute control has an unrecognized label: “\(label)”")
            }
            cantRead(app)
            return .seconds(3)
        case .notFound:
            misses += 1
            if foundInCall {
                // Lost after it was working (e.g. the window was rebuilt): keep
                // the last reading through a few quick looks, then stop following.
                if misses >= 3 { cantRead(app) }
                return misses < 3 ? .seconds(1) : misses > 10 ? .seconds(10) : .seconds(3)
            }
            // Not found yet: the control appears once the meeting window/menu
            // does, so allow ~10 s before saying so; then keep looking.
            if misses >= 4 { cantRead(app) }
            return misses > 10 ? .seconds(10) : .seconds(3)
        case .noPermission:
            settle(.needsPermission, problem: "Wingman isn't following your mute in Teams or Zoom: it needs Accessibility permission (Settings → Calls).")
            return .seconds(2)
        case .notRunning:
            settle(.waitingForCall, problem: nil)
            return .seconds(1)
        }
    }

    private func cantRead(_ app: CallApp) {
        if status != .cantRead(app) { Log.write("can't read \(app.shortName)'s mute control — transcribing normally") }
        settle(.cantRead(app),
               problem: "Wingman can't see \(app.shortName)'s mute button right now, so it isn't following your mute there. Use Wingman's own mute meanwhile.")
    }

    /// Not following: never leave Wingman muted on a stale reading.
    private func settle(_ new: Status, problem: String?, note: String? = nil) {
        if new != status, recorder.isRecording { Log.write("follow call mute: \(new.description)") }
        status = new
        recorder.callMuteProblem = problem
        recorder.callMuteNote = note
        // A read failure mid-call keeps "Transcribe me anyway"; a call ending or
        // following being turned off ends it.
        if case .cantRead = new {
            recorder.stopFollowingCallMute(keepOverride: true)
        } else {
            recorder.stopFollowingCallMute(keepOverride: false)
        }
        if new == .off || new == .waitingForCall { target = nil }
        guard let problem, recorder.isRecording else {
            clearProblem()
            return
        }
        // Tell the user only about a problem that lasts, once per recording.
        let now = Date()
        let since = problemSince ?? now
        problemSince = since
        if now.timeIntervalSince(since) >= Self.tellAfter, toldRecording != recorder.startedAt {
            toldRecording = recorder.startedAt
            onProblem?(problem)
        }
    }

    private func clearProblem() {
        recorder.callMuteProblem = nil
        if problemSince != nil, toldRecording != nil { onProblem?(nil) }
        problemSince = nil
    }

    /// The call being recorded: the app that started it, else whichever of
    /// Teams/Zoom is using the microphone (they keep it open while muted).
    private func callApp() -> CallApp? {
        if let app = recorder.callApp, app != .browser, app != .meet { return app }
        let using = Set(CallDetector.processesUsingMicrophone().compactMap(CallApp.matching(bundleID:)))
        if using.contains(.teams) { return .teams }
        if using.contains(.zoom) { return .zoom }
        return nil
    }
}

// MARK: - Reading the control

/// Does the Accessibility work off the main thread. Finds the mute control
/// once, keeps it, and re-reads only its label; searches again if it goes stale.
actor AXProbe {
    enum Reading {
        case state(Bool)
        case unknownLabel(String)
        case notFound
        case noPermission
        case notRunning
    }

    private var control: AXUIElement?
    private var pid: pid_t = 0
    private var triedWebAccessibility = false
    private var timeoutSet = false

    func reset() {
        control = nil
        triedWebAccessibility = false
    }

    func read(_ app: CallApp) -> Reading {
        guard let pid = AXTree.pid(for: app) else {
            control = nil
            return .notRunning
        }
        if pid != self.pid {
            self.pid = pid
            reset()
        }
        // Its window was minimized: that copy goes stale, so find the live one.
        if let control, app == .teams, AXTree.inMinimizedWindow(control) {
            self.control = nil
        }
        if let control {
            switch AXTree.label(control, for: app) {
            case .success(let label):
                if let muted = MuteLabels.isMuted(label) { return .state(muted) }
                return .unknownLabel(label)
            case .failure(.apiDisabled):
                return .noPermission
            case .failure:
                self.control = nil  // stale (window closed, UI rebuilt) — search again
            }
        }

        // A busy app can't stall Wingman: this applies to every element read,
        // including the saved control and the tree search (default is ~6 s).
        if !timeoutSet {
            AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
            timeoutSet = true
        }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
        if AXTree.string(application, kAXRoleAttribute) == nil, AXTree.lastError == .apiDisabled { return .noPermission }

        let started = Date()
        var found = AXTree.findMuteControl(in: application, for: app)
        if found == nil, app == .teams, !triedWebAccessibility {
            // Web-based UIs may only build their accessibility tree once asked.
            triedWebAccessibility = true
            AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            found = AXTree.findMuteControl(in: application, for: app)
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        guard let found else { return .notFound }
        Log.write("found \(app.shortName)'s mute control in \(ms) ms")
        control = found
        if case .success(let label) = AXTree.label(found, for: app) {
            if let muted = MuteLabels.isMuted(label) { return .state(muted) }
            return .unknownLabel(label)
        }
        return .notFound
    }
}

/// Mute/unmute wording in the languages Wingman supports. The label's
/// longest matching beginning decides, since some phrases contain another:
/// Portuguese "Ativar mudo" (turn mute on) starts with "ativar" (turn on).
enum MuteLabels {
    /// Labels that mean "you're muted — click to unmute".
    static let unmute = [
        "unmute", "turn on mic", "turn mic on",
        "reactivar", "activar", "dejar de silenciar", "quitar silencio", "anular silencio",
        "ativar", "desativar mudo", "desativar o mudo", "reativar",
        "stummschaltung aufheben", "mikrofon einschalten",
        "audio-stummschaltung aufheben", "audio stummschaltung aufheben",
        "réactiver", "rétablir", "activer",
        "riattiva", "attiva",
    ]
    /// Labels that mean "you're unmuted — click to mute".
    static let mute = [
        "mute", "turn off mic", "turn mic off",
        "silenciar", "desactivar", "desativar", "mudo", "ativar mudo", "ativar o mudo",
        "stummschalten", "mikrofon ausschalten", "audio stummschalten",
        "couper", "désactiver", "muet",
        "disattiva", "silenzia",
    ]
    /// Plain "turn on/off" verbs: they say nothing about the mic on their own.
    static let genericVerbs: Set<String> = [
        "activar", "desactivar", "reactivar", "ativar", "desativar", "reativar",
        "activer", "désactiver", "réactiver", "rétablir", "couper", "attiva", "disattiva", "riattiva",
    ]

    /// true = muted, false = unmuted, nil = not a mute/unmute label.
    static func isMuted(_ label: String) -> Bool? {
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let best = (unmute.map { ($0, true) } + mute.map { ($0, false) })
            .filter { text.hasPrefix($0.0) }
            .max { $0.0.count < $1.0.count }
        return best?.1
    }

    /// A short label that's only about the mic: the bare word ("Mute", "Silenciar")
    /// or one naming the mic/audio — not "Activar cámara" (camera), nor a bare
    /// "Activar", which could be anything.
    static func isAboutMicrophone(_ label: String) -> Bool {
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard text.split(separator: " ").count <= 3 else { return false }
        if (unmute + mute).contains(text) { return !genericVerbs.contains(text) }
        // Whole words, so "Activar personas" doesn't count as "son" (sound).
        let words = text.split { !$0.isLetter }.map(String.init)
        return words.contains { word in
            ["mic", "mikro", "audio", "áudio", "sonido"].contains { word.hasPrefix($0) } || ["son", "som", "ton"].contains(word)
        }
    }

    /// Teams' button carries its shortcut, e.g. "Mute (⌘ ⇧ M)" — a language-independent hook.
    static func hasTeamsShortcut(_ label: String) -> Bool {
        let compact = label.replacingOccurrences(of: " ", with: "").lowercased()
        return compact.contains("⌘⇧m") || compact.contains("⇧⌘m") || compact.contains("cmd+shift+m")
            || compact.contains("ctrl+shift+m")
    }
}

/// Small helpers around the Accessibility C API.
enum AXTree {
    enum Failure: Error { case apiDisabled, other }

    nonisolated(unsafe) static var lastError: AXError = .success

    static func pid(for app: CallApp) -> pid_t? {
        let bundles: [String]
        switch app {
        case .teams: bundles = ["com.microsoft.teams2", "com.microsoft.teams"]
        case .zoom: bundles = ["us.zoom.xos"]
        case .meet, .browser: return nil
        }
        // Teams can stop being a regular (Dock) app while it's minimized to its
        // floating mini window; it's still the same call.
        for bundle in bundles {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
            if let app = running.first(where: { $0.activationPolicy == .regular })
                ?? running.first(where: { $0.activationPolicy != .prohibited }) {
                return app.processIdentifier
            }
        }
        return nil
    }

    static func isMinimized(_ window: AXUIElement) -> Bool {
        (value(window, kAXMinimizedAttribute) as? Bool) == true
    }

    /// Whether a control sits in a minimized window, where Teams stops updating it.
    static func inMinimizedWindow(_ element: AXUIElement) -> Bool {
        guard let window = value(element, kAXWindowAttribute), CFGetTypeID(window) == AXUIElementGetTypeID() else { return false }
        return isMinimized(window as! AXUIElement)
    }

    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        lastError = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return lastError == .success ? value : nil
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    /// The text that names a control: description, title, or help.
    static func name(_ element: AXUIElement) -> String? {
        for attribute in [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute] {
            if let text = string(element, attribute), !text.isEmpty { return text }
        }
        return nil
    }

    static func label(_ element: AXUIElement, for app: CallApp) -> Result<String, Failure> {
        let text = app == .zoom ? string(element, kAXTitleAttribute) : name(element)
        if let text { return .success(text) }
        return .failure(lastError == .apiDisabled ? .apiDisabled : .other)
    }

    static func findMuteControl(in application: AXUIElement, for app: CallApp) -> AXUIElement? {
        switch app {
        case .teams:
            // A minimized meeting window keeps a copy of the mute button that stops
            // updating (the floating mini window has the live one), so skip it.
            let windows = ((value(application, kAXWindowsAttribute) as? [AXUIElement]) ?? []).filter { !isMinimized($0) }
            var fallback: AXUIElement?
            for window in windows {
                var visited = 0
                if let button = search(window, depth: 0, visited: &visited, match: { element in
                    guard let role = string(element, kAXRoleAttribute), role == kAXButtonRole || role == kAXCheckBoxRole,
                          let name = name(element) else { return false }
                    if MuteLabels.hasTeamsShortcut(name), MuteLabels.isMuted(name) != nil { return true }
                    // Without the shortcut (changed or hidden), accept a short label that's
                    // clearly about the microphone, e.g. "Unmute" or "Activar micrófono".
                    if fallback == nil, MuteLabels.isMuted(name) != nil, MuteLabels.isAboutMicrophone(name) {
                        fallback = element
                    }
                    return false
                }) {
                    return button
                }
            }
            return fallback
        case .zoom:
            guard let menuBar = value(application, kAXMenuBarAttribute).map({ $0 as! AXUIElement }) else { return nil }
            var visited = 0
            return search(menuBar, depth: 0, visited: &visited, maxDepth: 4) { element in
                guard string(element, kAXRoleAttribute) == kAXMenuItemRole,
                      let title = string(element, kAXTitleAttribute) else { return false }
                let shortcut = string(element, kAXMenuItemCmdCharAttribute)?.uppercased() == "A"
                    && (value(element, kAXMenuItemCmdModifiersAttribute) as? Int) == 1  // ⌘⇧
                let lower = title.lowercased()
                return MuteLabels.isMuted(title) != nil && (shortcut || lower.contains("audio") || lower.contains("áudio"))
            }
        case .meet, .browser:
            return nil
        }
    }

    /// Depth-first search with limits, so a huge window can't stall Wingman.
    static func search(_ element: AXUIElement, depth: Int, visited: inout Int, maxDepth: Int = 25,
                       match: (AXUIElement) -> Bool) -> AXUIElement? {
        visited += 1
        guard visited <= 8_000, depth <= maxDepth else { return nil }
        if match(element) { return element }
        for child in children(element) {
            if let found = search(child, depth: depth + 1, visited: &visited, maxDepth: maxDepth, match: match) {
                return found
            }
        }
        return nil
    }
}
#endif
