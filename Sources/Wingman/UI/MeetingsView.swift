import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// The last two weeks of notes, listed in the Wingman window for naming
/// speakers after the meeting — also while another call records, since it
/// never touches the recording.
@MainActor
@Observable
final class MeetingsStore {
    struct Entry: Identifiable, Equatable {
        var id: URL { url }
        let url: URL
        let day: String
        let title: String
        let time: Date?
        let tally: SpeakerTally
        let readOnly: MeetingNote.ReadOnly?
    }

    static let days = 14
    private(set) var entries: [Entry] = []
    /// A meeting to show when the window opens (from a notification).
    var requested: URL?
    private(set) var scanning = false
    /// Notes read before, by path, with the modification date they had.
    private var cache: [String: (modified: Date, entry: Entry?)] = [:]
    private let index: MeetingIndex
    /// Finds voices in older meetings' audio.
    let runner: VoiceRecoveryRunner

    init(index: MeetingIndex, runner: VoiceRecoveryRunner) {
        self.index = index
        self.runner = runner
    }

    /// Reads the notes of the last two weeks (only those changed since last time).
    func refresh(now: Date = Date()) async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        let folder = Recorder.notesFolder
        let known = cache
        let starts = Dictionary(index.meetings.compactMap { m in m.started.map { (m.key, $0) } }, uniquingKeysWith: max)
        let firstDay = Recorder.dayFolderName(for: Calendar.current.date(byAdding: .day, value: -(Self.days - 1), to: now)!)
        let scanned = await Task.detached(priority: .utility) { () -> [String: (modified: Date, entry: Entry?)] in
            Self.scan(folder, from: firstDay, known: known, starts: starts)
        }.value
        cache = scanned
        entries = scanned.values.compactMap(\.entry).sorted { ($0.day, $0.time ?? .distantPast, $0.url.path) > ($1.day, $1.time ?? .distantPast, $1.url.path) }
    }

    private nonisolated static func scan(_ folder: URL, from firstDay: String, known: [String: (modified: Date, entry: Entry?)],
                                         starts: [String: Date]) -> [String: (modified: Date, entry: Entry?)] {
        let fm = FileManager.default
        var result: [String: (modified: Date, entry: Entry?)] = [:]
        let days = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { NoteNaming.isDay($0) && $0 >= firstDay }
        for day in days {
            let dayFolder = folder.appendingPathComponent(day, isDirectory: true)
            let notes = ((try? fm.contentsOfDirectory(at: dayFolder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: .skipsHiddenFiles)) ?? []).filter { $0.pathExtension == "md" }
            for url in notes {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if let cached = known[url.path], cached.modified == modified {
                    result[url.path] = cached
                    continue
                }
                // A note that isn't downloaded (iCloud) is read when it's opened, not here.
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
                let note = MeetingNote.parse(data)
                let base = url.deletingPathExtension().lastPathComponent
                let key = "\(day)/\(base)"
                let entry = note.lines.isEmpty ? nil : Entry(
                    url: url, day: day, title: note.title ?? NoteNaming.displayName(base: base),
                    time: starts[key] ?? AudioCleanup.started(day: day, base: base),
                    tally: SpeakerTally(speakers: note.speakers, meName: nil), readOnly: note.readOnly)
                result[url.path] = (modified, entry)
            }
        }
        return result
    }
}

/// "Learn Ana's voice from this meeting?" with a sample to listen to first.
private struct OfferRow: View {
    let offer: PastMeeting.Offer
    let audio: URL?
    let learn: () -> Void
    let notNow: () -> Void
    @State private var player = SamplePlayer()

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.badge.plus").foregroundStyle(.tint)
            Text("Wingman found a voice that may be \(offer.name)'s. Listen, and learn it if it's them.")
            Spacer()
            if let audio, let sample = offer.sample {
                Button(player.playing ? "Stop" : "Play Sample") {
                    player.playing ? player.stop() : player.play(audio, from: sample.start, to: sample.end)
                }
                .controlSize(.small)
            }
            Button("Learn") { learn() }.controlSize(.small).buttonStyle(.borderedProminent)
            Button("Not Now") { notNow() }.controlSize(.small)
        }
        .font(.callout)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
    }
}

/// Plays a few seconds of a meeting's call audio.
@MainActor
@Observable
final class SamplePlayer {
    private(set) var playing = false
    private var player: AVAudioPlayer?
    private var stopper: Task<Void, Never>?

    func play(_ url: URL, from start: Double, to end: Double) {
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.currentTime = start
        player.play()
        self.player = player
        playing = true
        stopper = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.5, end - start)))
            self?.stop()
        }
    }

    func stop() {
        stopper?.cancel()
        player?.stop()
        player = nil
        playing = false
    }
}

/// One saved meeting: its voices, who's left to name, Find, and the transcript.
struct PastMeetingDetail: View {
    let url: URL
    let recorder: Recorder
    let store: MeetingsStore
    @State private var meeting: PastMeeting?
    @State private var failure: String?
    @State private var find = FindState()
    @State private var walk = SpeakerWalk()
    @State private var confirmDelete = false
    @State private var confirmDeleteMeeting = false

    var body: some View {
        Group {
            if let meeting {
                content(meeting)
            } else if let failure {
                ContentUnavailableView("Can't Open This Note", systemImage: "exclamationmark.triangle", description: Text(failure))
            } else {
                ProgressView()
            }
        }
        .task {
            do {
                let opened = try await PastMeeting.open(url, index: recorder.index, voices: recorder.voices,
                                                        recognize: { [recorder] in recorder.recognizeVoices })
                meeting = opened
            } catch {
                failure = PastMeeting.describe(error)
            }
        }
        .onChange(of: store.runner.running) { old, _ in
            if let meeting, old == meeting.entry.id { Task { await meeting.reload() } }
        }
    }

    private func content(_ meeting: PastMeeting) -> some View {
        let guesses = meeting.voiceGuesses
        let rows = TranscriptRow.rows(meeting).map { row in
            var row = row
            if row.guess == nil, let guess = guesses[row.speakerKey] { row.guess = guess }
            return row
        }
        let tally = meeting.tally
        // Naming someone in an older meeting is what starts looking for their
        // voice in its call audio (not just opening it: that's heavy work).
        let searchIfNeeded = { [store] in
            if meeting.entry.speakers.contains(where: \.pendingLearn) { store.runner.request(meeting.entry, note: meeting.url) }
        }
        let rename: (String, String) -> Void = { speaker, name in
            Task {
                await meeting.rename(speaker, to: name)
                searchIfNeeded()
                await store.refresh()
            }
        }
        let confirm: (String) -> Void = { guess in
            Task {
                await meeting.confirm(guess)
                searchIfNeeded()
                await store.refresh()
            }
        }
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(meeting.title).font(.title3.weight(.semibold)).lineLimit(1)
                    Spacer()
                    if meeting.busy { ProgressView().controlSize(.small) }
                }
                if let date = meeting.note.header["Date"] {
                    Text(date).font(.caption).foregroundStyle(.secondary)
                }
                if let reason = meeting.note.readOnly {
                    Label("This note can't be changed here: \(reason.reason).", systemImage: "lock")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        if store.runner.isSearching(meeting.entry.id) {
                            ProgressView().controlSize(.small)
                            Text("Finding voices in the call audio… Names you give now are kept, and offered to learn when it's done.")
                                .font(.callout).foregroundStyle(.secondary)
                        } else {
                            Text(meeting.voiceStatus).font(.callout).foregroundStyle(.secondary)
                        }
                        if meeting.entry.voiceState == .stored || meeting.entry.speakers.contains(where: { $0.learned != nil }) {
                            Spacer()
                            Button("Delete Voices…", role: .destructive) { confirmDelete = true }
                                .controlSize(.small)
                        }
                    }
                    TallyLine(tally: tally) { walk.start(tally) }
                }
                if let outcome = meeting.outcome {
                    HStack {
                        Label(outcome.text, systemImage: outcome.isError ? "exclamationmark.triangle.fill" : "checkmark.circle")
                            .foregroundStyle(outcome.isError ? Color.orange : Color.secondary)
                        Spacer()
                        if let job = outcome.retry {
                            Button("Retry") { Task { await meeting.resume(job) } }.controlSize(.small)
                        }
                    }
                    .font(.callout)
                }
                ForEach(meeting.offers) { offer in
                    OfferRow(offer: offer, audio: meeting.callAudio, learn: { meeting.learn(offer) }, notNow: { meeting.notNow(offer) })
                }
                if let different = meeting.differentVoice {
                    HStack {
                        Spacer()
                        Button("Learn as a Different \(different.name)") { meeting.learnAsDifferentPerson() }
                            .controlSize(.small)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            if find.shown { FindBar(find: find, count: find.matches(in: rows).count, allWords: find.usesAllWords(in: rows)) }
            if walk.speaker != nil, meeting.note.readOnly == nil {
                SpeakerBar(walk: walk, rows: rows, tally: tally, suggestions: meeting.suggestions, rename: rename, confirm: confirm)
            }
            TranscriptList(rows: rows, canRename: meeting.note.readOnly == nil && !meeting.busy, suggestions: meeting.suggestions,
                           rename: rename, confirm: confirm, find: find, walk: walk) { EmptyView() }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { NSWorkspace.shared.activateFileViewerSelecting([meeting.url]) } label: {
                    Label("Show Note", systemImage: "doc.text.magnifyingglass")
                }
                .help("Show the note in Finder")
                Button { confirmDeleteMeeting = true } label: {
                    Label("Delete Meeting", systemImage: "trash")
                }
                .help("Move this meeting's note and audio to the Trash")
            }
        }
        .focusedSceneValue(\.transcriptActions, TranscriptActions(
            find: { find.open() },
            next: { find.next(find.matches(in: rows).count) },
            previous: { find.previous(find.matches(in: rows).count) }))
        .confirmationDialog("Delete this meeting?", isPresented: $confirmDeleteMeeting) {
            Button("Delete Meeting", role: .destructive) {
                recorder.onDeleted?(Recorder.deletedMessage(notTrashed: meeting.delete()))
                Task { await store.refresh() }
            }
        } message: {
            Text("Its note, audio and subtitles go to the Trash, and Wingman forgets the voices it learned from it.")
        }
        .confirmationDialog("Delete this meeting's voices?", isPresented: $confirmDelete) {
            Button("Delete Voices", role: .destructive) {
                recorder.deleteVoices(of: [meeting.entry.id])
                Task { await meeting.reload() }
            }
        } message: {
            Text(deleteMessage(meeting))
        }
    }

    private func deleteMessage(_ meeting: PastMeeting) -> String {
        let effect = recorder.effectOfDeletingVoices(of: [meeting.entry.id])
        var parts = ["Names in the note stay, but Wingman won't learn voices from this meeting anymore."]
        if !effect.recalculated.isEmpty {
            parts.append("What it learned from it is removed: \(effect.recalculated.joined(separator: ", ")) will be recognized from other meetings only.")
        }
        if !effect.forgotten.isEmpty {
            parts.append("\(effect.forgotten.joined(separator: ", ")) \(effect.forgotten.count == 1 ? "was" : "were") learned only from it and will be forgotten.")
        }
        let untraceable = recorder.untraceableLearning(in: Set([meeting.entry.id]))
        if !untraceable.isEmpty {
            parts.append("An older version of Wingman changed \(untraceable.joined(separator: ", "))'s voice, so what this meeting taught can't be taken out exactly. To remove it completely, forget them in Settings → People.")
        }
        return parts.joined(separator: " ")
    }
}
