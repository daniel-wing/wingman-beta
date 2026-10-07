import AppKit
import SwiftUI

/// First-run guide: what Wingman does, why it asks for each permission, and
/// the choices that matter most. Skipping leaves every call app on "Ask me first".
struct WelcomeView: View {
    @Bindable var recorder: Recorder
    @Bindable var watcher: CallWatcher
    let permissions: Permissions
    var callMute: AnyObject? = nil
    let done: () -> Void

    @State private var page: Int
    private let pages = 5

    init(recorder: Recorder, watcher: CallWatcher, permissions: Permissions, callMute: AnyObject? = nil,
         startPage: Int = 0, done: @escaping () -> Void) {
        self.recorder = recorder
        self.watcher = watcher
        self.permissions = permissions
        self.callMute = callMute
        self.done = done
        _page = State(initialValue: startPage)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Pages scroll if they're taller than the window, so the buttons
            // below always stay visible.
            ScrollView {
                Group {
                    switch page {
                    case 0: intro
                    case 1: permissionsPage
                    case 2: autoRecordPage
                    case 3: aboutYouPage
                    default: finishPage
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(28)
            }
            .id(page)  // start each page at the top

            Divider()
            HStack {
                if page < pages - 1 {
                    Button("Skip setup") { finish() }
                        .help("Use the defaults: Wingman asks before recording any call. You can change everything in Settings.")
                }
                Spacer()
                HStack(spacing: 6) {
                    ForEach(0..<pages, id: \.self) { i in
                        Circle().fill(i == page ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if page > 0 { Button("Back") { page -= 1 } }
                Button(page == pages - 1 ? "Start using Wingman" : "Continue") {
                    if page == pages - 1 { finish() } else { page += 1 }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 580, height: 620)
        .task { await permissions.refresh() }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "welcomeCompleted")
        done()
    }

    // MARK: - Pages

    private var intro: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading) {
                    Text("Welcome to Wingman").font(.largeTitle.weight(.bold))
                    Text("Your meeting notes, written for you.").foregroundStyle(.secondary)
                }
            }
            point("waveform", "Live transcript", "Everything you and the other people on the call say, as it's said — in English, Spanish and more.")
            point("person.2", "Who said what", "Your words appear under your name; other voices are told apart after the meeting so you can name them.")
            point("lock.shield", "Stays on this Mac", "Recording, transcription and speaker detection all run on your Mac. Nothing is uploaded.")
            point("doc.text", "Files you own", "Each meeting is saved as a note, an audio file and optional subtitles in a folder you can open any time.")
            Text("The next steps explain each permission before macOS asks for it, so you can decide with the full picture.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Permissions").font(.title.weight(.semibold))
            Text("Wingman asks only for what it uses. Each one can be changed later in System Settings → Privacy & Security.")
                .foregroundStyle(.secondary)
            PermissionRow(
                icon: "speaker.wave.2", title: "System audio", required: true,
                why: "To transcribe the other people on the call. Wingman captures sound only — never your screen.",
                state: permissions.systemAudio, settingsPane: "Privacy_ScreenCapture",
                note: permissions.systemAudioNote
            ) { await permissions.requestSystemAudio() }
            PermissionRow(
                icon: "mic", title: "Microphone", required: true,
                why: "To transcribe what you say. Wingman only listens while it's recording.",
                state: permissions.microphone, settingsPane: "Privacy_Microphone"
            ) { await permissions.requestMicrophone() }
            PermissionRow(
                icon: "calendar", title: "Calendar", required: false,
                why: "To name meetings after the event on your calendar and offer the invited people as names. Wingman reads the Mac's Calendar app — there's no Microsoft or Google sign-in — so a work calendar (Outlook / Microsoft 365) needs to be added to your Mac first. Read-only; Wingman never changes your calendar.",
                state: permissions.calendar, settingsPane: "Privacy_Calendars",
                addsCalendarAccounts: true
            ) { await permissions.requestCalendar() }
            PermissionRow(
                icon: "bell", title: "Notifications", required: false,
                why: "To ask before recording a call it detects, and to show when it's recording with a Stop button.",
                state: permissions.notifications, settingsPane: nil
            ) { await permissions.requestNotifications() }
        }
    }

    private var autoRecordPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recording calls").font(.title.weight(.semibold))
            Text("Wingman notices when a call app starts using your microphone. Choose what happens for each.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
                ForEach(Array(CallApp.shown.enumerated()), id: \.element) { index, app in
                    if index > 0 { Divider().gridCellColumns(3) }
                    GridRow {
                        AppIcon(app: app)
                        Text(app.name)
                        Picker(app.name, selection: Binding(
                            get: { watcher.policy(for: app) },
                            set: { watcher.policies[app] = $0 }
                        )) {
                            ForEach(AutoRecordPolicy.allCases) { Text($0.name).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 200)
                        .gridColumnAlignment(.trailing)
                    }
                    .padding(.vertical, 10)
                }
            }
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
            #if !APP_STORE
            MeetAccessibilityHint(watcher: watcher, permissions: permissions)
            #endif

            VStack(alignment: .leading, spacing: 10) {
                note("bell.badge", "When Wingman starts recording, a notification with Stop and Stop & Discard appears and the menu-bar icon changes to a record symbol.")
                note("stop.circle", "Recording stops by itself when the call ends.")
                note("person.wave.2", "Let the people on the call know they're being recorded — in many places it's required.")
            }
            #if !APP_STORE
            if let monitor = callMute as? CallMuteMonitor {
                VStack(alignment: .leading, spacing: 6) {
                    FollowCallMuteControls(monitor: monitor, permissions: permissions, showsStatus: false)
                    Text("Talk to someone next to you without it landing in the transcript: when you mute in the Teams or Zoom app (button, shortcut or AirPods), Wingman stops transcribing you too. Not yet for Google Meet or other calls in a browser. Optional; needs Accessibility to read their mute button.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            #endif

            settingsReminder
        }
    }

    private var aboutYouPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("About you").font(.title.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text("Your name").font(.headline)
                TextField("Your name", text: $recorder.myName, prompt: Text("Me"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                Text("Shown instead of \"Me\" for everything your microphone hears.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Languages spoken in your meetings").font(.headline)
                LazyVGrid(columns: [GridItem(.fixed(150), alignment: .leading), GridItem(.fixed(150), alignment: .leading),
                                    GridItem(.fixed(150), alignment: .leading)], alignment: .leading, spacing: 8) {
                    LanguageToggles(recorder: recorder)
                }
                MainLanguagePicker(recorder: recorder)
                    .fixedSize()
                Text("If a line comes out in a language you didn't check — say, Spanish heard as Portuguese — it's re-transcribed in the closest checked language when the meeting ends.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Recognize people I name in later meetings", isOn: $recorder.recognizeVoices)
                    .font(.headline)
                Text("Wingman keeps a voiceprint (numbers describing how a voice sounds — not recordings) for each person you name, only on this Mac. Off by default.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            settingsReminder
        }
    }

    private var settingsReminder: some View {
        Label("You can change any of this later in Settings (⌘,).", systemImage: "gearshape")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private func note(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var finishPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("You're all set").font(.largeTitle.weight(.bold))
            point("waveform", "Find Wingman in the menu bar", "Click the waveform at the top of your screen to start or stop recording and open the transcript.")
            point("phone", "Or just start your call", "Teams and Zoom calls are picked up based on what you chose.")
            point("gearshape", "Change anything later", "Settings (⌘,) has everything from this guide, and can show it again.")
            if permissions.microphone != .granted || permissions.systemAudio != .granted {
                Label("Microphone and system audio are needed to record. You can allow them from the Permissions step or in System Settings.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
        }
    }

    private func point(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(Color.accentColor).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The app's own icon (or a globe for browsers), so each row is recognizable at a glance.
private struct AppIcon: View {
    let app: CallApp

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: symbol).resizable().scaledToFit().padding(3).foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: 28, height: 28)
    }

    private var icon: NSImage? {
        let bundleID: String? = switch app {
        case .teams: "com.microsoft.teams2"
        case .zoom: "us.zoom.xos"
        case .meet: "com.google.Chrome.app." + MeetDetection.meetAppID  // the Google Meet app, if installed
        case .browser: nil
        }
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private var symbol: String { app == .meet ? "video.fill" : "globe" }
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let required: Bool
    let why: String
    let state: Permissions.State
    let settingsPane: String?
    var note: String? = nil
    var addsCalendarAccounts = false
    let request: () async -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(Color.accentColor).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    Text(required ? "Needed" : "Optional")
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
                Text(why).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if addsCalendarAccounts {
                    Button(CalendarAccounts.buttonTitle) { CalendarAccounts.openSettings() }
                        .buttonStyle(.link)
                        .font(.callout)
                }
                if let note {
                    Label(note, systemImage: "hourglass")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control.frame(minWidth: 110, alignment: .trailing)
        }
    }

    @ViewBuilder private var control: some View {
        switch state {
        case .granted:
            Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .waiting:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Waiting…").foregroundStyle(.secondary) }
        case .denied:
            VStack(alignment: .trailing, spacing: 4) {
                Button("Open Settings") { openSettings() }
                Button("Check again") { Task { await request() } }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        case .unknown:
            Button("Allow") { Task { await request() } }
        }
    }

    private func openSettings() {
        let url = settingsPane.map { "x-apple.systempreferences:com.apple.preference.security?\($0)" }
            ?? "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}

struct AutoRecordPickers: View {
    @Bindable var watcher: CallWatcher

    static func help(for app: CallApp) -> String {
        switch app {
        #if !APP_STORE
        case .meet:
            return "Google Meet in Chrome or the Google Meet app (Edge, Brave, Arc and Opera work the same way but have had less testing). Wingman recognizes it from Chrome's tab titles, so it needs Accessibility; when it can't be sure, it asks instead of recording. In Safari or Firefox, Meet counts as a browser call."
        #endif
        case .browser:
            return "Other calls in a browser, like Teams or Zoom on the web. Wingman only sees that the browser is using the mic, so asking first is safest."
        default:
            return ""
        }
    }

    var body: some View {
        ForEach(CallApp.shown) { app in
            Picker(app.name, selection: Binding(
                get: { watcher.policy(for: app) },
                set: { watcher.policies[app] = $0 }
            )) {
                ForEach(AutoRecordPolicy.allCases) { Text($0.name).tag($0) }
            }
            .help(Self.help(for: app))
        }
    }
}

/// Wingman reads the calendars in the Mac's Calendar app instead of signing in
/// to Microsoft or Google itself. Companies that don't let apps like Wingman
/// connect to their Microsoft accounts often still allow the Mac's own Calendar,
/// so a work calendar is added there (System Settings → Internet Accounts).
enum CalendarAccounts {
    static let buttonTitle = "Add a Work Calendar to Your Mac…"
    static let explanation = "Wingman reads the Mac's Calendar app and never asks you to sign in to Microsoft or Google. To use a work calendar (Outlook / Microsoft 365), add the account to your Mac: System Settings → Internet Accounts → Add Account → Microsoft Exchange, sign in, and turn on Calendars. That often works even when your company doesn't let other apps connect to your Microsoft account. Once its meetings show in the Calendar app, Wingman sees them too."

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!)
    }
}

struct LanguageToggles: View {
    @Bindable var recorder: Recorder

    var body: some View {
        ForEach(SpokenLanguage.allCases) { language in
            Toggle(language.name, isOn: Binding(
                get: { recorder.enabledLanguages.contains(language) },
                set: { on in
                    if on { recorder.enabledLanguages.insert(language) } else { recorder.enabledLanguages.remove(language) }
                }
            ))
            .disabled(recorder.enabledLanguages == [language])
        }
    }
}

/// Kept apart from `LanguageToggles` so the welcome guide can place it below its
/// grid of fixed columns, which cut the menu down to "E…".
struct MainLanguagePicker: View {
    @Bindable var recorder: Recorder

    var body: some View {
        if recorder.enabledLanguages.count > 1 {
            Picker("Main language", selection: $recorder.mainLanguage) {
                ForEach(SpokenLanguage.allCases.filter(recorder.enabledLanguages.contains)) { language in
                    Text(language.name).tag(language)
                }
            }
            .help("The language most of your meetings are in. When a line is too short or unclear to tell, the review after the meeting writes it in this language.")
        }
    }
}
