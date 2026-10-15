import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A meeting's window — recording, finishing, or done — or, without a meeting,
/// Wingman's home window: Start Recording, transcribing a file, and how calls
/// are handled. Each call gets its own window, so naming speakers in one isn't
/// interrupted by the next.
struct TranscriptView: View {
    @Bindable var recorder: Recorder
    /// The meeting this window shows; nil for the home window.
    let meeting: Meeting?
    let watcher: CallWatcher
    let reporter: ProblemReporter
    let shortcut: GlobalShortcut
    @FocusState private var nameFocused: Bool
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var find = FindState()
    @State private var walk = SpeakerWalk()
    @State private var confirmDelete = false

    /// The in-window question for a call waiting for an answer.
    private static func recordQuestion(for call: CallSession) -> String {
        #if !APP_STORE
        if call.isUnsureMeet { return "Looks like a Google Meet call. Record it?" }
        #endif
        return "\(call.app.callTitle) detected. Record it?"
    }

    /// This window's meeting is the one being recorded.
    private var live: Bool { meeting != nil && meeting === recorder.current }

    var body: some View {
        let rows = (meeting?.lines ?? []).map { TranscriptRow($0, meeting: meeting!) }
        let tally = Self.tally(rows)
        VStack(spacing: 0) {
            if let meeting { header(meeting, tally) } else { home }
            Divider()
            if find.shown { FindBar(find: find, count: find.matches(in: rows).count, allWords: find.usesAllWords(in: rows)) }
            if canRename, walk.speaker != nil, let meeting {
                SpeakerBar(walk: walk, rows: rows, tally: tally, suggestions: meeting.suggestedNames,
                           rename: { meeting.rename(speaker: $0, to: $1) }, confirm: { meeting.confirmGuess(for: $0) })
            }
            if meeting != nil { transcript(rows) } else { ScrollView { emptyState } }
            if live { muteStatus }
        }
        .focusedSceneValue(\.transcriptActions, TranscriptActions(
            find: { find.open() },
            next: { find.next(find.matches(in: rows).count) },
            previous: { find.previous(find.matches(in: rows).count) }))
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
                Button { openWindow(id: "meetings") } label: {
                    Label("Meetings", systemImage: "list.bullet.rectangle")
                }
                .help("Past meetings: name speakers after the meeting")
                TextSizeMenu()
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
        .confirmationDialog("Delete this meeting?", isPresented: $confirmDelete) {
            Button("Delete Meeting", role: .destructive) {
                guard let meeting else { return }
                recorder.notice = "Meeting deleted. " + recorder.delete(meeting)
            }
        } message: {
            Text("Its note, audio and subtitles go to the Trash, and Wingman forgets the voices it learned from it.")
        }
        .onDisappear { if let meeting { recorder.windowClosed(meeting) } }
    }

    // MARK: - Home

    private var home: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                homeStatus
                Spacer()
                muteButton
                if recorder.isRecording, let current = recorder.current {
                    Button("Show Recording") { recorder.showMeeting?(current) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Record") { Task { await recorder.start() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(recorder.phase != .idle)
                }
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
            messages(notice: recorder.notice, warning: recorder.warning, error: recorder.lastError)
        }
        .padding(12)
    }

    @ViewBuilder private var homeStatus: some View {
        switch recorder.phase {
        case .idle:
            Text("Ready").foregroundStyle(.secondary)
        case .preparing(let message), .finishing(let message):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(message).foregroundStyle(.secondary)
            }
        case .recording:
            Label("Recording", systemImage: "record.circle.fill").foregroundStyle(.red)
        }
    }

    /// Shown in the home window: a big Record button and what Wingman will do on its own.
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
            Text("Each call opens in its own window.").font(.caption).foregroundStyle(.tertiary)
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

    /// Speakers still to name or confirm, by label (what renaming acts on here).
    static func tally(_ rows: [TranscriptRow]) -> SpeakerTally {
        var tally = SpeakerTally(speakers: [], meName: nil)
        var seen = Set<String>()
        for row in rows where row.isFinal && !row.isMe && seen.insert(row.speakerKey).inserted {
            if row.guess != nil {
                tally.toConfirm.append(row.speakerKey)
            } else if row.name == row.speakerKey {
                tally.toName.append(row.speakerKey)
            } else {
                tally.named += 1
            }
        }
        return tally
    }

    // MARK: - A meeting

    private func header(_ meeting: Meeting, _ tally: SpeakerTally) -> some View {
        @Bindable var meeting = meeting
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Name this meeting", text: $meeting.meetingName)
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                    .focused($nameFocused)
                    .onSubmit { meeting.applyMeetingName() }
                    .onChange(of: nameFocused) { _, focused in
                        if !focused { meeting.applyMeetingName() }
                    }
                CalendarEventMenu(recorder: recorder, meeting: meeting)
            }
            .disabled(meeting.stage.isFinishing)
            if let event = meeting.meeting {
                MeetingDetails(meeting: event, invitees: meeting.invitees)
            }
            HStack {
                status(meeting)
                Spacer()
                if let note = meeting.currentNote, meeting.noteSaved {
                    Button("Show Note") { NSWorkspace.shared.activateFileViewerSelecting([note]) }
                    if meeting.stage == .done, meeting.lines.contains(where: \.isFinal) {
                        Menu("Export") {
                            Button("Subtitles (.vtt)") { export(meeting, .vtt) }
                            Button("Subtitles (.srt)") { export(meeting, .srt) }
                        }
                        .fixedSize()
                    }
                    if meeting.stage == .done, let call = watcher.report(forNote: note) {
                        Button { reporter.report(call) } label: { Image(systemName: "exclamationmark.bubble") }
                            .buttonStyle(.borderless)
                            .help("Report a problem with this call")
                            .accessibilityLabel("Report a problem with this call")
                    }
                }
                if live {
                    muteButton
                    Button("New Note") { recorder.split(reason: .user, force: true) }
                        .help("A new call started: keep recording, into a new note from now on")
                    Button("Stop") { Task { await watcher.stopRecording() } }
                        .keyboardShortcut(".", modifiers: .command)
                } else if meeting.stage == .done {
                    Button("Delete Meeting…", role: .destructive) { confirmDelete = true }
                        .help("Move this meeting's note and audio to the Trash — for a test or a call you don't need")
                }
            }
            if live, meeting.joinable {
                HStack {
                    Label("A new call started, so this is a new note.", systemImage: "rectangle.split.2x1")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Join with Previous") { recorder.join(meeting) }
                        .controlSize(.small)
                        .help("It was the same call: put this back into the previous note")
                }
                .font(.callout)
            }
            if live { recordingAlerts }
            if canRename {
                if tally.isDone && tally.named == 0 {
                    Text("Click a speaker's name to change it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    TallyLine(tally: tally) { walk.start(tally) }
                }
            }
            if let different = meeting.differentVoice {
                HStack {
                    Label("This voice doesn't sound like the \(different.name) Wingman knows, so it wasn't learned.", systemImage: "person.2")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Learn as a Different \(different.name)") { meeting.learnAsDifferentPerson() }
                        .controlSize(.small)
                }
                .font(.callout)
            }
            messages(notice: meeting.notice, warning: live ? (recorder.warning ?? meeting.warning) : meeting.warning,
                     error: meeting.lastError)
            if let error = meeting.noteSaveError {
                HStack {
                    Label(error, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Save Note As…") { saveNoteAs(meeting) }
                }
            }
        }
        .padding(12)
    }

    /// Problems with capture while this meeting records.
    @ViewBuilder private var recordingAlerts: some View {
        if recorder.systemMuted && !recorder.micMuted {
            HStack {
                Label("macOS has muted Wingman's microphone — for example with an AirPods press. Your words aren't being transcribed.", systemImage: "mic.slash.fill")
                    .foregroundStyle(.orange)
                Spacer()
                Button("Unmute") { recorder.clearSystemMute() }
            }
            .font(.callout)
        }
        if watcher.detectionUncertain {
            Label("Wingman can't tell whether the call is still going, so it keeps recording until you stop it.", systemImage: "questionmark.circle")
                .font(.callout)
                .foregroundStyle(.orange)
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
        if recorder.callMuted == nil, let problem = recorder.callMuteProblem ?? recorder.callMuteNote {
            Label(problem, systemImage: "eye.slash")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func messages(notice: String?, warning: String?, error: String?) -> some View {
        if let notice {
            Label(notice, systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
        if let warning {
            Label(warning, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
                .textSelection(.enabled)
        }
        if let error {
            Label(error, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.callout)
                .textSelection(.enabled)
        }
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
                // At most two lines, no fixed height: a never-truncate line
                // makes the window's minimum size depend on its width, which
                // the window's live resize keeps renegotiating.
                Label(text, systemImage: icon)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
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

    private var canRename: Bool {
        guard let meeting else { return false }
        return meeting.stage == .done && meeting.lines.contains(where: \.isFinal)
    }

    /// The note couldn't be saved where it belongs: keep a copy somewhere else.
    private func saveNoteAs(_ meeting: Meeting) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = meeting.currentNote?.lastPathComponent ?? "Meeting.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try meeting.saveNoteCopy(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func export(_ meeting: Meeting, _ format: SubtitleExport.Format) {
        if let url = meeting.exportSubtitles(format) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    @ViewBuilder private func status(_ meeting: Meeting) -> some View {
        switch meeting.stage {
        case .recording:
            if let start = meeting.startedAt {
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
        case .done:
            Text("Saved").foregroundStyle(.secondary)
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
        .accessibilityLabel(recorder.micMuted ? "Unmute microphone" : "Mute microphone")
        .accessibilityValue(recorder.micMuted ? "Your microphone is muted in Wingman" : "Your microphone is being transcribed")
    }

    private func transcript(_ rows: [TranscriptRow]) -> some View {
        TranscriptList(rows: rows, canRename: canRename, suggestions: meeting?.suggestedNames ?? [],
                       rename: { meeting?.rename(speaker: $0, to: $1) }, confirm: { meeting?.confirmGuess(for: $0) },
                       find: find, walk: walk, live: live) {
            Text(live ? "Listening…" : "")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 40)
        }
    }
}

/// Chooses which calendar event this meeting belongs to: today's meetings,
/// nearest to now first, or none. Shows the attached event, so it's clear
/// where the name and invitees come from.
private struct CalendarEventMenu: View {
    let recorder: Recorder
    let meeting: Meeting
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
                    ForEach(meetings) { event in
                        Button {
                            meeting.attach(event)
                        } label: {
                            if event.id == meeting.meeting?.id {
                                Label(title(event), systemImage: "checkmark")
                            } else {
                                Text(title(event))
                            }
                        }
                    }
                }
            }
            if meeting.meeting != nil {
                Divider()
                Button("No calendar event") { meeting.attach(nil) }
            }
            // Wingman reads the Mac's Calendar app: a missing work calendar is
            // added there, never signed in to here.
            if recorder.useCalendar {
                Divider()
                Button(CalendarAccounts.buttonTitle) { CalendarAccounts.openSettings() }
            }
        } label: {
            Label(meeting.meeting == nil ? "Calendar" : timeRange(meeting.meeting!), systemImage: "calendar")
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(meeting.meeting == nil
              ? "Link this meeting to one on your calendar — its name, invitees and link"
              : "Linked to “\(meeting.meeting!.title)” on your calendar. Click to change.")
        // Refresh when the list is likely to have changed (and every few minutes,
        // as its order follows the time of day), not on every redraw.
        .task {
            while !Task.isCancelled {
                meetings = CalendarLookup.todaysMeetings(meetCode: meeting.callMeetingCode)
                try? await Task.sleep(for: .seconds(180))
            }
        }
        .onChange(of: meeting.stage) { meetings = CalendarLookup.todaysMeetings(meetCode: meeting.callMeetingCode) }
        .onChange(of: meeting.meeting?.id) { meetings = CalendarLookup.todaysMeetings(meetCode: meeting.callMeetingCode) }
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
