import AppKit
import SwiftUI

/// What the Live Transcript shows and whether it's on screen. No AppKit, so
/// the rules can be tested: it appears when a recording starts, closing it
/// only hides it (the recording goes on), it follows a call into a new note,
/// and once its call is saved it says so for a moment and goes away.
struct LivePanelState: Equatable {
    private(set) var meeting: UUID?
    private(set) var visible = false
    /// Closed during this recording: it stays closed until it's asked for.
    private(set) var userHidden = false
    /// Its call stopped: "Saving…", then "Saved".
    private(set) var ended = false

    /// The meeting being recorded changed (nil: nothing is recording).
    mutating func current(_ id: UUID?) {
        guard let id else {
            if meeting != nil { ended = true }
            return
        }
        if meeting == nil || ended {
            // A new recording.
            meeting = id
            ended = false
            userHidden = false
            visible = true
        } else if meeting != id {
            // A split or a join: the same call goes on in another note.
            meeting = id
            visible = !userHidden
        }
    }

    /// The close button: hides it. A recording goes on; a saved one is done with.
    mutating func close() {
        visible = false
        if ended {
            meeting = nil
            ended = false
        } else {
            userHidden = true
        }
    }

    /// From the menu bar, the Dock or the Wingman window.
    mutating func show() {
        guard meeting != nil else { return }
        visible = true
        userHidden = false
    }

    /// A while after its meeting was saved.
    mutating func savedTimeout() {
        guard ended else { return }
        self = LivePanelState()
    }

    /// Its meeting was deleted, discarded or joined into another.
    mutating func meetingGone() {
        self = LivePanelState()
    }
}

/// How see-through the Live Transcript is.
enum LiveLook {
    static let opacityRange: ClosedRange<Double> = 0.6...1
    static let defaultOpacity = 0.85
    /// How long "Saved" stays before the Live Transcript closes.
    static let savedFor: Duration = .seconds(10)

    /// Never see-through when macOS is asked to reduce transparency or to
    /// increase contrast; otherwise the setting, kept readable.
    static func alpha(setting: Double, reduceTransparency: Bool, increaseContrast: Bool) -> Double {
        if reduceTransparency || increaseContrast { return 1 }
        return min(max(setting, opacityRange.lowerBound), opacityRange.upperBound)
    }
}

/// The Live Transcript's settings, remembered.
@MainActor
@Observable
final class LivePrefs {
    static let shared = LivePrefs()

    var opacity: Double {
        didSet { UserDefaults.standard.set(opacity, forKey: "liveOpacity") }
    }
    /// Just the latest line, instead of the whole transcript.
    var compact: Bool {
        didSet { UserDefaults.standard.set(compact, forKey: "liveCompact") }
    }
    /// Hidden while the screen is shared in Teams (where Wingman can tell).
    var hideWhileSharing: Bool {
        didSet { UserDefaults.standard.set(hideWhileSharing, forKey: "liveHideWhileSharing") }
    }

    private init() {
        let defaults = UserDefaults.standard
        let stored = defaults.double(forKey: "liveOpacity")
        opacity = stored == 0 ? LiveLook.defaultOpacity : stored
        compact = defaults.bool(forKey: "liveCompact")
        hideWhileSharing = defaults.object(forKey: "liveHideWhileSharing") as? Bool ?? true
    }
}

/// What the Live Transcript's view shows (the controller keeps it current).
@MainActor
@Observable
final class LiveModel {
    var meetingID: UUID?
}

/// A panel that can take typing (the meeting's name) without making Wingman
/// the active app, so the call stays in front.
private final class LivePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The Live Transcript: one floating window for the call being recorded. It
/// stays above the call, also in full screen and on every desktop, without
/// taking focus from it. (Apple's standard floating windows hide when their
/// app isn't the active one, which during a call it never is.)
@MainActor
final class LiveTranscriptController: NSObject, NSWindowDelegate {
    private let recorder: Recorder
    private let watcher: CallWatcher
    private let prefs = LivePrefs.shared
    private let model = LiveModel()
    /// Whether the screen is being shared in the call (Teams only, with Accessibility).
    private let sharing: () -> Bool
    /// Opens the Wingman window on a meeting (set by the app).
    var openInWingman: ((UUID) -> Void)?
    private(set) var state = LivePanelState()
    private var panel: LivePanel?
    private var savedTimer: Task<Void, Never>?
    private static let compactHeight: CGFloat = 150
    private var expandedHeight: CGFloat = 380

    init(recorder: Recorder, watcher: CallWatcher, sharing: @escaping () -> Bool) {
        self.recorder = recorder
        self.watcher = watcher
        self.sharing = sharing
        super.init()
    }

    func start() {
        observe()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyLook() }
        }
    }

    /// From the menu bar, the Dock, a notification or the Wingman window.
    func show() {
        state.show()
        evaluate()
        panel?.orderFrontRegardless()
    }

    /// Back to the top right of the screen, in case it got lost.
    func restorePosition() {
        guard let panel else { return }
        panel.setFrame(defaultFrame(height: panel.frame.height), display: true)
    }

    /// Whether this meeting is in the Live Transcript (so it isn't forgotten).
    func isShowing(_ meeting: Meeting) -> Bool { state.meeting == meeting.id }

    /// Re-evaluates whenever what it reads changes: the meeting being recorded,
    /// its stage, screen sharing, the settings.
    /// Only what's read in `dependencies` is tracked: the panel's own view
    /// (the transcript) is never read here, so new lines don't come through.
    private func observe() {
        evaluate()
        withObservationTracking { dependencies() } onChange: { [weak self] in
            DispatchQueue.main.async { self?.observe() }
        }
    }

    private func dependencies() {
        _ = recorder.current
        _ = recorder.meetings
        _ = recorder.isRecording
        _ = state.meeting.flatMap(recorder.meeting(id:))?.stage
        _ = sharing()
        _ = prefs.opacity
        _ = prefs.compact
        _ = prefs.hideWhileSharing
    }

    private func evaluate() {
        state.current(recorder.current?.id)
        let meeting = state.meeting.flatMap(recorder.meeting(id:))
        if state.meeting != nil, meeting == nil { state.meetingGone() }
        if state.ended, meeting?.stage == .done {
            scheduleSavedTimeout()
        } else if !state.ended {
            savedTimer?.cancel()
            savedTimer = nil
        }
        model.meetingID = state.meeting
        let hidden = prefs.hideWhileSharing && recorder.isRecording && sharing()
        if state.visible, state.meeting != nil, !hidden {
            let panel = self.panel ?? makePanel()
            applyLook()
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else {
            panel?.orderOut(nil)
        }
    }

    private func scheduleSavedTimeout() {
        guard savedTimer == nil else { return }
        savedTimer = Task { [weak self] in
            try? await Task.sleep(for: LiveLook.savedFor)
            guard !Task.isCancelled, let self else { return }
            self.savedTimer = nil
            self.state.savedTimeout()
            self.evaluate()
        }
    }

    private func makePanel() -> LivePanel {
        let panel = LivePanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: expandedHeight),
                              styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        panel.identifier = NSUserInterfaceItemIdentifier("live-transcript")
        panel.title = "Live Transcript"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        // Asks screen sharing to leave it out; since macOS 15 not every app
        // honours this, so it's also hidden while sharing where Wingman can tell.
        panel.sharingType = .none
        #if !NO_DIAGNOSTICS
        // Development: `-WingmanLiveCapturable YES` lets screenshots of it be taken, to check it.
        if UserDefaults.standard.bool(forKey: "WingmanLiveCapturable") { panel.sharingType = .readOnly }
        #endif
        panel.minSize = NSSize(width: 340, height: Self.compactHeight)
        panel.delegate = self
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        let hosting = NSHostingView(rootView: LiveTranscriptView(
            recorder: recorder, watcher: watcher, model: model, prefs: prefs,
            open: { [weak self] id in self?.openInWingman?(id) },
            toggleCompact: { [weak self] in self?.toggleCompact() }))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: background.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
        // Dark like Apple's other floating panels over video, whatever the
        // Mac's appearance: light text on it stays readable over any call.
        panel.appearance = NSAppearance(named: .darkAqua)
        if !panel.setFrameUsingName("LiveTranscript") {
            panel.setFrame(defaultFrame(height: expandedHeight), display: false)
        }
        panel.setFrameAutosaveName("LiveTranscript")
        // The saved frame is from either size: start in the one chosen, top edge kept.
        var frame = panel.frame
        if frame.height > Self.compactHeight + 40 { expandedHeight = frame.height }
        let height = prefs.compact ? Self.compactHeight : expandedHeight
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: false)
        self.panel = panel
        return panel
    }

    private func defaultFrame(height: CGFloat) -> NSRect {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width: CGFloat = 440
        return NSRect(x: visible.maxX - width - 20, y: visible.maxY - height - 20, width: width, height: height)
    }

    private func applyLook() {
        guard let panel else { return }
        let workspace = NSWorkspace.shared
        panel.alphaValue = LiveLook.alpha(setting: prefs.opacity,
                                          reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
                                          increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast)
    }

    /// Compact keeps the top edge where it is and remembers the full height.
    private func toggleCompact() {
        guard let panel else { return }
        var frame = panel.frame
        if !prefs.compact { expandedHeight = frame.height }
        prefs.compact.toggle()
        let height = prefs.compact ? Self.compactHeight : expandedHeight
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true, animate: false)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        state.close()
        evaluate()
        return false
    }
}

/// The Live Transcript's content: unmistakably live (red dot, "Live", the
/// timer), the call's controls at the top edge, then the transcript, or just
/// the latest line when compact.
struct LiveTranscriptView: View {
    let recorder: Recorder
    let watcher: CallWatcher
    let model: LiveModel
    @Bindable var prefs: LivePrefs
    let open: (UUID) -> Void
    let toggleCompact: () -> Void
    @State private var find = FindState()
    @State private var walk = SpeakerWalk()
    @State private var naming = false
    /// Compact: the line being named stays while its popover is open.
    @State private var pinned: UUID?

    var body: some View {
        if let id = model.meetingID, let meeting = recorder.meeting(id: id) {
            content(meeting)
        } else {
            Color.clear
        }
    }

    private func content(_ meeting: Meeting) -> some View {
        let live = meeting === recorder.current
        return VStack(spacing: 0) {
            topBar(meeting, live: live)
            if live {
                VStack(alignment: .leading, spacing: 6) {
                    if meeting.joinable { JoinLine(recorder: recorder, meeting: meeting) }
                    RecordingAlerts(recorder: recorder, watcher: watcher)
                }
                .lineLimit(prefs.compact ? 1 : 3)
                .padding(.horizontal, 10)
                MuteStatusBar(recorder: recorder, compact: prefs.compact)
            }
            Divider()
            if prefs.compact {
                latestLine(meeting)
            } else {
                TranscriptList(rows: meeting.lines.map { TranscriptRow($0, meeting: meeting) }, canRename: false,
                               suggestions: [], rename: { _, _ in }, confirm: { _ in }, find: find, walk: walk, live: live,
                               hinting: meeting.labelsFinal ? nil : LineHinting(meeting)) {
                    Text(live ? "Listening…" : "")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 30)
                }
            }
            if !live { savedBar(meeting) }
        }
        // A dimming layer over the blur, as Apple advises for text over
        // bright, busy backgrounds like a video call.
        .background(Color.black.opacity(0.35))
    }

    private func topBar(_ meeting: Meeting, live: Bool) -> some View {
        HStack(spacing: 8) {
            if live {
                HStack(spacing: 5) {
                    Circle().fill(.red).frame(width: 9, height: 9)
                    Text("LIVE").font(.caption.weight(.bold)).foregroundStyle(.red)
                    if let start = meeting.startedAt {
                        Text(start, style: .timer).font(.callout).monospacedDigit()
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Recording")
            } else {
                MeetingStatus(meeting: meeting).font(.callout)
            }
            Button {
                naming = true
            } label: {
                Text(meeting.meetingName.isEmpty ? "Name this meeting" : meeting.meetingName)
                    .lineLimit(1)
                    .foregroundStyle(meeting.meetingName.isEmpty ? .secondary : .primary)
            }
            .buttonStyle(.plain)
            .help("Name this meeting, or link it to your calendar")
            .popover(isPresented: $naming, arrowEdge: .bottom) { NamePopover(recorder: recorder, meeting: meeting) }
            Spacer(minLength: 4)
            if live {
                MuteButton(recorder: recorder)
                Button("New Note") { recorder.split(reason: .user, force: true) }
                    .help("A new call started: keep recording, into a new note from now on")
                Button("Stop") { Task { await watcher.stopRecording() } }
            }
            Button(action: toggleCompact) {
                Image(systemName: prefs.compact ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
            }
            .buttonStyle(.borderless)
            .help(prefs.compact ? "Show the whole transcript" : "Show only the latest line")
            .accessibilityLabel(prefs.compact ? "Expand" : "Compact")
            Button { open(meeting.id) } label: { Image(systemName: "macwindow") }
                .buttonStyle(.borderless)
                .help("Open this meeting in the Wingman window")
                .accessibilityLabel("Open in Wingman")
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func latestLine(_ meeting: Meeting) -> some View {
        let size = ReadingPrefs.shared.size
        return HStack(alignment: .top) {
            if let last = pinned.flatMap({ id in meeting.lines.first { $0.id == id } }) ?? meeting.lines.last {
                let row = TranscriptRow(last, meeting: meeting)
                VStack(alignment: .leading, spacing: 1) {
                    // Who's speaking, as in the full list, so the latest line can be named here too.
                    let label = Text(row.name)
                        .font(.system(size: max(10, (size * 0.8).rounded()), weight: .medium))
                        .foregroundStyle(row.isMe ? Color.accentColor : .green)
                        .lineLimit(1)
                    if !row.isMe, !meeting.labelsFinal {
                        HintButton(row: row, hinting: LineHinting(meeting), editingChanged: { pinned = $0 ? last.id : nil }) { label }
                    } else {
                        label
                    }
                    Text(last.text)
                        .font(.system(size: size))
                        .foregroundStyle(last.isFinal ? .primary : .secondary)
                        .italic(!last.isFinal)
                        .lineLimit(2)
                        .truncationMode(.head)
                }
            } else {
                Text("Listening…").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func savedBar(_ meeting: Meeting) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text(savedText(meeting))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("Open in Wingman") { open(meeting.id) }
                    .controlSize(.small)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

extension LiveTranscriptView {
    private func savedText(_ meeting: Meeting) -> String {
        guard meeting.stage == .done else { return "Saving…" }
        let count = meeting.guessCount
        return count == 0 ? "Saved. Name the speakers in the Wingman window."
                          : "Saved. \(count) \(count == 1 ? "name" : "names") to confirm in the Wingman window."
    }
}

/// The meeting's name and calendar event, from the Live Transcript.
private struct NamePopover: View {
    let recorder: Recorder
    @Bindable var meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name this meeting", text: $meeting.meetingName)
                .frame(width: 260)
                .onSubmit { meeting.applyMeetingName() }
            CalendarEventMenu(recorder: recorder, meeting: meeting)
        }
        .padding(12)
        .onDisappear { meeting.applyMeetingName() }
    }
}
