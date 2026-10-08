import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var recorder: Recorder
    @Bindable var watcher: CallWatcher
    let permissions: Permissions
    let shortcut: GlobalShortcut
    let muteShortcut: GlobalShortcut
    /// The call-mute follower (absent in App Store builds).
    var callMute: AnyObject? = nil
    /// The updater (absent in App Store builds).
    var updates: AnyObject? = nil
    @Environment(\.openWindow) private var openWindow
    /// How much space meeting audio takes now, to help pick a size limit.
    @State private var audioBytes: Int64?

    var body: some View {
        Form {
            Section {
                TextField("Your name", text: $recorder.myName, prompt: Text("Me"))
            } header: {
                Text("You")
            } footer: {
                footnote("Shown instead of \"Me\" for everything your microphone hears, in the window, notes and exports. You can still rename it for a single meeting.")
            }

            Section {
                LabeledContent("Start or stop recording") {
                    VStack(alignment: .trailing, spacing: 4) { ShortcutRecorder(shortcut: shortcut) }
                }
                LabeledContent("Mute or unmute Wingman") {
                    VStack(alignment: .trailing, spacing: 4) { ShortcutRecorder(shortcut: muteShortcut) }
                }
            } header: {
                Text("Keyboard shortcuts")
            } footer: {
                footnote("Work from any app, so you don't need to find the menu-bar icon. Click a shortcut to change it.")
            }

            Section {
                AutoRecordPickers(watcher: watcher)
                #if !APP_STORE
                MeetAccessibilityHint(watcher: watcher, permissions: permissions)
                if let monitor = callMute as? CallMuteMonitor {
                    FollowCallMuteControls(monitor: monitor, permissions: permissions)
                }
                #endif
            } header: {
                Text("Calls")
            } footer: {
                footnote(callsFooter)
            }

            Section {
                Toggle("Name meetings from my calendar", isOn: $recorder.useCalendar)
                if recorder.useCalendar && permissions.calendar != .granted {
                    HStack {
                        Text("Wingman doesn't have calendar access yet.").foregroundStyle(.secondary)
                        Spacer()
                        Button(permissions.calendar == .denied ? "Open Settings" : "Allow") {
                            if permissions.calendar == .denied {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                            } else {
                                Task { await permissions.requestCalendar() }
                            }
                        }
                    }
                }
                LabeledContent("Work calendar missing?") {
                    Button(CalendarAccounts.buttonTitle) { CalendarAccounts.openSettings() }
                }
            } header: {
                Text("Calendar")
            } footer: {
                footnote("Uses the event happening when recording starts for the meeting name, the invite details in the note, and one-click names when renaming speakers. Read-only. \(CalendarAccounts.explanation)")
            }

            PeopleSection(recorder: recorder, voices: recorder.voices)

            Section {
                LanguageToggles(recorder: recorder)
                MainLanguagePicker(recorder: recorder)
            } header: {
                Text("Languages spoken in your meetings")
            } footer: {
                footnote("Lines that come out in a language you haven't checked — say, Spanish heard as Portuguese — are re-transcribed in the closest checked language when the meeting ends, before the note and exports are saved.")
            }

            Section {
                Toggle("Save meeting audio", isOn: $recorder.keepAudio)
                Toggle("Also keep separate tracks for me and the call", isOn: $recorder.keepSeparateTracks)
                    .disabled(!recorder.keepAudio)
                Picker("Remove audio older than", selection: $recorder.removeAudioAfterDays) {
                    Text("Never").tag(0)
                    Text("1 week").tag(7)
                    Text("1 month").tag(30)
                    Text("3 months").tag(90)
                    Text("1 year").tag(365)
                }
                Toggle("Limit the space meeting audio takes", isOn: Binding(
                    get: { recorder.audioLimitGB > 0 },
                    set: { recorder.audioLimitGB = $0 ? 10 : 0 }
                ))
                if recorder.audioLimitGB > 0 {
                    LabeledContent("Keep it under") {
                        HStack(spacing: 4) {
                            TextField("Size limit", value: $recorder.audioLimitGB, format: .number)
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 56)
                            Text("GB")
                        }
                    }
                }
            } header: {
                Text("Audio")
            } footer: {
                footnote("Each meeting is saved as one small audio file with both sides mixed (about 15 MB per hour), plus your microphone and the call as separate tracks (about 30 MB per hour more), which help when checking a recording. Audio these rules remove goes to the Trash, oldest first; notes and subtitles are always kept. With Save meeting audio off, Wingman still records audio during a meeting to transcribe it, in a private folder, and deletes it once the note is saved. \(audioUsage)Headphones give the cleanest recording: with speakers your microphone also hears the other side (repeated lines are dropped from the transcript).")
            }
            .disabled(recorder.phase != .idle)
            .task(id: "\(recorder.phase == .idle) \(recorder.removeAudioAfterDays) \(recorder.audioLimitGB)") {
                await recorder.cleanupFinished()
                let folder = Recorder.notesFolder
                audioBytes = await Task.detached(priority: .utility) {
                    AudioCleanup.scan(folder).reduce(Int64(0)) { $0 + $1.bytes }
                }.value
            }

            Section("Notes") {
                LabeledContent("Saved in") {
                    Button(Recorder.notesFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                        try? Recorder.createNotesFolder()
                        NSWorkspace.shared.open(Recorder.notesFolder)
                    }
                    .buttonStyle(.link)
                }
                Button("Show Welcome Guide…") {
                    openWindow(id: "welcome")
                    NSApp.activate()
                }
            }

            Section("About") {
                LabeledContent("Version") {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                }
                Button("Acknowledgements…") {
                    openWindow(id: "acknowledgements")
                    NSApp.activate()
                }
                Button("Send Feedback…") { Feedback.show() }
                #if !APP_STORE
                if let updates = updates as? Updates, updates.available {
                    Toggle("Install updates automatically", isOn: Binding(
                        get: { updates.automatic }, set: { updates.automatic = $0 }))
                    Button("Check for Updates…") { updates.checkNow() }
                }
                #endif
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .frame(minHeight: 420, maxHeight: 720)
        .task { await permissions.refresh() }
        // Permissions are usually changed in System Settings: re-check on coming back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await permissions.refresh() }
        }
    }

    private var callsFooter: String {
        var text = permissions.notifications == .granted
            ? "When a call starts, Wingman records it or asks first. Recordings stop when the call ends."
            : "Notifications are off, so \"Ask me first\" opens the Wingman window instead of a notification."
        #if !APP_STORE
        text += " Google Meet is recognized from Chrome's tab titles (read only, nothing saved). Following your mute works in the Teams and Zoom apps, not yet in Google Meet or other browser calls. Wingman reads their mute button and never clicks or types."
        #endif
        return text
    }

    /// "Meeting audio takes 1.2 GB now. ", or nothing until it's been measured.
    private var audioUsage: String {
        guard let audioBytes else { return "" }
        return "Meeting audio takes \(ByteCountFormatter.string(fromByteCount: audioBytes, countStyle: .file)) now. "
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Recognizing people across meetings: the switch, and who's remembered.
private struct PeopleSection: View {
    @Bindable var recorder: Recorder
    let voices: VoiceLibrary
    @State private var confirmForgetAll = false

    var body: some View {
        Section {
            Toggle("Recognize people I've named", isOn: $recorder.recognizeVoices)
            if voices.people.isEmpty {
                Text(recorder.recognizeVoices
                     ? "No one yet. After a meeting, click a speaker's name and name them — Wingman will recognize their voice next time."
                     : "Off.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(voices.people.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { person in
                    PersonRow(person: person, voices: voices)
                }
                if let problem = voices.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Forget Everyone…", role: .destructive) { confirmForgetAll = true }
                    .confirmationDialog("Forget all \(voices.people.count) voices?", isPresented: $confirmForgetAll) {
                        Button("Forget Everyone", role: .destructive) { voices.forgetEveryone() }
                    } message: {
                        Text("Wingman won't recognize anyone until you name them again. Your notes aren't affected.")
                    }
            }
        } header: {
            Text("People")
        } footer: {
            Text("When you name a voice after a meeting, Wingman keeps a voiceprint — numbers describing how the voice sounds, not recordings or words — and uses it to label that person in later meetings. Voiceprints stay on this Mac. Let people know if you keep them: in some places voice data counts as biometric information.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PersonRow: View {
    let person: VoiceLibrary.Person
    let voices: VoiceLibrary
    @State private var name = ""

    var body: some View {
        HStack {
            TextField("Name", text: $name)
                .textFieldStyle(.plain)
                .onSubmit { voices.rename(person, to: name) }
            Text(person.meetings == 1 ? "1 meeting" : "\(person.meetings) meetings")
                .font(.caption).foregroundStyle(.secondary)
            Button(role: .destructive) { voices.forget(person) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Forget \(person.name)'s voice")
        }
        .onAppear { name = person.name }
    }
}

/// Wingman lives in the menu bar, but while any of its windows is open it
/// shows in Cmd+Tab and the Dock like a regular app.
enum WindowPresence {
    @MainActor static func windowOpened() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    @MainActor static func windowClosed() {
        // Let the closing window finish disappearing before counting what's left.
        DispatchQueue.main.async {
            // A minimized window counts: without the Dock it couldn't be brought back.
            let open = NSApp.windows.contains {
                ($0.isVisible || $0.isMiniaturized) && $0.styleMask.contains(.titled) && !($0 is NSPanel)
            }
            if !open { NSApp.setActivationPolicy(.accessory) }
        }
    }
}
