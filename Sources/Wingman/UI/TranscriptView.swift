import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TranscriptView: View {
    @Bindable var recorder: Recorder
    let watcher: CallWatcher
    let reporter: ProblemReporter
    let shortcut: GlobalShortcut
    @FocusState private var nameFocused: Bool
    @Environment(\.openSettings) private var openSettings

    /// The in-window question for a call waiting for an answer.
    private static func recordQuestion(for call: CallSession) -> String {
        #if !APP_STORE
        if call.isUnsureMeet { return "Looks like a Google Meet call. Record it?" }
        #endif
        return "\(call.app.callTitle) detected. Record it?"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            muteStatus
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard recorder.phase == .idle, let url = urls.first,
                  let type = UTType(filenameExtension: url.pathExtension),
                  FileImport.types.contains(where: { type.conforms(to: $0) })
            else { return false }
            Task { await recorder.transcribeFile(url) }
            return true
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { FileImport.choose(for: recorder) } label: {
                    Label("Transcribe a Recording", systemImage: "doc.badge.plus")
                }
                .help("Transcribe a meeting recording or video file")
                .disabled(recorder.phase != .idle)
                Button { Recorder.openNotesFolder() } label: {
                    Label("Notes Folder", systemImage: "folder")
                }
                .help("Open the folder with all your meeting notes")
                Button { openSettings() } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings (⌘,)")
            }
        }
    }

    /// Shown in place of the transcript before anything is recorded: a big
    /// Record button and what Wingman will do on its own.
    private var emptyState: some View {
        VStack(spacing: 14) {
            Button {
                Task { await recorder.start() }
            } label: {
                Label("Start Recording", systemImage: "record.circle")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(recorder.phase != .idle)
            if let keys = shortcut.shortcut?.display {
                Text("or press \(keys) from any app").font(.callout).foregroundStyle(.secondary)
            }
            Button("Transcribe a recording or video file…") { FileImport.choose(for: recorder) }
                .buttonStyle(.link)
                .disabled(recorder.phase != .idle)
            Text("You can also drop a file here.").font(.caption).foregroundStyle(.tertiary)
            VStack(spacing: 4) {
                ForEach(CallApp.shown) { app in
                    Text("\(app.name): \(summary(watcher.policy(for: app)))")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func summary(_ policy: AutoRecordPolicy) -> String {
        switch policy {
        case .automatic: return "recorded automatically"
        case .ask: return "Wingman asks first"
        case .off: return "not recorded"
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Name this meeting", text: $recorder.meetingName)
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                    .focused($nameFocused)
                    .onSubmit { recorder.applyMeetingName() }
                    .onChange(of: nameFocused) { _, focused in
                        if !focused { recorder.applyMeetingName() }
                    }
                CalendarEventMenu(recorder: recorder)
            }
            .disabled(isBusy)
            if let meeting = recorder.meeting {
                MeetingDetails(meeting: meeting, invitees: recorder.invitees)
            }
            HStack {
                status
                Spacer()
                if let note = recorder.currentNote {
                    Button("Show Note") { NSWorkspace.shared.activateFileViewerSelecting([note]) }
                    if recorder.phase == .idle, recorder.lines.contains(where: \.isFinal) {
                        Menu("Export") {
                            Button("Subtitles (.vtt)") { export(.vtt) }
                            Button("Subtitles (.srt)") { export(.srt) }
                        }
                        .fixedSize()
                    }
                    if recorder.phase == .idle, let call = watcher.report(forNote: note) {
                        Button { reporter.report(call) } label: { Image(systemName: "exclamationmark.bubble") }
                            .buttonStyle(.borderless)
                            .help("Report a problem with this call")
                    }
                }
                muteButton
                recordButton
            }
            if recorder.systemMuted && !recorder.micMuted {
                HStack {
                    Label("macOS has muted Wingman's microphone — for example with an AirPods press. Your words aren't being transcribed.", systemImage: "mic.slash.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Unmute") { recorder.clearSystemMute() }
                }
                .font(.callout)
            }
            if recorder.callAudioMissing {
                Label("No call audio heard for a minute. If the other side is talking, allow Wingman in System Settings → Privacy & Security → Screen & System Audio Recording (System Audio Recording Only), then start a new recording.", systemImage: "speaker.slash.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if recorder.micSilent && !(recorder.systemMuted && !recorder.micMuted) {
                Label("Your microphone has sent only silence for over 30 seconds. If you're speaking, check that it isn't muted in macOS or on your headset.", systemImage: "mic.badge.xmark")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if recorder.callMuted == nil, let problem = recorder.callMuteProblem ?? recorder.callMuteNote, recorder.isRecording {
                Label(problem, systemImage: "eye.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if canRename {
                Text("Click a speaker's name to change it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let call = watcher.pendingCall, recorder.phase == .idle {
                HStack {
                    Label(Self.recordQuestion(for: call), systemImage: "phone.fill")
                    Spacer()
                    Button("Ignore") { watcher.answerPending(record: false) }
                    Button("Record") { watcher.answerPending(record: true) }
                        .buttonStyle(.borderedProminent)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
            }
            if let status = recorder.modelStatus, recorder.phase == .idle {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(status).foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            if let notice = recorder.notice {
                Label(notice, systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            if let warning = recorder.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            if let error = recorder.lastError {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
    }

    /// Being muted is a state you chose, not a problem: a quiet line at the
    /// bottom of the window, with the way around it for a comment of your own.
    @ViewBuilder private var muteStatus: some View {
        if recorder.micMuted {
            statusBar("Your microphone is muted in Wingman — only the other side is transcribed.",
                      icon: "mic.slash", button: "Unmute") { recorder.micMuted = false }
        } else if recorder.isRecording, let app = recorder.callMuted {
            if recorder.callMuteIgnored {
                statusBar("Muted in \(app.shortName), but Wingman is transcribing you anyway — until you next mute or unmute there.",
                          icon: "text.bubble", button: "Stop") { recorder.followCallMuteAgain() }
            } else {
                statusBar("You're muted in \(app.shortName), so Wingman isn't transcribing you.",
                          icon: "mic.slash", button: "Transcribe me anyway",
                          help: "For a comment you want in the notes without unmuting in \(app.shortName)") {
                    recorder.transcribeDespiteCallMute()
                }
            }
        }
    }

    private func statusBar(_ text: String, icon: String, button: String, help: String? = nil,
                           action: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Label(text, systemImage: icon)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(button, action: action)
                    .controlSize(.small)
                    .help(help ?? "")
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private var isBusy: Bool {
        switch recorder.phase {
        case .preparing, .finishing: return true
        default: return false
        }
    }

    private var canRename: Bool {
        recorder.phase == .idle && recorder.lines.contains(where: \.isFinal)
    }

    private func export(_ format: SubtitleExport.Format) {
        if let url = recorder.exportSubtitles(format) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    @ViewBuilder private var status: some View {
        switch recorder.phase {
        case .idle:
            Text(recorder.lines.isEmpty ? "Ready" : "Stopped").foregroundStyle(.secondary)
        case .preparing(let message):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(message).foregroundStyle(.secondary)
            }
        case .recording:
            if let start = recorder.startedAt {
                Label {
                    Text(start, style: .timer).monospacedDigit()
                } icon: {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                }
            }
        case .finishing(let message):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(message).foregroundStyle(.secondary)
            }
        }
    }

    /// Wingman's own mute only. A mute followed from Teams/Zoom shows in the
    /// status bar at the bottom (with "Transcribe me anyway"); mixing the two here made a click
    /// meant to unmute switch Wingman's own mute on instead.
    private var muteButton: some View {
        Button {
            recorder.micMuted.toggle()
        } label: {
            Image(systemName: recorder.micMuted ? "mic.slash.fill" : "mic.fill")
                .foregroundStyle(recorder.micMuted ? Color.orange : Color.primary)
        }
        .help(recorder.micMuted ? "Unmute your microphone in Wingman" : "Mute your microphone in Wingman — e.g. while playing a recorded call")
    }

    @ViewBuilder private var recordButton: some View {
        if recorder.isRecording {
            Button("Stop") { Task { await recorder.stop() } }
                .keyboardShortcut(".", modifiers: .command)
        } else {
            Button("Record") { Task { await recorder.start() } }
                .buttonStyle(.borderedProminent)
                .disabled(recorder.phase != .idle)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if recorder.lines.isEmpty {
                        if recorder.phase == .idle {
                            emptyState
                        } else {
                            Text(recorder.isRecording ? "Listening…" : "")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 40)
                        }
                    }
                    ForEach(recorder.lines) { line in
                        LineView(
                            line: line,
                            name: recorder.displayName(line),
                            canRename: canRename,
                            suggestions: recorder.suggestedNames,
                            guess: recorder.guess(for: line.label),
                            recognized: recorder.isRecognized(line.label),
                            rename: { recorder.rename(speaker: line.label, to: $0) },
                            confirmGuess: { recorder.confirmGuess(for: line.label) }
                        )
                        .id(line.id)
                    }
                }
                .padding(12)
                .textSelection(.enabled)
            }
            .onChange(of: recorder.lines.last?.text) {
                if let last = recorder.lines.last {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }
}

private struct LineView: View {
    let line: TranscriptLine
    let name: String
    let canRename: Bool
    let suggestions: [String]
    let guess: String?
    let recognized: Bool
    let rename: (String) -> Void
    let confirmGuess: () -> Void
    @State private var editing = false

    private static let voiceColors: [Color] = [.green, .orange, .purple, .pink, .teal, .yellow, .red, .mint]

    private var color: Color {
        if line.speaker == .me { return .accentColor }
        guard let voice = line.voice else { return .green }
        return Self.voiceColors[(voice - 1) % Self.voiceColors.count]
    }

    @ViewBuilder private var speaker: some View {
        let label = Text(name)
            .font(.callout.weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
        if canRename {
            Button { editing = true } label: { label }
                .buttonStyle(.plain)
                .help("Rename \(name)")
                .popover(isPresented: $editing, arrowEdge: .bottom) {
                    RenameSpeaker(original: line.label, current: name, suggestions: suggestions,
                                  guess: guess, recognized: recognized,
                                  confirm: { confirmGuess(); editing = false }) { newName in
                        rename(newName)
                        editing = false
                    }
                }
        } else {
            label
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Recorder.timestamp(line.start))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            speaker
                .frame(width: 90, alignment: .leading)
            Text(line.text)
                .foregroundStyle(line.isFinal && !line.isUnclear ? .primary : .secondary)
                .italic(!line.isFinal)
                .frame(maxWidth: .infinity, alignment: .leading)
            if line.isUnclear {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(.orange)
                    .help("Wingman wasn't sure about this line (confidence \(Int(line.confidence * 100))%). Check it against the audio.")
            }
        }
    }
}

/// Popover for giving a speaker label a real name. Applies to every line
/// with that label.
private struct RenameSpeaker: View {
    let original: String
    let current: String
    let suggestions: [String]
    var guess: String? = nil
    var recognized = false
    var confirm: () -> Void = {}
    let done: (String) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let guess {
                Text("Is this \(guess)?").font(.headline)
                Text("This voice sounds like \(guess) from an earlier meeting.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Yes, it's \(guess)") { confirm() }
                    .buttonStyle(.borderedProminent)
                Divider()
                Text("Or name them:").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Rename \(original)").font(.headline)
                if recognized {
                    Label("Recognized by voice from an earlier meeting", systemImage: "checkmark.seal")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !suggestions.isEmpty {
                Text("Invited to this meeting").font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(suggestions, id: \.self) { name in
                        Button(name) { done(name) }
                            .buttonStyle(.plain)
                            .padding(.vertical, 2)
                    }
                }
                Divider()
            }
            TextField(original, text: $text)
                .frame(width: 220)
                .onSubmit { done(text) }
            HStack {
                if current != original {
                    Button("Reset") { done("") }
                }
                Spacer()
                Button("Rename") { done(text) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .onAppear { text = current == original || guess != nil ? "" : current }
    }
}

/// Chooses which calendar event this meeting belongs to: today's meetings,
/// nearest to now first, or none. Shows the attached event, so it's clear
/// where the name and invitees come from.
private struct CalendarEventMenu: View {
    let recorder: Recorder
    @State private var meetings: [MeetingInfo] = []

    var body: some View {
        Menu {
            if !recorder.useCalendar {
                Text("Calendar is off — turn it on in Settings → Calendar")
            } else if !CalendarLookup.isAuthorized {
                Text("Wingman can't read your calendar — allow it in Settings → Calendar")
            } else if meetings.isEmpty {
                Text("No meetings with invitees or a call link today in the Calendar app")
            } else {
                Section("Today's meetings") {
                    ForEach(meetings) { meeting in
                        Button {
                            recorder.attach(meeting)
                        } label: {
                            if meeting.id == recorder.meeting?.id {
                                Label(title(meeting), systemImage: "checkmark")
                            } else {
                                Text(title(meeting))
                            }
                        }
                    }
                }
            }
            if recorder.meeting != nil {
                Divider()
                Button("No calendar event") { recorder.attach(nil) }
            }
            // Wingman reads the Mac's Calendar app: a missing work calendar is
            // added there, never signed in to here.
            if recorder.useCalendar {
                Divider()
                Button(CalendarAccounts.buttonTitle) { CalendarAccounts.openSettings() }
            }
        } label: {
            Label(recorder.meeting == nil ? "Calendar" : timeRange(recorder.meeting!), systemImage: "calendar")
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(recorder.meeting == nil
              ? "Link this meeting to one on your calendar — its name, invitees and link"
              : "Linked to “\(recorder.meeting!.title)” on your calendar. Click to change.")
        // Refresh when the list is likely to have changed (and every few minutes,
        // as its order follows the time of day), not on every redraw.
        .task {
            while !Task.isCancelled {
                meetings = CalendarLookup.todaysMeetings(meetCode: recorder.callMeetingCode)
                try? await Task.sleep(for: .seconds(180))
            }
        }
        .onChange(of: recorder.phase) { meetings = CalendarLookup.todaysMeetings(meetCode: recorder.callMeetingCode) }
        .onChange(of: recorder.meeting?.id) { meetings = CalendarLookup.todaysMeetings(meetCode: recorder.callMeetingCode) }
    }

    private func title(_ meeting: MeetingInfo) -> String {
        "\(timeRange(meeting))  \(meeting.title.isEmpty ? "Untitled event" : meeting.title)"
    }

    private func timeRange(_ meeting: MeetingInfo) -> String {
        "\(meeting.start.formatted(date: .omitted, time: .shortened))–\(meeting.end.formatted(date: .omitted, time: .shortened))"
    }
}

/// One line of calendar details under the meeting name; invitees expand on
/// click, with ✓ next to people already matched to a speaker.
private struct MeetingDetails: View {
    let meeting: MeetingInfo
    let invitees: [(name: String, matched: Bool)]
    @State private var showInvitees = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let organizer = meeting.organizer {
                    Text("Organizer: \(organizer)").lineLimit(1)
                    Text("·")
                }
                if !invitees.isEmpty {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { showInvitees.toggle() }
                    } label: {
                        Label("\(invitees.count) invited", systemImage: showInvitees ? "chevron.down" : "chevron.right")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain)
                    .help(showInvitees ? "Hide invitees" : "Show invitees")
                }
                if let link = meeting.link {
                    Text("·")
                    Link("Meeting link", destination: link)
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if showInvitees {
                // Scrolls only when long; a short list takes just the room it needs.
                if invitees.count > 12 {
                    ScrollView { inviteeGrid }.frame(maxHeight: 110)
                } else {
                    inviteeGrid
                }
            }
        }
    }

    private var inviteeGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 4) {
            ForEach(invitees, id: \.name) { person in
                Label(person.name, systemImage: person.matched ? "checkmark.circle.fill" : "person")
                    .foregroundStyle(person.matched ? Color.green : Color.secondary)
                    .lineLimit(1)
                    .help(person.matched ? "Named as a speaker in this meeting" : "Not matched to a speaker yet")
            }
        }
        .font(.caption)
    }
}
