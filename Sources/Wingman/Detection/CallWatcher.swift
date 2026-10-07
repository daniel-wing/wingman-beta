import AppKit
import Foundation
import Observation

/// Connects call detection to recording, following the per-app choice in
/// Settings: record automatically, ask first, or ignore. Recordings started
/// for a call stop by themselves when that call ends.
///
/// Everything is per call session (`CallTracker`): an offer, a postponed call and a
/// recording belong to one session, so a second meeting never ends the first, and
/// a Meet call whose evidence improves (weak → strong) is the same call — it isn't
/// asked about twice, isn't restarted, and an "Ignore" given for it stays.
@MainActor
@Observable
final class CallWatcher {
    var policies: [CallApp: AutoRecordPolicy] {
        didSet { save() }
    }
    /// A call waiting for an answer, shown in the window when notifications are off.
    private(set) var pendingCall: CallSession?
    /// A call that started while Wingman was busy (finishing the previous
    /// meeting, transcribing a file, recording another call); offered once it's
    /// free, if still going — or recorded straight away if the user already said "Record".
    private var deferredCall: (session: CallSession, answered: Bool)?
    /// Sessions the user answered (Record or Ignore): never asked again, whatever
    /// their evidence becomes. Sessions already offered aren't offered twice.
    private var answered: Set<UUID> = []
    private var offered: Set<UUID> = []
    /// Today's calls, newest first: what Wingman saw and did, for "Report a Problem
    /// with a Call" (no titles, codes or links).
    private(set) var reports: [CallReport] = []
    /// The call whose recording is running or being finished, to note how it ended.
    private var recordingReport: UUID?

    private let recorder: Recorder
    private let notifier: Notifier
    private var detector: CallDetector?
    /// Opens the Wingman window (set by the app, which owns window handling).
    var showWindow: (() -> Void)?

    init(recorder: Recorder, notifier: Notifier) {
        self.recorder = recorder
        self.notifier = notifier
        let saved = UserDefaults.standard.dictionary(forKey: "autoRecord") as? [String: String] ?? [:]
        var policies: [CallApp: AutoRecordPolicy] = [:]
        for app in CallApp.allCases {
            policies[app] = saved[app.rawValue].flatMap(AutoRecordPolicy.init(rawValue:)) ?? .ask
        }
        policies[.meet] = Self.meetPolicy(saved: saved) ?? policies[.meet]
        self.policies = policies
        notifier.onAction = { [weak self] action in self?.handle(action) }
        recorder.onPhaseChange = { [weak self] old, new in self?.phaseChanged(from: old, to: new) }
    }

    /// Updating from before Meet was its own call app: Meet calls were browser
    /// calls, so they keep that choice (no surprise prompts or recordings).
    static func meetPolicy(saved: [String: String]) -> AutoRecordPolicy? {
        if let meet = saved[CallApp.meet.rawValue].flatMap(AutoRecordPolicy.init(rawValue:)) { return meet }
        return saved[CallApp.browser.rawValue].flatMap(AutoRecordPolicy.init(rawValue:))
    }

    func start() {
        guard detector == nil else { return }
        #if APP_STORE
        let detector = CallDetector { [weak self] event in self?.handle(event) }
        #else
        let detector = CallDetector(inspect: { pid, family in
            await MeetInspector.shared.scan(browserPID: pid, family: family)
        }) { [weak self] event in self?.handle(event) }
        #endif
        detector.start()
        self.detector = detector
    }

    func policy(for app: CallApp) -> AutoRecordPolicy { policies[app] ?? .ask }

    /// What applies to a session: its app's choice, or for Google Meet the one its
    /// evidence allows (weak Meet evidence never records on its own).
    func policy(for session: CallSession) -> AutoRecordPolicy {
        guard session.app == .meet else { return policy(for: session.app) }
        return MeetDetection.effectivePolicy(evidence: session.evidence, meet: policy(for: .meet), browser: policy(for: .browser))
    }

    private func save() {
        UserDefaults.standard.set(
            Dictionary(uniqueKeysWithValues: policies.map { ($0.key.rawValue, $0.value.rawValue) }), forKey: "autoRecord")
    }

    // MARK: - Calls

    private func handle(_ event: CallDetector.Event) {
        switch event {
        case .started(let session):
            Log.write("call started: \(Self.describe(session))")
            track(session)
            if session.app == .meet { quietBrowserPrompt(for: session) }
            arrived(session)
        case .updated(let session):
            Log.write("call evidence now: \(Self.describe(session))")
            #if !APP_STORE
            if session.evidence == .strong { note(session.id, "Now sure it's Google Meet") }
            #endif
            if pendingCall?.id == session.id { pendingCall = session }
            if deferredCall?.session.id == session.id { deferredCall?.session = session }
            guard Self.actsOnUpdate(session.id, answered: answered, offered: offered,
                                    recording: recorder.callSessionID, deferred: deferredCall?.session.id) else { return }
            arrived(session)
        case .ended(let session):
            Log.write("call ended: \(Self.describe(session))")
            note(session.id, "Call ended")
            if let i = reports.firstIndex(where: { $0.id == session.id }) { reports[i].ended = Date() }
            if pendingCall?.id == session.id {
                pendingCall = nil
                notifier.withdrawAsk()
            }
            if deferredCall?.session.id == session.id { deferredCall = nil }
            if recorder.isRecording, recorder.callSessionID == session.id {
                Task { await finish() }
            }
            answered.remove(session.id)
            offered.remove(session.id)
        }
    }

    /// Whether a session whose evidence improved gets a (first) offer now. Better
    /// evidence may allow what it didn't before — weak Meet evidence held back by
    /// an Off, now strong — but an answer (Record or Ignore), an offer already made,
    /// a postponed call or a running recording stays as it is.
    static func actsOnUpdate(_ id: UUID, answered: Set<UUID>, offered: Set<UUID>, recording: UUID?, deferred: UUID?) -> Bool {
        !answered.contains(id) && !offered.contains(id) && recording != id && deferred != id
    }

    /// A session to act on now or once Wingman is free.
    private func arrived(_ session: CallSession) {
        switch recorder.phase {
        case .idle:
            offer(session)
        case .recording:
            // Joining the next meeting before leaving this one: once this
            // call's recording stops, offer the new one if it's still going.
            // (A recording started by hand is left to the user.)
            if let current = recorder.callSessionID, current != session.id {
                postpone(session, answered: false)
                note(session.id, "Another call was being recorded; offered once that recording ends")
            } else if recorder.callSessionID == nil {
                note(session.id, "Not offered: a recording started by hand was running")
            }
        case .preparing, .finishing:
            // Each call is reported once, so remember it rather than lose it.
            postpone(session, answered: false)
            note(session.id, "Wingman was busy (finishing a meeting or a file); offered once it's free")
            Log.write("\(session.app.callTitle) started while Wingman was busy; offering it when done")
        }
    }

    /// A Meet call showed up in a browser whose mic use was being asked about as a
    /// plain browser call: that question is replaced by the Meet one.
    private func quietBrowserPrompt(for meet: CallSession) {
        guard let pending = pendingCall, pending.app == .browser, pending.browser == meet.browser else { return }
        answered.insert(pending.id)
        pendingCall = nil
        notifier.withdrawAsk()
        #if !APP_STORE
        note(pending.id, "Question withdrawn: it turned out to be Google Meet", outcome: .notRecorded)
        #endif
    }

    /// Follows the policy for a call that has started: record, ask, or nothing.
    private func offer(_ session: CallSession) {
        guard !answered.contains(session.id) else { return }
        let policy = policy(for: session)
        note(session.id, Self.offerStep(session, policy: policy, meet: self.policy(for: .meet), browser: self.policy(for: .browser)),
             outcome: policy == .ask ? .asked : policy == .off ? .notRecorded : nil)
        switch policy {
        case .automatic:
            Task { await record(session) }
        case .ask:
            offered.insert(session.id)
            pendingCall = session
            Task {
                if await notifier.isAuthorized {
                    let title = recorder.useCalendar ? CalendarLookup.currentMeeting(meetCode: session.meetingCode)?.title : nil
                    notifier.askToRecord(session, meeting: title)
                } else {
                    note(session.id, "Notifications are off, so the question opened the Wingman window")
                    // Nothing else will tell the user, so bring the window to the front.
                    showWindow?()
                    NSApp.requestUserAttention(.informationalRequest)
                }
            }
        case .off:
            break
        }
    }

    /// For a call's report: what Wingman did when the call started, and why.
    static func offerStep(_ session: CallSession, policy: AutoRecordPolicy, meet: AutoRecordPolicy, browser: AutoRecordPolicy) -> String {
        var setting = "\(session.app.name) is set to \(policy.name)"
        #if !APP_STORE
        if session.isUnsureMeet {
            setting = "not sure it's Google Meet, so it does at most Ask me first (Google Meet: \(meet.name), Browser calls: \(browser.name))"
        }
        #endif
        switch policy {
        case .automatic: return "Recording automatically: \(setting)"
        case .ask: return "Asked whether to record: \(setting)"
        case .off: return "Not recorded: \(setting)"
        }
    }

    /// Remembers a call for later. One slot: a "Record" the user already
    /// clicked isn't replaced by a call they haven't been asked about.
    private func postpone(_ session: CallSession, answered: Bool) {
        if deferredCall?.answered == true && !answered { return }
        deferredCall = (session, answered)
    }

    private func phaseChanged(from old: Recorder.Phase, to new: Recorder.Phase) {
        // However a recording stops (window, menu, shortcut), its notification goes.
        if old == .recording { notifier.withdrawRecording() }
        if old == .recording, let id = recordingReport, report(id)?.ended == nil {
            note(id, "Recording stopped while the call was still going")
        }
        if case .finishing = old, new == .idle, let id = recordingReport {
            recordingReport = nil
            note(id, recorder.currentNote == nil ? "No note saved" : "Note saved")
            if let warning = recorder.warning { note(id, "Warning shown: \(Log.redacted(warning))") }
            if let i = reports.firstIndex(where: { $0.id == id }) { reports[i].note = recorder.currentNote }
        }
        switch new {
        case .recording:
            // The session a recording is for is set just after this; look then.
            // A recording of that call, or one started by hand, covers it.
            Task { [weak self] in
                guard let self, let deferred = self.deferredCall, self.recorder.isRecording else { return }
                if self.recorder.callSessionID == nil || self.recorder.callSessionID == deferred.session.id { self.deferredCall = nil }
            }
        case .idle:
            guard let deferred = deferredCall, !recorder.quitting else { return }
            deferredCall = nil
            guard let session = detector?.current(deferred.session) else {
                note(deferred.session.id, "Ended before Wingman was free")
                return
            }
            if deferred.answered {
                Task { await record(session) }
            } else {
                offer(session)
            }
        default:
            break
        }
    }

    private func handle(_ action: Notifier.Action) {
        switch action {
        case .record:
            if let session = pendingCall {
                note(session.id, "You chose Record")
                Task { await record(session) }
            }
        case .ignore:
            if let session = pendingCall {
                answered.insert(session.id)
                note(session.id, "You chose Ignore", outcome: .ignored)
            }
            pendingCall = nil
        case .stop:
            Task { await finish() }
        case .discard:
            Task {
                await recorder.discard()
                notifier.withdrawRecording()
            }
        }
    }

    /// Answers the in-window prompt.
    func answerPending(record: Bool) {
        guard let session = pendingCall else { return }
        if record {
            note(session.id, "You chose Record")
            Task { await self.record(session) }
        } else {
            answered.insert(session.id)
            note(session.id, "You chose Ignore", outcome: .ignored)
            pendingCall = nil
        }
    }

    private func record(_ session: CallSession) async {
        answered.insert(session.id)
        pendingCall = nil
        notifier.withdrawAsk()
        switch recorder.phase {
        case .idle:
            break
        case .preparing, .finishing:
            postpone(session, answered: true)  // "Record" clicked while busy: do it once free
            note(session.id, "Wingman was busy; recording once it's free")
            return
        case .recording:
            note(session.id, "Not recorded: another recording was running")
            return
        }
        await recorder.start(for: session)
        guard recorder.isRecording, recorder.callSessionID == session.id else {
            note(session.id, "Recording didn't start" + (recorder.lastError.map { ": \(Log.redacted($0))" } ?? ""),
                 outcome: .notRecorded)
            return
        }
        recordingReport = session.id
        note(session.id, "Recording started", outcome: .recorded)
        if recorder.useCalendar {
            note(session.id, recorder.meeting == nil ? "No calendar event found, so the note is named by time" : "Named from a calendar event")
        }
        // The call may have ended while the speech model was loading.
        if detector?.isActive(session) == false {
            Log.write("\(session.app.callTitle) ended while recording was starting; stopping")
            note(session.id, "The call ended while recording was starting; stopped")
            await finish()
            return
        }
        let name = recorder.meetingName.trimmingCharacters(in: .whitespaces)
        notifier.announceRecording(session.app, meeting: name.isEmpty ? nil : name)
    }

    private func finish() async {
        notifier.withdrawRecording()
        await recorder.stop()
        // Read right away: a call waiting to be recorded may start next and clear the warning.
        if let note = recorder.currentNote {
            notifier.announceSaved(note.deletingPathExtension().lastPathComponent, warning: recorder.warning)
        }
    }

    // MARK: - Reports

    /// The report of the call whose recording saved `note`.
    func report(forNote note: URL) -> CallReport? {
        reports.first { $0.note == note }
    }

    /// Today's calls, newest first.
    var todaysReports: [CallReport] {
        reports.filter { Calendar.current.isDateInToday($0.started) }
    }

    private func report(_ id: UUID) -> CallReport? {
        reports.first { $0.id == id }
    }

    private func track(_ session: CallSession) {
        var report = CallReport(id: session.id, app: session.app, started: Date())
        report.add("Seen: " + Self.seen(session))
        reports.insert(report, at: 0)
        reports = Array(todaysReports.prefix(12))
    }

    private func note(_ id: UUID, _ text: String, outcome: CallReport.Outcome? = nil) {
        guard let i = reports.firstIndex(where: { $0.id == id }) else { return }
        reports[i].add(text)
        if let outcome { reports[i].outcome = outcome }
    }

    /// How a call was recognized, for its report.
    static func seen(_ session: CallSession) -> String {
        switch session.app {
        case .meet:
            #if APP_STORE
            return session.app.name
            #else
            return session.evidence == .strong
                ? "Google Meet (sure it's Meet)"
                : "Google Meet (not sure: the Meet tab isn't in front, or Chrome's language isn't one Wingman can read yet)"
            #endif
        case .browser:
            return "a browser is using the microphone (not recognized as Google Meet)"
        default:
            return "\(session.app.name) is using the microphone"
        }
    }

    /// For the log: categories only — never titles, codes or addresses.
    private static func describe(_ session: CallSession) -> String {
        switch session.app {
        case .meet:
            let evidence = session.evidence == .strong ? "strong" : "weak"
            return "Google Meet (\(evidence)\(session.meetingCode == nil ? ", no code" : ""))"
        default:
            return session.app.callTitle
        }
    }
}
