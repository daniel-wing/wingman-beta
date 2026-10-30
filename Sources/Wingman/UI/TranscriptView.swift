import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One meeting in the Wingman window — recording, finishing, or done: its
/// name and calendar event, the transcript, naming speakers, export and delete.
struct MeetingDetailView: View {
    @Bindable var recorder: Recorder
    let meeting: Meeting
    let watcher: CallWatcher
    let reporter: ProblemReporter
    @FocusState private var nameFocused: Bool
    @State private var find = FindState()
    @State private var walk = SpeakerWalk()
    @State private var confirmDelete = false

    /// This is the meeting being recorded.
    private var live: Bool { meeting === recorder.current }

    var body: some View {
        let rows = meeting.lines.map { TranscriptRow($0, meeting: meeting) }
        let tally = SpeakerTally.of(rows)
        VStack(spacing: 0) {
            header(tally)
            Divider()
            if find.shown { FindBar(find: find, count: find.matches(in: rows).count, allWords: find.usesAllWords(in: rows)) }
            if canRename, walk.speaker != nil {
                SpeakerBar(walk: walk, rows: rows, tally: tally, suggestions: meeting.suggestedNames,
                           rename: { meeting.rename(speaker: $0, to: $1) }, confirm: { meeting.confirmGuess(for: $0) })
            }
            TranscriptList(rows: rows, canRename: canRename, suggestions: meeting.suggestedNames,
                           rename: { meeting.rename(speaker: $0, to: $1) }, confirm: { meeting.confirmGuess(for: $0) },
                           find: find, walk: walk, live: live, hinting: meeting.labelsFinal ? nil : LineHinting(meeting)) {
                Text(live ? "Listening…" : "")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 40)
            }
            if live { MuteStatusBar(recorder: recorder) }
        }
        .focusedSceneValue(\.transcriptActions, TranscriptActions(
            find: { find.open() },
            next: { find.next(find.matches(in: rows).count) },
            previous: { find.previous(find.matches(in: rows).count) }))
        .confirmationDialog("Delete this meeting?", isPresented: $confirmDelete) {
            Button("Delete Meeting", role: .destructive) {
                recorder.notice = "Meeting deleted. " + recorder.delete(meeting)
            }
        } message: {
            Text("Its note, audio and subtitles go to the Trash, and Wingman forgets the voices it learned from it.")
        }
    }

    private func header(_ tally: SpeakerTally) -> some View {
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
                MeetingStatus(meeting: meeting)
                Spacer()
                if let note = meeting.currentNote, meeting.noteSaved {
                    Button("Show Note") { NSWorkspace.shared.activateFileViewerSelecting([note]) }
                    if meeting.stage == .done, meeting.lines.contains(where: \.isFinal) {
                        Menu("Export") {
                            Button("Subtitles (.vtt)") { export(.vtt) }
                            Button("Subtitles (.srt)") { export(.srt) }
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
                    MuteButton(recorder: recorder)
                    Button("New Note") { recorder.split(reason: .user, force: true) }
                        .help("A new call started: keep recording, into a new note from now on")
                    Button("Stop") { Task { await watcher.stopRecording() } }
                        .keyboardShortcut(".", modifiers: .command)
                } else if meeting.stage == .done {
                    Button("Delete Meeting…", role: .destructive) { confirmDelete = true }
                        .help("Move this meeting's note and audio to the Trash — for a test or a call you don't need")
                }
            }
            if live, meeting.joinable { JoinLine(recorder: recorder, meeting: meeting) }
            if live { RecordingAlerts(recorder: recorder, watcher: watcher) }
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
            Messages(notice: meeting.notice, warning: live ? (recorder.warning ?? meeting.warning) : meeting.warning,
                     error: meeting.lastError)
            if let error = meeting.noteSaveError {
                HStack {
                    Label(error, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Save Note As…") { saveNoteAs() }
                }
            }
        }
        .padding(12)
    }

    private var canRename: Bool {
        meeting.stage == .done && meeting.lines.contains(where: \.isFinal)
    }

    /// The note couldn't be saved where it belongs: keep a copy somewhere else.
    private func saveNoteAs() {
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

    private func export(_ format: SubtitleExport.Format) {
        if let url = meeting.exportSubtitles(format) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

/// The Wingman window with no meeting chosen: a big Record button, transcribing
/// a file, and what Wingman does on its own with each kind of call.
struct HomeView: View {
    let recorder: Recorder
    let watcher: CallWatcher
    let shortcut: GlobalShortcut

    var body: some View {
        ScrollView {
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
                        Text("\(app.name): \(Self.summary(watcher.policy(for: app)))")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
                Text("During a call, the Live Transcript floats over it. Meetings stay here afterwards.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
            .padding(.horizontal, 16)
        }
    }

    private static func summary(_ policy: AutoRecordPolicy) -> String {
        switch policy {
        case .automatic: return "recorded automatically"
        case .ask: return "Wingman asks first"
        case .off: return "not recorded"
        }
    }
}

/// What needs an answer or attention whatever is chosen in the Wingman window:
/// a call waiting for "Record it?", the speech models getting ready, and
/// Wingman's own notices and errors.
struct WingmanBanner: View {
    let recorder: Recorder
    let watcher: CallWatcher

    /// The question for a call waiting for an answer.
    private static func recordQuestion(for call: CallSession) -> String {
        #if !APP_STORE
        if call.isUnsureMeet { return "Looks like a Google Meet call. Record it?" }
        #endif
        return "\(call.app.callTitle) detected. Record it?"
    }

    var isEmpty: Bool {
        !(watcher.pendingCall != nil && recorder.phase == .idle)
            && !(recorder.modelStatus != nil && recorder.phase == .idle)
            && recorder.notice == nil && recorder.warning == nil && recorder.lastError == nil
    }

    var body: some View {
        if !isEmpty {
            VStack(alignment: .leading, spacing: 8) {
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
                Messages(notice: recorder.notice, warning: recorder.isRecording ? nil : recorder.warning,
                         error: recorder.lastError)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
        }
    }
}

// MARK: - Pieces shared with the Live Transcript

/// Recording (with its timer), finishing (with what's being done), or saved.
struct MeetingStatus: View {
    let meeting: Meeting

    var body: some View {
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
}

/// Wingman's own mute only. A mute followed from Teams/Zoom shows in the
/// mute status line (with "Transcribe me anyway"); mixing the two here made a
/// click meant to unmute switch Wingman's own mute on instead.
struct MuteButton: View {
    @Bindable var recorder: Recorder

    var body: some View {
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
}

/// "A new call started, so this is a new note", with the way back.
struct JoinLine: View {
    let recorder: Recorder
    let meeting: Meeting

    var body: some View {
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
}

/// Problems with capture while a meeting records.
struct RecordingAlerts: View {
    let recorder: Recorder
    let watcher: CallWatcher

    var body: some View {
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
}

/// A notice, a warning and an error, each when there is one.
struct Messages: View {
    let notice: String?
    let warning: String?
    let error: String?

    var body: some View {
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
}

/// Being muted is a state you chose, not a problem: a quiet line, with the way
/// around it for a comment of your own. Nothing when you're not muted.
struct MuteStatusBar: View {
    let recorder: Recorder
    /// One line, for the compact Live Transcript (the whole text on hover).
    var compact = false

    var body: some View {
        if recorder.micMuted {
            bar("Your microphone is muted in Wingman — only the other side is transcribed.",
                icon: "mic.slash", button: "Unmute") { recorder.micMuted = false }
        } else if recorder.isRecording, let app = recorder.callMuted {
            if recorder.callMuteIgnored {
                bar("Muted in \(app.shortName), but Wingman is transcribing you anyway — until you next mute or unmute there.",
                    icon: "text.bubble", button: "Stop") { recorder.followCallMuteAgain() }
            } else {
                bar("You're muted in \(app.shortName), so Wingman isn't transcribing you.",
                    icon: "mic.slash", button: "Transcribe me anyway",
                    help: "For a comment you want in the notes without unmuting in \(app.shortName)") {
                    recorder.transcribeDespiteCallMute()
                }
            }
        }
    }

    private func bar(_ text: String, icon: String, button: String, help: String? = nil,
                     action: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                // At most two lines, no fixed height: a never-truncate line
                // makes the window's minimum size depend on its width, which
                // the window's live resize keeps renegotiating.
                Label(text, systemImage: icon)
                    .foregroundStyle(.secondary)
                    .lineLimit(compact ? 1 : 2)
                    .help(compact ? text : "")
                Spacer(minLength: 8)
                Button(button, action: action)
                    .controlSize(.small)
                    .help(help ?? "")
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, compact ? 5 : 8)
        }
        .background(.bar)
    }
}

/// Chooses which calendar event this meeting belongs to: today's meetings,
/// nearest to now first, or none. Shows the attached event, so it's clear
/// where the name and invitees come from.
struct CalendarEventMenu: View {
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

extension SpeakerTally {
    /// Speakers of a meeting in memory still to name or confirm, by label
    /// (what renaming acts on there).
    static func of(_ rows: [TranscriptRow]) -> SpeakerTally {
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
}
