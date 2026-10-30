import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What the Wingman window shows.
enum WingmanSelection: Hashable {
    /// A meeting in memory: recording, finishing, or done recently.
    case meeting(UUID)
    /// A saved note.
    case note(URL)
}

/// Which meeting the Wingman window shows, set from anywhere: a new recording,
/// a notification, the Live Transcript's "Open in Wingman".
@MainActor
@Observable
final class WingmanNavigation {
    var selection: WingmanSelection?
    /// What Wingman chose itself, so it may move on to the next call.
    private var followed: WingmanSelection?

    /// A meeting Wingman started (a recording, a split): shown only when the
    /// window shows nothing the user chose, so naming speakers in one meeting
    /// isn't interrupted by the next call.
    func follow(_ id: UUID) {
        guard selection == nil || selection == followed else { return }
        selection = .meeting(id)
        followed = selection
    }

    /// Something the user asked to see.
    func show(_ target: WingmanSelection) {
        selection = target
        followed = nil
    }

    /// A meeting went away (deleted, discarded, joined).
    func forget(_ id: UUID) {
        guard selection == .meeting(id) else { return }
        selection = nil
        followed = nil
    }
}

/// The Wingman window's list: calls going on now, then meetings by day. Pure,
/// so the merging of meetings in memory with saved notes can be tested.
enum WingmanSidebar {
    enum Badge: Equatable {
        case recording(Date?)
        case saving
        case readOnly(String)
        case toName(Int)
        case toConfirm(Int)
        case named
        case none
    }

    struct Row: Identifiable, Equatable {
        let id: WingmanSelection
        let title: String
        let time: Date?
        let badge: Badge
    }

    struct Day: Identifiable, Equatable {
        var id: String { day }
        let day: String
        let rows: [Row]
    }

    /// A meeting in memory.
    struct Open: Equatable {
        let id: UUID
        let note: URL?
        let title: String
        let started: Date?
        let stage: Meeting.Stage
        /// Speakers left to name, once it's done.
        let tally: SpeakerTally?
    }

    struct Sections: Equatable {
        var now: [Row] = []
        var days: [Day] = []
    }

    /// One row per meeting: a meeting in memory replaces its saved note's row,
    /// so it keeps one row (and its selection) from recording to done.
    static func sections(entries: [MeetingsStore.Entry], open: [Open], onlyToName: Bool,
                         today: String = Recorder.dayFolderName(for: Date())) -> Sections {
        var sections = Sections()
        var byDay: [String: [Row]] = [:]
        let openNotes = Set(open.compactMap { $0.note?.standardizedFileURL })
        for meeting in open {
            switch meeting.stage {
            case .recording:
                sections.now.append(Row(id: .meeting(meeting.id), title: meeting.title, time: meeting.started,
                                        badge: .recording(meeting.started)))
            case .finishing:
                sections.now.append(Row(id: .meeting(meeting.id), title: meeting.title, time: meeting.started, badge: .saving))
            case .done:
                if onlyToName, meeting.tally?.isDone ?? true { continue }
                let day = meeting.started.map(Recorder.dayFolderName(for:)) ?? today
                byDay[day, default: []].append(Row(id: .meeting(meeting.id), title: meeting.title, time: meeting.started,
                                                   badge: badge(meeting.tally, readOnly: nil)))
            }
        }
        for entry in entries where !openNotes.contains(entry.url.standardizedFileURL) {
            if onlyToName, entry.tally.isDone { continue }
            byDay[entry.day, default: []].append(Row(id: .note(entry.url), title: entry.title, time: entry.time,
                                                     badge: badge(entry.tally, readOnly: entry.readOnly?.reason)))
        }
        sections.days = byDay.sorted { $0.key > $1.key }.map { day, rows in
            Day(day: day, rows: rows.sorted { ($0.time ?? .distantPast) > ($1.time ?? .distantPast) })
        }
        return sections
    }

    static func badge(_ tally: SpeakerTally?, readOnly: String?) -> Badge {
        if let readOnly { return .readOnly(readOnly) }
        guard let tally else { return .none }
        if !tally.toName.isEmpty { return .toName(tally.toName.count) }
        if !tally.toConfirm.isEmpty { return .toConfirm(tally.toConfirm.count) }
        return tally.named > 0 ? .named : .none
    }

    static func dayTitle(_ day: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: day) else { return day }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

/// The Wingman window: every meeting (the call going on now, then the last
/// two weeks), and for the one chosen everything about it. With none chosen,
/// what starts a recording. The live call itself floats in the Live Transcript.
struct WingmanWindowView: View {
    let recorder: Recorder
    let watcher: CallWatcher
    let reporter: ProblemReporter
    let shortcut: GlobalShortcut
    let store: MeetingsStore
    @Bindable var nav: WingmanNavigation
    let showLive: () -> Void
    @State private var onlyToName = false
    @State private var dropRefused = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            VStack(spacing: 0) {
                WingmanBanner(recorder: recorder, watcher: watcher)
                detail
            }
        }
        .toolbar { toolbar }
        .task { await store.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await store.refresh() }
        }
        .onChange(of: recorder.phase) { if recorder.phase == .idle { Task { await store.refresh() } } }
        .onChange(of: nav.selection) { recorder.trimDone() }
        // A meeting deleted here (or its note removed elsewhere) leaves the detail.
        .onChange(of: store.entries.map(\.url)) {
            if case .note(let url) = nav.selection, !FileManager.default.fileExists(atPath: url.path) { nav.selection = nil }
        }
        // A note dropped from Finder opens like one chosen with Open…; a
        // recording or video file is transcribed.
        .dropDestination(for: URL.self) { urls, _ in
            guard urls.count == 1, let url = urls.first, url.isFileURL else {
                dropRefused = true
                return false
            }
            if url.pathExtension.lowercased() == "md" {
                nav.show(.note(url))
                return true
            }
            guard recorder.phase == .idle, let type = UTType(filenameExtension: url.pathExtension),
                  FileImport.types.contains(where: { type.conforms(to: $0) }) else {
                dropRefused = true
                return false
            }
            Task { await recorder.transcribeFile(url) }
            return true
        }
        .alert("Wingman can't open that", isPresented: $dropRefused) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Drop one meeting note (a .md file from your notes folder) to open it, or one recording or video file to transcribe it (when nothing is recording).")
        }
    }

    // MARK: - Sidebar

    private var openMeetings: [WingmanSidebar.Open] {
        recorder.meetings.map { meeting in
            let name = meeting.meetingName.trimmingCharacters(in: .whitespaces)
            let tally = meeting.stage == .done
                ? SpeakerTally.of(meeting.lines.map { TranscriptRow($0, meeting: meeting) }) : nil
            return WingmanSidebar.Open(id: meeting.id, note: meeting.currentNote, title: name.isEmpty ? "Untitled meeting" : name,
                                       started: meeting.startedAt, stage: meeting.stage, tally: tally)
        }
    }

    private var sidebar: some View {
        let sections = WingmanSidebar.sections(entries: store.entries, open: openMeetings, onlyToName: onlyToName)
        return List(selection: $nav.selection) {
            if !sections.now.isEmpty {
                Section("Now") {
                    ForEach(sections.now) { row($0).tag($0.id) }
                }
            }
            ForEach(sections.days) { day in
                Section(WingmanSidebar.dayTitle(day.day)) {
                    ForEach(day.rows) { row($0).tag($0.id) }
                }
            }
        }
        .overlay {
            if sections.now.isEmpty, sections.days.isEmpty, !store.scanning {
                ContentUnavailableView(onlyToName ? "Everyone's Named" : "No Meetings Yet",
                                       systemImage: onlyToName ? "checkmark.circle" : "tray",
                                       description: Text(onlyToName ? "No meeting in the last two weeks has speakers to name."
                                                         : "Meetings from the last two weeks show here."))
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Toggle("Only to name", isOn: $onlyToName).toggleStyle(.checkbox)
                Spacer()
                Button("Open…") { openOlder() }
                    .help("Open an older meeting note")
            }
            .padding(8)
            .background(.bar)
        }
    }

    private func row(_ row: WingmanSidebar.Row) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).lineLimit(1)
                if let time = row.time {
                    Text(time.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            badge(row.badge)
        }
    }

    @ViewBuilder private func badge(_ badge: WingmanSidebar.Badge) -> some View {
        switch badge {
        case .recording(let started):
            HStack(spacing: 4) {
                Image(systemName: "record.circle.fill").foregroundStyle(.red)
                if let started { Text(started, style: .timer).monospacedDigit() }
            }
            .font(.caption)
        case .saving:
            Text("Saving…").font(.caption).foregroundStyle(.secondary)
        case .readOnly(let reason):
            Image(systemName: "lock").foregroundStyle(.secondary).help("This note can't be changed: \(reason).")
        case .toName(let count):
            Text("\(count) to name").font(.caption.weight(.medium))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Color.orange.opacity(0.2)))
        case .toConfirm(let count):
            Text("\(count) to confirm").font(.caption)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
        case .named:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Everyone's named")
        case .none:
            EmptyView()
        }
    }

    private func openOlder() {
        let panel = NSOpenPanel()
        panel.directoryURL = Recorder.notesFolder
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        nav.show(.note(url))
    }

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        switch nav.selection {
        case nil:
            HomeView(recorder: recorder, watcher: watcher, shortcut: shortcut)
        case .meeting(let id):
            if let meeting = recorder.meeting(id: id) {
                MeetingDetailView(recorder: recorder, meeting: meeting, watcher: watcher, reporter: reporter)
                    .id(id)
            } else {
                ContentUnavailableView("Choose a Meeting", systemImage: "person.2.wave.2")
            }
        case .note(let url):
            if let open = recorder.openMeeting(note: url) {
                MeetingDetailView(recorder: recorder, meeting: open, watcher: watcher, reporter: reporter)
                    .id(open.id)
            } else {
                PastMeetingDetail(url: url, recorder: recorder, store: store)
                    .id(url)
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            if recorder.isRecording {
                Button { Task { await watcher.stopRecording() } } label: {
                    Label("Stop Recording", systemImage: "stop.circle.fill")
                }
                .help("Stop recording the call")
                Button(action: showLive) {
                    Label("Live Transcript", systemImage: "captions.bubble")
                }
                .help("Show the Live Transcript")
            } else {
                Button { Task { await recorder.start() } } label: {
                    Label("Record", systemImage: "record.circle")
                }
                .help("Start recording")
                .disabled(recorder.phase != .idle)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
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
}
