import AppKit
import SwiftUI

struct WingmanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(recorder: delegate.recorder, watcher: delegate.watcher, reporter: delegate.reporter,
                        muteShortcut: delegate.muteShortcut, updates: delegate.updatesForUI)
        } label: {
            MenuBarLabel(delegate: delegate)
        }

        Window("Wingman", id: "transcript") {
            TranscriptView(recorder: delegate.recorder, watcher: delegate.watcher, reporter: delegate.reporter,
                           shortcut: delegate.shortcut)
                .frame(minWidth: 420, minHeight: 360)
                .onAppear { WindowPresence.windowOpened() }
                .onDisappear { WindowPresence.windowClosed() }
        }
        .defaultSize(width: 560, height: 640)
        .defaultLaunchBehavior(.suppressed)

        Window("Welcome to Wingman", id: "welcome") {
            WelcomeView(recorder: delegate.recorder, watcher: delegate.watcher, permissions: delegate.permissions,
                        callMute: delegate.callMuteForUI) {
                NSApp.windows.first { $0.identifier?.rawValue == "welcome" }?.close()
            }
            .onAppear { WindowPresence.windowOpened() }
            .onDisappear {
                // Closing the guide counts as skipping it: defaults apply, and
                // everything stays changeable in Settings.
                UserDefaults.standard.set(true, forKey: "welcomeCompleted")
                WindowPresence.windowClosed()
                // Set up: fetch the models now, before the first call needs them.
                Task { await delegate.recorder.prepareModels() }
            }
        }
        .windowResizability(.contentSize)
        // Opened by macOS as part of launching, until setup is completed. Relying
        // on the menu-bar icon to open it raced with launch and could drop it.
        .defaultLaunchBehavior(AppDelegate.welcomeCompleted ? .suppressed : .presented)

        Window("Acknowledgements", id: "acknowledgements") {
            AcknowledgementsView()
                .onAppear { WindowPresence.windowOpened() }
                .onDisappear { WindowPresence.windowClosed() }
        }
        .defaultSize(width: 640, height: 720)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView(recorder: delegate.recorder, watcher: delegate.watcher, permissions: delegate.permissions,
                         shortcut: delegate.shortcut, muteShortcut: delegate.muteShortcut,
                         callMute: delegate.callMuteForUI, updates: delegate.updatesForUI)
                .onAppear { WindowPresence.windowOpened() }
                .onDisappear { WindowPresence.windowClosed() }
        }
    }
}

/// Owns the recorder so quitting from anywhere (Cmd+Q, the Dock, logging out)
/// finishes an active recording — and whatever runs after it, like telling
/// speakers apart and saving the audio — instead of cutting it off.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let recorder: Recorder
    @MainActor let notifier: Notifier
    @MainActor let permissions: Permissions
    @MainActor let watcher: CallWatcher
    @MainActor let shortcut: GlobalShortcut
    @MainActor let muteShortcut: GlobalShortcut
    @MainActor let reporter: ProblemReporter
    /// SIGTERM (`kill`, `killall Wingman`) turned into a normal quit.
    @MainActor private var terminateSignal: DispatchSourceSignal?
    #if !APP_STORE
    @MainActor let callMute: CallMuteMonitor
    @MainActor let updates: Updates
    #endif

    @MainActor
    override init() {
        recorder = Recorder()
        notifier = Notifier()
        permissions = Permissions(notifier: notifier)
        watcher = CallWatcher(recorder: recorder, notifier: notifier)
        shortcut = GlobalShortcut(id: 1, name: "Start or stop recording", defaultsKey: "recordShortcut",
                                  defaultShortcut: .default)
        muteShortcut = GlobalShortcut(id: 2, name: "Mute or unmute Wingman", defaultsKey: "muteShortcut",
                                      defaultShortcut: .defaultMute)
        #if APP_STORE
        reporter = ProblemReporter(watcher: watcher, recorder: recorder, permissions: permissions, followMute: { nil })
        #else
        let callMute = CallMuteMonitor(recorder: recorder)
        self.callMute = callMute
        reporter = ProblemReporter(watcher: watcher, recorder: recorder, permissions: permissions,
                                   followMute: { callMute.enabled })
        updates = Updates(recorder: recorder)
        #endif
        super.init()
        #if !APP_STORE
        callMute.onProblem = { [notifier] problem in
            if let problem {
                notifier.warn("Wingman isn't following your call mute", problem)
            } else {
                notifier.withdrawWarning()
            }
        }
        #endif
        shortcut.action = { [weak self] in self?.toggleRecording() }
        muteShortcut.action = { [weak self] in self?.recorder.micMuted.toggle() }
    }

    /// Wingman isn't declared menu-bar-only (LSUIElement): macOS launches those
    /// in the background, and the first-run welcome guide ended up behind other
    /// windows. It launches as a regular app instead, and switches to living in
    /// the menu bar right away once setup has been done.
    @MainActor
    func applicationWillFinishLaunching(_ notification: Notification) {
        if Self.welcomeCompleted { NSApp.setActivationPolicy(.accessory) }
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        // So a log sent from another Mac says what it came from.
        #if APP_STORE
        Log.write("Wingman \(Feedback.appVersion) started — \(Feedback.systemDescription)")
        #else
        Log.write("Wingman \(Feedback.appVersion) started — \(Feedback.systemDescription), Accessibility \(AXIsProcessTrusted() ? "on" : "off")")
        #endif
        // `kill` and `killall` send SIGTERM, which would end Wingman on the spot and
        // lose a recording in progress: quit the normal way instead, so it's
        // finished and saved first (and a downloaded update installs).
        signal(SIGTERM, SIG_IGN)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminate.setEventHandler { NSApp.terminate(nil) }
        terminate.resume()
        terminateSignal = terminate
        watcher.start()
        recorder.cleanUpAudio()
        #if !APP_STORE
        callMute.start()
        #endif
        guard !Self.welcomeCompleted else {
            Task { await recorder.prepareModels() }
            return
        }
        NSApp.activate()
        // Safety net: a first launch right after installing can be slow, so keep
        // bringing the guide forward for a few seconds until Wingman is in front.
        Task { @MainActor [weak self] in
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(600))
                guard let self, !Self.welcomeCompleted else { return }
                if NSApp.isActive, NSApp.windows.contains(where: { $0.identifier?.rawValue == "welcome" && $0.isKeyWindow }) {
                    return
                }
                self.showWelcomeIfHidden()
            }
        }
    }

    /// The updater for views; nil in App Store builds, where it doesn't exist.
    @MainActor var updatesForUI: AnyObject? {
        #if APP_STORE
        return nil
        #else
        return updates
        #endif
    }

    /// The call-mute follower for views; nil in App Store builds, where it doesn't exist.
    @MainActor var callMuteForUI: AnyObject? {
        #if APP_STORE
        return nil
        #else
        return callMute
        #endif
    }

    static var welcomeCompleted: Bool { UserDefaults.standard.bool(forKey: "welcomeCompleted") }

    /// Opens the welcome guide (set by the menu-bar label, which has SwiftUI's environment).
    @MainActor var openWelcome: (() -> Void)?

    @MainActor
    private func showWelcomeIfHidden() {
        guard !Self.welcomeCompleted else { return }
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "welcome" }), window.isVisible {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        } else {
            openWelcome?()
        }
        NSApp.activate()
    }

    /// Clicking the Dock icon, or opening Wingman again from Finder or
    /// Spotlight while it's running, opens the main window — which has
    /// everything the menu-bar menu has, for when that icon is hard to find.
    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !Self.welcomeCompleted {
            showWelcomeIfHidden()  // until setup is done, the app icon leads back to it
        } else if !flag {
            watcher.showWindow?()
        }
        return true
    }

    /// Starts or stops a manual recording (keyboard shortcut, Dock menu).
    @MainActor
    func toggleRecording() {
        if recorder.isRecording {
            Task {
                notifier.withdrawRecording()
                await recorder.stop()
                if let note = recorder.currentNote {
                    notifier.announceSaved(note.deletingPathExtension().lastPathComponent, warning: recorder.warning)
                }
            }
        } else if recorder.phase == .idle {
            Task {
                await recorder.start()
                if recorder.isRecording {
                    let name = recorder.meetingName.trimmingCharacters(in: .whitespaces)
                    notifier.announceRecording(nil, meeting: name.isEmpty ? nil : name)
                } else if recorder.lastError != nil {
                    watcher.showWindow?()
                }
            }
        }
    }

    /// Right-click menu on the Dock icon.
    @MainActor
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false  // the isEnabled values below decide
        let record = NSMenuItem(title: recorder.isRecording ? "Stop Recording" : "Start Recording",
                                action: #selector(dockToggleRecording), keyEquivalent: "")
        record.isEnabled = recorder.isRecording || recorder.phase == .idle
        menu.addItem(record)
        let mute = NSMenuItem(title: "Mute My Microphone" + (muteShortcut.shortcut.map { "  \($0.display)" } ?? ""),
                              action: #selector(dockToggleMute), keyEquivalent: "")
        mute.state = recorder.micMuted ? .on : .off
        menu.addItem(mute)
        menu.addItem(NSMenuItem(title: "Show Transcript", action: #selector(dockShowWindow), keyEquivalent: ""))
        let transcribe = NSMenuItem(title: "Transcribe a Recording…", action: #selector(dockTranscribe), keyEquivalent: "")
        transcribe.isEnabled = recorder.phase == .idle
        menu.addItem(transcribe)
        menu.addItem(NSMenuItem(title: "Open Notes Folder", action: #selector(dockOpenNotes), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Send Feedback…", action: #selector(dockSendFeedback), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(dockOpenSettings), keyEquivalent: ""))
        menu.items.forEach { $0.target = self }
        return menu
    }

    @MainActor @objc private func dockToggleRecording() { toggleRecording() }
    @MainActor @objc private func dockShowWindow() { watcher.showWindow?() }
    @MainActor @objc private func dockToggleMute() { recorder.micMuted.toggle() }
    @MainActor @objc private func dockTranscribe() {
        watcher.showWindow?()
        FileImport.choose(for: recorder)
    }
    @MainActor @objc private func dockOpenNotes() { Recorder.openNotesFolder() }
    @MainActor @objc private func dockOpenSettings() { openSettings?() }
    @MainActor @objc private func dockSendFeedback() { Feedback.show() }

    /// Opens Settings (set by the menu-bar label, which has SwiftUI's environment).
    @MainActor var openSettings: (() -> Void)?

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard recorder.phase != .idle else { return .terminateNow }
        Task {
            await recorder.finishForQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// The menu-bar icon. Being the one view that always exists, it also hooks up
/// window opening for call prompts and shows the welcome guide on first launch.
private struct MenuBarLabel: View {
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        icon
            .task {
                delegate.watcher.showWindow = {
                    openWindow(id: "transcript")
                    NSApp.activate()
                    // Activation isn't guaranteed when another app is in front
                    // (e.g. the call itself), so also order the window front.
                    DispatchQueue.main.async {
                        NSApp.windows.first { $0.identifier?.rawValue == "transcript" }?.orderFrontRegardless()
                    }
                }
                delegate.openSettings = {
                    openSettings()
                    NSApp.activate()
                }
                delegate.openWelcome = {
                    openWindow(id: "welcome")
                    NSApp.activate()
                }
            }
    }

    /// Wingman's own "W" when idle; a status symbol while recording or muted, so
    /// it's always clear at a glance whether Wingman is listening.
    @ViewBuilder private var icon: some View {
        if let symbol {
            Image(systemName: symbol)
        } else {
            Image(nsImage: MenuBarIcon.image).renderingMode(.template)
        }
    }

    private var symbol: String? {
        let recorder = delegate.recorder
        if recorder.isRecording { return recorder.effectiveMuted ? "mic.slash.circle.fill" : "record.circle.fill" }
        // Muting with the shortcut while not recording still shows, so it isn't a surprise later.
        return recorder.micMuted ? "mic.slash" : nil
    }
}

/// The app icon's "W" of audio bars (scripts/make-icon.swift, "floating" style)
/// without its blue tile, as a template image so the menu bar tints it for light
/// and dark. Keep the W's points in step with the script.
private enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 22, height: 16), flipped: false) { rect in
            let area = rect.insetBy(dx: 0.5, dy: 1)
            let count = 11
            let pitch = area.width / CGFloat(count)
            let barWidth = pitch * 0.66
            let barHeight = area.height * 0.42
            NSColor.black.setFill()
            for i in 0..<count {
                let t = CGFloat(i) / CGFloat(count - 1)
                let x = area.minX + CGFloat(i) * pitch + (pitch - barWidth) / 2
                let center = area.minY + barHeight / 2 + (area.height - barHeight) * (w(t) - 0.22) / 0.78
                NSBezierPath(roundedRect: NSRect(x: x, y: center - barHeight / 2, width: barWidth, height: barHeight),
                             xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Wingman"
        return image
    }()

    /// Height (0…1) of the W's outline at t (0…1) across it.
    private static func w(_ t: CGFloat) -> CGFloat {
        let points: [(CGFloat, CGFloat)] = [(0, 1), (0.25, 0.22), (0.5, 0.78), (0.75, 0.22), (1, 1)]
        for i in 1..<points.count where t <= points[i].0 {
            let (x0, y0) = points[i - 1], (x1, y1) = points[i]
            return y0 + (y1 - y0) * (t - x0) / (x1 - x0)
        }
        return 1
    }
}

private struct MenuContent: View {
    @Bindable var recorder: Recorder
    let watcher: CallWatcher
    let reporter: ProblemReporter
    let muteShortcut: GlobalShortcut
    /// The updater (absent in App Store builds).
    var updates: AnyObject? = nil
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if recorder.isRecording {
            Button("Stop Recording") { Task { await recorder.stop() } }
        } else {
            Button("Start Recording") {
                showWindow()
                Task { await recorder.start() }
            }
            .disabled(recorder.phase != .idle)
        }
        Button("Show Transcript") { showWindow() }
        Button("Transcribe a Recording…") {
            showWindow()
            FileImport.choose(for: recorder)
        }
        .disabled(recorder.phase != .idle)
        if let status = recorder.modelStatus {
            Text(status)
        }
        Toggle("Mute My Microphone" + (muteShortcut.shortcut.map { "  \($0.display)" } ?? ""), isOn: $recorder.micMuted)
        if recorder.isRecording, recorder.callMuteProblem != nil {
            // Also here: the window is often closed during calls. Details are in the window.
            Text("⚠︎ Not following your call mute")
        }
        Button("Open Notes Folder") { Recorder.openNotesFolder() }
        Divider()
        let calls = watcher.todaysReports
        if !calls.isEmpty {
            Menu("Report a Problem with a Call") {
                ForEach(calls) { call in
                    Button(call.menuTitle()) { reporter.report(call) }
                }
            }
        }
        Button("Send Feedback…") { Feedback.show() }
        #if !APP_STORE
        if let updates = updates as? Updates, updates.available {
            if let ready = updates.ready, !recorder.isRecording {
                Button("Restart to Install Wingman \(ready)") { updates.installAndRestart() }
            }
            Button("Check for Updates…") { updates.checkNow() }
        }
        #endif
        Button("Settings…") {
            openSettings()
            NSApp.activate()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit Wingman") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func showWindow() {
        openWindow(id: "transcript")
        NSApp.activate()
    }
}
