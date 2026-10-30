import AppKit
import SwiftUI

// The transcript as both windows show it — the meeting in the Wingman window and
// a saved one in Meetings — with Find, text size, and naming speakers.

/// One line as shown.
struct TranscriptRow: Identifiable, Equatable {
    let id: String
    let start: TimeInterval
    /// What renaming acts on: the label in the Wingman window ("Them 2"), the
    /// name as the note shows it in Meetings.
    let speakerKey: String
    let name: String
    let isMe: Bool
    /// For the speaker's color: their number among the voices.
    let voice: Int?
    let text: String
    var isFinal = true
    var unclear = false
    var incomplete = false
    var possibleEcho = false
    var confidence: Float = 1
    var guess: String?
    var recognized = false
    /// The guess comes from a name the user gave lines during the call.
    var guessFromHint = false
    /// The name is the user's, for this line only, during the call.
    var hinted = false
}

extension TranscriptRow {
    /// A line of a meeting with its own window (recording, finishing or just done).
    @MainActor init(_ line: TranscriptLine, meeting: Meeting) {
        self.init(id: line.id.uuidString, start: line.start, speakerKey: line.label, name: meeting.liveName(line),
                  isMe: line.speaker == .me, voice: line.voice, text: line.text, isFinal: line.isFinal,
                  unclear: line.isUnclear, incomplete: line.incomplete, possibleEcho: line.possibleEcho,
                  confidence: line.confidence, guess: meeting.guess(for: line.label),
                  recognized: meeting.isRecognized(line.label), guessFromHint: meeting.guessFromHint.contains(line.label),
                  hinted: !meeting.labelsFinal && line.hint != nil)
    }

    /// The lines of a saved note.
    @MainActor static func rows(_ meeting: PastMeeting) -> [TranscriptRow] {
        let order = meeting.speakers
        return meeting.note.lines.map { line in
            let kind = meeting.kind(of: line.speaker)
            return TranscriptRow(id: "\(line.row)", start: TimeInterval(line.start), speakerKey: line.speaker, name: line.speaker,
                                 isMe: kind == .me, voice: order.firstIndex(of: line.speaker).map { $0 + 1 }, text: line.text,
                                 unclear: line.mark == .unclear, incomplete: line.mark == .incomplete,
                                 possibleEcho: line.mark == .possibleEcho,
                                 guess: kind == .guess ? String(line.speaker.dropLast()) : nil)
        }
    }
}

// MARK: - Text size

/// The transcript's text size, the same in both windows and remembered.
@MainActor
@Observable
final class ReadingPrefs {
    static let shared = ReadingPrefs()
    static let sizes: [CGFloat] = [11, 12, 13, 14, 15, 16, 18, 20, 22, 24, 28]
    static let standard: CGFloat = 13

    private(set) var size: CGFloat {
        didSet { UserDefaults.standard.set(Double(size), forKey: "transcriptTextSize") }
    }

    private init() {
        let saved = CGFloat(UserDefaults.standard.double(forKey: "transcriptTextSize"))
        size = Self.sizes.contains(saved) ? saved : Self.standard
    }

    var canGrow: Bool { size < Self.sizes.last! }
    var canShrink: Bool { size > Self.sizes.first! }
    func bigger() { size = Self.sizes.first { $0 > size } ?? size }
    func smaller() { size = Self.sizes.last { $0 < size } ?? size }
    func actualSize() { size = Self.standard }

    /// ⌘+ and ⌘= both make the text bigger, on any keyboard layout: a menu
    /// shortcut alone matches only one of them, and which key types "+"
    /// depends on the layout (Shift-= on US, its own key on Latin American).
    private var keyMonitor: Any?
    func watchKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection([.command, .option, .control]) == .command,
                  let key = event.charactersIgnoringModifiers, key == "+" || key == "=" else { return event }
            MainActor.assumeIsolated { ReadingPrefs.shared.bigger() }
            return nil
        }
    }
}

/// Text Size in a window's toolbar.
struct TextSizeMenu: View {
    let prefs = ReadingPrefs.shared

    var body: some View {
        Menu {
            Button("Make Text Bigger") { prefs.bigger() }.disabled(!prefs.canGrow)
            Button("Make Text Smaller") { prefs.smaller() }.disabled(!prefs.canShrink)
            Button("Actual Size") { prefs.actualSize() }.disabled(prefs.size == ReadingPrefs.standard)
        } label: {
            Label("Text Size", systemImage: "textformat.size")
        }
        .help("Make the transcript's text bigger or smaller")
    }
}

// MARK: - Find

/// Finds a phrase in the transcript ignoring case, accents, punctuation and
/// extra spaces: "testing since i always" finds "Testing, since I always".
/// When the phrase itself isn't there, lines that have all of its words, in
/// any order, are found instead (each word highlighted), and Find says so.
enum TranscriptFind {
    struct Match: Equatable {
        let row: Int
        /// In the row's original text.
        let range: Range<String.Index>
    }

    static func matches(_ query: String, in texts: [String]) -> [Match] {
        let exact = phraseMatches(query, in: texts)
        return exact.isEmpty ? allWordsMatches(query, in: texts) : exact
    }

    /// The phrase wasn't found as typed, but lines with all its words were.
    static func usesAllWords(_ query: String, in texts: [String]) -> Bool {
        phraseMatches(query, in: texts).isEmpty && !allWordsMatches(query, in: texts).isEmpty
    }

    /// Lines containing every word of a query of two or more words; each
    /// word's occurrences in them, in reading order.
    static func allWordsMatches(_ query: String, in texts: [String]) -> [Match] {
        let words = Set(String(folded(query).chars).split(separator: " ").map(String.init))
        guard words.count >= 2 else { return [] }
        var found: [Match] = []
        for (row, text) in texts.enumerated() {
            let perWord = words.map { phraseMatches($0, in: [text]) }
            guard perWord.allSatisfy({ !$0.isEmpty }) else { continue }
            found += perWord.flatMap { $0 }.map { Match(row: row, range: $0.range) }
                .sorted { $0.range.lowerBound < $1.range.lowerBound }
        }
        return found
    }

    static func phraseMatches(_ query: String, in texts: [String]) -> [Match] {
        let needle = folded(query).chars
        guard !needle.isEmpty else { return [] }
        var found: [Match] = []
        for (row, text) in texts.enumerated() {
            let hay = folded(text)
            guard hay.chars.count >= needle.count else { continue }
            var i = 0
            while i + needle.count <= hay.chars.count {
                if Array(hay.chars[i..<(i + needle.count)]) == needle {
                    let start = hay.origin[i]
                    let end = text.index(after: hay.origin[i + needle.count - 1])
                    found.append(Match(row: row, range: start..<end))
                    i += needle.count
                } else {
                    i += 1
                }
            }
        }
        return found
    }

    /// The text folded for matching, each character with where it came from.
    /// Punctuation becomes a space; runs of spaces become one; ends are trimmed.
    static func folded(_ text: String) -> (chars: [Character], origin: [String.Index]) {
        var chars: [Character] = [], origin: [String.Index] = []
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            let isWord = c.isLetter || c.isNumber
            if isWord {
                for f in String(c).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased() {
                    chars.append(f)
                    origin.append(index)
                }
            } else if !chars.isEmpty, chars.last != " " {
                chars.append(" ")
                origin.append(index)
            }
            index = text.index(after: index)
        }
        while chars.last == " " {
            chars.removeLast()
            origin.removeLast()
        }
        return (chars, origin)
    }
}

/// Find's state in one window.
@MainActor
@Observable
final class FindState {
    var shown = false
    var query = "" { didSet { current = 0 } }
    var current = 0
    /// Asks the field to take focus.
    var focusRequest = 0

    func open() {
        shown = true
        focusRequest += 1
    }

    func close() {
        shown = false
        query = ""
    }

    func matches(in rows: [TranscriptRow]) -> [TranscriptFind.Match] {
        shown ? TranscriptFind.matches(query, in: rows.map(\.text)) : []
    }

    func usesAllWords(in rows: [TranscriptRow]) -> Bool {
        shown && TranscriptFind.usesAllWords(query, in: rows.map(\.text))
    }

    func next(_ count: Int) { if count > 0 { current = (current + 1) % count } }
    func previous(_ count: Int) { if count > 0 { current = (current - 1 + count) % count } }
}

struct FindBar: View {
    @Bindable var find: FindState
    let count: Int
    var allWords = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in transcript", text: $find.query)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { find.next(count) }
                .onKeyPress(.downArrow) { find.next(count); return .handled }
                .onKeyPress(.upArrow) { find.previous(count); return .handled }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    find.previous(count)
                    return .handled
                }
                .onExitCommand { find.close() }
            if !find.query.isEmpty {
                Text(count == 0 ? "Not found" : "\(min(find.current + 1, count)) of \(count)\(allWords ? " · all words, any order" : "")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button { find.previous(count) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless).disabled(count == 0)
                .help("Previous (⇧⌘G)")
            Button { find.next(count) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).disabled(count == 0)
                .help("Next (⌘G)")
            Button { find.close() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("Close (Esc)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .onAppear { focused = true }
        .onChange(of: find.focusRequest) { focused = true }
    }
}

/// What the Find and text-size menu items act on: the focused window's transcript.
struct TranscriptActions {
    let find: () -> Void
    let next: () -> Void
    let previous: () -> Void
}

struct TranscriptActionsKey: FocusedValueKey {
    typealias Value = TranscriptActions
}

extension FocusedValues {
    var transcriptActions: TranscriptActions? {
        get { self[TranscriptActionsKey.self] }
        set { self[TranscriptActionsKey.self] = newValue }
    }
}

/// Edit → Find, and View → text size.
struct TranscriptCommands: Commands {
    @FocusedValue(\.transcriptActions) private var actions

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find…") { actions?.find() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(actions == nil)
            Button("Find Next") { actions?.next() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(actions == nil)
            Button("Find Previous") { actions?.previous() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(actions == nil)
        }
        CommandGroup(after: .toolbar) {
            Button("Make Text Bigger") { ReadingPrefs.shared.bigger() }
                .keyboardShortcut("+", modifiers: .command)
            Button("Make Text Smaller") { ReadingPrefs.shared.smaller() }
                .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") { ReadingPrefs.shared.actualSize() }
                .keyboardShortcut("0", modifiers: .command)
        }
    }
}

// MARK: - Speakers left to name

/// "2 speakers to name · 1 to confirm [Name Them]", or "Everyone's named ✓".
struct TallyLine: View {
    let tally: SpeakerTally
    let nameThem: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let summary = tally.summary {
                Image(systemName: "person.crop.circle.badge.questionmark").foregroundStyle(.orange)
                Text(summary)
                Button("Name Them", action: nameThem).controlSize(.small)
            } else if tally.named > 0 {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Everyone's named")
            }
        }
        .font(.callout)
    }
}

/// Steps through one unnamed speaker's lines, then on to the next speaker.
@MainActor
@Observable
final class SpeakerWalk {
    /// The speaker key being named, nil when the bar is closed.
    var speaker: String?
    var line = 0
    /// Asks the bar to open the rename popover.
    var renaming = false

    func start(_ tally: SpeakerTally) {
        speaker = (tally.toName + tally.toConfirm).first
        line = 0
    }

    func lines(in rows: [TranscriptRow]) -> [TranscriptRow] {
        guard let speaker else { return [] }
        return rows.filter { $0.speakerKey == speaker }
    }

    /// Their first line of six words or more (or the first), to read before naming.
    func firstUsefulLine(in rows: [TranscriptRow]) -> Int {
        lines(in: rows).firstIndex { $0.text.split(separator: " ").count >= 6 } ?? 0
    }

    func next(_ tally: SpeakerTally) {
        let queue = tally.toName + tally.toConfirm
        guard let speaker, let i = queue.firstIndex(of: speaker) else {
            start(tally)
            return
        }
        self.speaker = queue.count > 1 ? queue[(i + 1) % queue.count] : nil
        line = 0
    }
}

struct SpeakerBar: View {
    @Bindable var walk: SpeakerWalk
    let rows: [TranscriptRow]
    let tally: SpeakerTally
    let suggestions: [String]
    let rename: (String, String) -> Void
    let confirm: (String) -> Void

    var body: some View {
        let theirs = walk.lines(in: rows)
        HStack(spacing: 8) {
            if let speaker = walk.speaker {
                Text(speaker).font(.callout.weight(.semibold))
                Text("· line \(min(walk.line + 1, theirs.count)) of \(theirs.count)")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Button { walk.line = max(0, walk.line - 1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless).disabled(walk.line == 0)
                Button { walk.line = min(theirs.count - 1, walk.line + 1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless).disabled(walk.line >= theirs.count - 1)
                Spacer()
                Button("Name \(speaker)…") { walk.renaming = true }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .popover(isPresented: $walk.renaming, arrowEdge: .bottom) {
                        let guess = speaker.hasSuffix("?") ? String(speaker.dropLast()) : nil
                        RenameSpeaker(original: speaker, current: speaker, suggestions: suggestions, guess: guess,
                                      confirm: { confirm(speaker); walk.renaming = false; walk.next(tally) }) { name in
                            walk.renaming = false
                            guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                            rename(speaker, name)
                            walk.next(tally)
                        }
                    }
                Button("Next Speaker") { walk.next(tally) }.controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Everyone's named").font(.callout)
                Spacer()
            }
            Button { walk.speaker = nil } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("Close")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

// MARK: - The list

/// Naming who's speaking on one line during the call (see `NameHints`).
struct LineHinting {
    /// Names already given in this call, most recent first.
    let recent: [String]
    /// Invitees not named yet.
    let invited: [String]
    /// The row's id (its line's UUID) and the name; nil for "not sure".
    let name: (String, String?) -> Void

    @MainActor init(_ meeting: Meeting) {
        let recent = meeting.hintNames
        self.recent = recent
        invited = meeting.suggestedNames.filter { name in !recent.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
        name = { [weak meeting] id, name in
            guard let id = UUID(uuidString: id) else { return }
            meeting?.nameLine(id, as: name)
        }
    }
}

struct TranscriptList<Empty: View>: View {
    let rows: [TranscriptRow]
    let canRename: Bool
    let suggestions: [String]
    let rename: (String, String) -> Void
    let confirm: (String) -> Void
    var find: FindState
    var walk: SpeakerWalk
    /// Follow new lines as they come (a live meeting).
    var live = false
    /// During the call: say who's speaking on a line.
    var hinting: LineHinting?
    @ViewBuilder var empty: () -> Empty
    private let prefs = ReadingPrefs.shared
    @State private var nearBottom = true
    @State private var follower = TranscriptFollower()
    /// The lines as they were when the window started being resized: while the
    /// edge is dragged, the list only re-measures, without new text or scrolling
    /// on top. New lines appear when it's let go.
    @State private var frozen: [TranscriptRow]?

    var body: some View {
        let rows = frozen ?? self.rows
        let matches = find.matches(in: rows)
        let current = matches.isEmpty ? nil : matches[min(find.current, matches.count - 1)]
        let walking = walk.lines(in: rows)
        let walkTarget = walking.isEmpty ? nil : walking[min(walk.line, walking.count - 1)].id
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: prefs.size * 0.75) {
                    if rows.isEmpty { empty() }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { offset, row in
                        LineView(row: row, size: prefs.size, canRename: canRename, suggestions: suggestions,
                                 highlights: matches.filter { $0.row == offset }.map(\.range),
                                 current: current?.row == offset ? current?.range : nil,
                                 emphasized: walk.speaker == row.speakerKey, hinting: hinting,
                                 // The list holds still while a line is being named, so
                                 // new lines don't scroll it (and its popover) away.
                                 hintEditing: { open in frozen = open ? self.rows : nil },
                                 rename: { rename(row.speakerKey, $0) }, confirm: { confirm(row.speakerKey) })
                            .id(row.id)
                    }
                }
                .padding(12)
                .modifier(OldLayoutSelection())
            }
            .onScrollGeometryChange(for: TranscriptFollower.Distance.self) { geometry in
                TranscriptFollower.distance(offset: geometry.contentOffset.y, visible: geometry.containerSize.height,
                                            content: geometry.contentSize.height)
            } action: { _, distance in
                follower.settle(distance) { near in
                    if nearBottom != near { nearBottom = near }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willStartLiveResizeNotification)) { note in
                guard live, !StressLayout.oldLayout, (note.object as? NSWindow)?.isKeyWindow == true else { return }
                frozen = self.rows
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndLiveResizeNotification)) { _ in
                frozen = nil
            }
            // Opened in the middle of a call (the Live Transcript brought
            // back, the call chosen in the Wingman window): start at the newest line.
            .onAppear {
                guard live, let last = rows.last else { return }
                follower.follow(last.id) { proxy.scrollTo($0, anchor: .bottom) }
            }
            .onChange(of: rows.last?.text) {
                // Follow only someone already at the bottom, and not while finding or naming.
                guard live, nearBottom, !find.shown, walk.speaker == nil, let last = rows.last else { return }
                follower.follow(last.id) { proxy.scrollTo($0, anchor: .bottom) }
            }
            .onChange(of: current) {
                if let current { withAnimation { proxy.scrollTo(rows[current.row].id, anchor: .center) } }
            }
            .onChange(of: walkTarget) {
                if let walkTarget { withAnimation { proxy.scrollTo(walkTarget, anchor: .center) } }
            }
            .overlay(alignment: .bottomTrailing) {
                if live, !nearBottom, let last = rows.last {
                    Button {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    } label: {
                        Label("Jump to Latest", systemImage: "arrow.down.circle.fill")
                    }
                    .controlSize(.small)
                    .padding(12)
                }
            }
        }
    }
}

/// Keeps a live transcript following its newest line without feeding back into
/// its own layout. On the field Mac (0.9.1) the list's main thread got stuck
/// re-placing its rows during calls: macOS reported "OnScrollGeometryChange
/// tried to update multiple times per frame", because the near-the-bottom flag
/// was written during layout and an animated scroll was started on every
/// revision of the live line, each one changing the geometry again. Here:
/// - the flag has a dead band (near within 80 pt, away beyond 200 pt), so a few
///   points of re-measuring can't flip it back and forth;
/// - it's written after the layout pass, once, with the latest value;
/// - following scrolls at most every 0.25 s, to the newest line then, without
///   animation.
@MainActor
final class TranscriptFollower {
    enum Distance: Equatable { case near, between, away }

    nonisolated static let nearWithin: CGFloat = 80
    nonisolated static let awayBeyond: CGFloat = 200
    nonisolated static let followInterval: TimeInterval = 0.25

    nonisolated static func distance(offset: CGFloat, visible: CGFloat, content: CGFloat) -> Distance {
        let below = content - (offset + visible)
        if below <= nearWithin { return .near }
        return below > awayBeyond ? .away : .between
    }

    private var pendingNear: Bool?
    private var pendingTarget: String?
    private var lastFollow: TimeInterval = -.infinity

    /// Hands `apply` the new near-the-bottom value on the next turn of the run
    /// loop; several changes in one pass become one write, the last.
    func settle(_ distance: Distance, apply: @escaping (Bool) -> Void) {
        guard distance != .between else { return }
        let scheduled = pendingNear != nil
        pendingNear = distance == .near
        guard !scheduled else { return }
        DispatchQueue.main.async { [self] in
            guard let near = pendingNear else { return }
            pendingNear = nil
            apply(near)
        }
    }

    /// Scrolls to `id` soon: at once if the last scroll was a while ago,
    /// otherwise when the interval is up, to whichever line is newest by then.
    func follow(_ id: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime,
                scroll: @escaping (String) -> Void) {
        let scheduled = pendingTarget != nil
        pendingTarget = id
        guard !scheduled else { return }
        let wait = max(0, lastFollow + Self.followInterval - now)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [self] in
            guard let target = pendingTarget else { return }
            pendingTarget = nil
            lastFollow = ProcessInfo.processInfo.systemUptime
            scroll(target)
        }
    }
}

struct LineView: View {
    let row: TranscriptRow
    let size: CGFloat
    let canRename: Bool
    let suggestions: [String]
    var highlights: [Range<String.Index>] = []
    var current: Range<String.Index>?
    var emphasized = false
    var hinting: LineHinting?
    var hintEditing: (Bool) -> Void = { _ in }
    let rename: (String) -> Void
    let confirm: () -> Void
    @State private var editing = false

    private static let voiceColors: [Color] = [.green, .orange, .purple, .pink, .teal, .yellow, .red, .mint]

    private var color: Color {
        if row.isMe { return .accentColor }
        guard let voice = row.voice else { return .green }
        return Self.voiceColors[(voice - 1) % Self.voiceColors.count]
    }

    @ViewBuilder private var speaker: some View {
        let label = Text(row.name)
            .font(.system(size: labelSize, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
        if canRename, !row.isMe {
            Button { editing = true } label: { label }
                .buttonStyle(.plain)
                .help("Rename \(row.name)")
                .popover(isPresented: $editing, arrowEdge: .bottom) {
                    RenameSpeaker(original: row.speakerKey, current: row.name, suggestions: suggestions,
                                  guess: row.guess, guessFromHint: row.guessFromHint, recognized: row.recognized,
                                  confirm: { confirm(); editing = false }) { newName in
                        rename(newName)
                        editing = false
                    }
                }
        } else if let hinting, !row.isMe {
            HintButton(row: row, hinting: hinting, editingChanged: hintEditing) { label }
        } else {
            label
        }
    }

    /// Why a line needs checking, if it does.
    @ViewBuilder private var marker: some View {
        if row.incomplete {
            Image(systemName: "exclamationmark.bubble.fill")
                .foregroundStyle(.orange)
                .help("The speech model failed on this line; this is what it had heard so far.")
        } else if row.possibleEcho {
            Image(systemName: "speaker.wave.2.bubble")
                .foregroundStyle(.secondary)
                .help("This may be the call coming back through your speakers rather than you. It's kept because it isn't a clear repeat.")
        } else if row.unclear {
            Image(systemName: "questionmark.circle.fill")
                .foregroundStyle(.orange)
                .help(row.confidence < 1
                      ? "Wingman wasn't sure about this line (confidence \(Int(row.confidence * 100))%). Check it against the audio."
                      : "Wingman wasn't sure about this line. Check it against the audio.")
        }
    }

    /// The text with Find's matches highlighted.
    private var text: Text {
        guard !highlights.isEmpty else { return Text(row.text) }
        var attributed = AttributedString(row.text)
        for range in highlights {
            guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].backgroundColor = range == current ? Color.orange.opacity(0.7) : Color.yellow.opacity(0.45)
        }
        return Text(attributed)
    }

    /// The name and time line above the text: smaller than the text, so the
    /// text gets the window's whole width.
    private var labelSize: CGFloat { max(10, (size * 0.8).rounded()) }

    var body: some View {
        // A stack, never baseline alignment: lining up the baselines of
        // selectable text makes SwiftUI measure each line's AppKit text view on
        // every layout pass, which (with live resizing) froze 0.8.1.
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                speaker
                Text(Recorder.timestamp(row.start))
                    .font(.system(size: labelSize).monospacedDigit())
                    .foregroundStyle(.tertiary)
                marker
                    .font(.system(size: labelSize))
            }
            text
                .font(.system(size: size))
                .foregroundStyle(row.isFinal && !row.unclear ? .primary : .secondary)
                .italic(!row.isFinal)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Only finished lines can be selected: the live line changes
                // several times a second, and its selection view with it.
                .selectable(row.isFinal && !StressLayout.oldLayout)
        }
        .padding(.vertical, emphasized ? 2 : 0)
        .background(emphasized ? color.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .background(current != nil ? Color.orange.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 4))
    }
}

/// A remote line's speaker during the call: click to say who's speaking.
struct HintButton<Label: View>: View {
    let row: TranscriptRow
    let hinting: LineHinting
    var editingChanged: (Bool) -> Void = { _ in }
    @ViewBuilder let label: () -> Label
    @State private var editing = false
    @State private var hovering = false

    var body: some View {
        Button { editing = true } label: {
            label()
                .underline(row.hinted || hovering, pattern: row.hinted ? .dot : .solid)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(row.hinted ? "You named this line. Wingman checks the voice when the call ends."
                         : "Who's speaking? Name them, and Wingman names their voice when the call ends.")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            RenameSpeaker(original: Speaker.them.rawValue, current: row.name, suggestions: hinting.invited,
                          recent: hinting.recent, purpose: .hint) { name in
                hinting.name(row.id, name.isEmpty ? nil : name)
                editing = false
            }
        }
        .onChange(of: editing) { editingChanged(editing) }
    }
}

/// Popover for giving a speaker a real name. Applies to every line with that
/// speaker; during the call (`.hint`), to the one line.
struct RenameSpeaker: View {
    enum Purpose { case rename, hint }

    let original: String
    let current: String
    let suggestions: [String]
    var guess: String? = nil
    var guessFromHint = false
    var recognized = false
    /// Names already given in this call.
    var recent: [String] = []
    var purpose = Purpose.rename
    var confirm: () -> Void = {}
    let done: (String) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if purpose == .hint {
                Text("Who's speaking?").font(.headline)
                Text("Wingman checks the voice when the call ends.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let guess {
                Text("Is this \(guess)?").font(.headline)
                Text(guessFromHint ? "You named this voice \(guess) during the call."
                                   : "This voice sounds like \(guess) from an earlier meeting.")
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
            if !recent.isEmpty {
                Text("Named in this call").font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(recent, id: \.self) { name in
                        Button(name) { done(name) }
                            .buttonStyle(.plain)
                            .padding(.vertical, 2)
                    }
                }
                Divider()
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
            TextField(purpose == .hint ? "Name" : original, text: $text)
                .frame(width: 220)
                .onSubmit { done(text) }
            HStack {
                if current != original {
                    Button(purpose == .hint ? "Not Sure" : "Reset") { done("") }
                }
                Spacer()
                Button(purpose == .hint ? "Name" : "Rename") { done(text) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .onAppear { text = current == original || guess != nil ? "" : current }
    }
}

private extension View {
    /// Text selection on or off (the two settings are different types).
    @ViewBuilder func selectable(_ on: Bool) -> some View {
        if on { textSelection(.enabled) } else { textSelection(.disabled) }
    }
}

/// 0.8.1's layout, for comparing (development only, `-WingmanOldLayout YES`).
private struct OldLayoutSelection: ViewModifier {
    func body(content: Content) -> some View {
        if StressLayout.oldLayout { content.textSelection(.enabled) } else { content }
    }
}
