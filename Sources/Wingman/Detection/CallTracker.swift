import Foundation

/// A call Wingman detected: which app it's in, how sure Wingman is that it's Google
/// Meet, and which meeting. Each session has its own id; a recording, an offer and
/// a deferred call are all tied to one session.
struct CallSession: Equatable, Sendable, Identifiable {
    let id: UUID
    var app: CallApp
    /// For Meet sessions: strong or weak. Teams and Zoom are `.strong` (the app is
    /// the evidence); a plain browser call is `.none`.
    var evidence: MeetEvidence
    var meetingCode: String?
    /// The browser it's in ("<bundle prefix>|<pid>"), for browser and Meet sessions.
    var browser: String?

    /// A Google Meet call recognized on weak evidence (a background tab, a note
    /// Wingman can't read): offered as a guess, never recorded on its own.
    var isUnsureMeet: Bool { app == .meet && evidence < .strong }
}

/// One poll's view of who holds the microphone.
struct MicObservation: Sendable {
    /// Teams and Zoom (apps recognized by their own process).
    var apps: Set<CallApp> = []
    /// Each browser holding the mic, by "<bundle prefix>|<pid>", with what its
    /// windows show.
    var browsers: [String: BrowserScan] = [:]
}

/// What reading one browser's windows showed.
enum BrowserScan: Equatable, Sendable {
    /// Nothing readable: not a browser Wingman can read, no Accessibility, the App
    /// Store build, or the read failed.
    case unavailable
    /// Some windows read, but not all (a time or size limit, an empty window list
    /// with only the front window readable): what's seen counts, what's missing
    /// proves nothing.
    case partial([MeetCandidate])
    /// Every window read in full: a meeting missing here really isn't capturing.
    case complete([MeetCandidate])
}

/// Turns polls into call sessions:
/// - an app or a meeting starts once seen for 3 s and ends after 6 s gone;
/// - Meet sessions are tracked by meeting code, so reordering tabs, moving one to
///   another window or opening the same meeting twice changes nothing, and a
///   different code is a different meeting;
/// - "gone" for a meeting only counts in complete scans; partial or unavailable
///   ones neither end it nor run its clock — only the browser releasing the mic does;
/// - evidence can improve within a session (weak → strong) and is never lowered;
/// - a browser's own session (a plain browser call) only starts when no meeting is
///   seen in it, and not at all after a Meet call ended while the browser kept the
///   mic, until it lets go.
/// Pure: the detector feeds it, tests drive it with made-up polls.
struct CallTracker {
    enum Event: Equatable {
        case started(CallSession)
        /// Same session, better evidence (or its code became known).
        case updated(CallSession)
        case ended(CallSession)
    }

    static let startAfter: TimeInterval = 3
    static let endAfter: TimeInterval = 6

    private struct AppState {
        var firstSeen: Date?
        var lastSeen: Date?
        var session: CallSession?
    }

    private struct MeetingState {
        var firstSeen: Date
        /// When complete scans started missing it; reset by any other reading.
        var missingSince: Date?
        var candidate: MeetCandidate
        var session: CallSession?
    }

    private struct BrowserState {
        var firstSeen: Date
        var lastSeen: Date
        var plainSession: CallSession?
        /// A Meet call ended while the browser kept the mic: don't offer that
        /// leftover as a browser call until it lets go.
        var holdBackPlain = false
        var meetings: [String: MeetingState] = [:]
    }

    private var apps: [CallApp: AppState] = [:]
    private var browsers: [String: BrowserState] = [:]
    private var lastSequence = Int.min
    private let makeID: () -> UUID

    init(makeID: @escaping () -> UUID = UUID.init) {
        self.makeID = makeID
    }

    /// Sessions that started and haven't ended.
    var sessions: [CallSession] {
        apps.values.compactMap(\.session)
            + browsers.values.flatMap { [$0.plainSession].compactMap { $0 } + $0.meetings.values.compactMap(\.session) }
    }

    func isActive(_ id: UUID) -> Bool { sessions.contains { $0.id == id } }

    func session(_ id: UUID) -> CallSession? { sessions.first { $0.id == id } }

    /// Feeds one poll. Results arriving out of order (an older sequence number)
    /// are ignored.
    mutating func update(_ observation: MicObservation, at now: Date, sequence: Int) -> [Event] {
        guard sequence > lastSequence else { return [] }
        lastSequence = sequence
        var events: [Event] = []
        updateApps(observation.apps, now: now, events: &events)
        for (key, scan) in observation.browsers {
            updateBrowser(key, scan: scan, now: now, events: &events)
        }
        for (key, state) in browsers where observation.browsers[key] == nil {
            let sessions = [state.plainSession].compactMap({ $0 }) + state.meetings.values.compactMap(\.session)
            // Gone before anything started: its 3 s start over, like an app's.
            if sessions.isEmpty {
                browsers[key] = nil
            } else if now.timeIntervalSince(state.lastSeen) >= Self.endAfter {
                events.append(contentsOf: sessions.map(Event.ended))
                browsers[key] = nil
            }
        }
        return events
    }

    private mutating func updateApps(_ present: Set<CallApp>, now: Date, events: inout [Event]) {
        for app in CallApp.allCases where app != .browser && app != .meet {
            var state = apps[app] ?? AppState()
            if present.contains(app) {
                state.lastSeen = now
                if state.firstSeen == nil { state.firstSeen = now }
                if state.session == nil, let first = state.firstSeen, now.timeIntervalSince(first) >= Self.startAfter {
                    let session = CallSession(id: makeID(), app: app, evidence: .strong)
                    state.session = session
                    events.append(.started(session))
                }
            } else {
                if state.session == nil { state.firstSeen = nil }
                if let session = state.session, let last = state.lastSeen, now.timeIntervalSince(last) >= Self.endAfter {
                    events.append(.ended(session))
                    state = AppState()
                }
            }
            apps[app] = state
        }
    }

    private mutating func updateBrowser(_ key: String, scan: BrowserScan, now: Date, events: inout [Event]) {
        var state = browsers[key] ?? BrowserState(firstSeen: now, lastSeen: now)
        state.lastSeen = now

        let seen: [MeetCandidate]
        let complete: Bool
        switch scan {
        case .complete(let found): seen = found; complete = true
        case .partial(let found): seen = found; complete = false
        case .unavailable: seen = []; complete = false
        }
        let seenKeys = Set(seen.map(\.key))

        for candidate in seen {
            // A tab first titled just "Meet" gets its code once its page is drawn:
            // the same meeting, so the session takes the code instead of a new one.
            if state.meetings[candidate.key] == nil, candidate.source == .tab, candidate.code != nil,
               var codeless = state.meetings["meet-tab"], !seenKeys.contains("meet-tab") {
                codeless.candidate.code = candidate.code
                codeless.missingSince = nil
                if var session = codeless.session {
                    session.meetingCode = candidate.code
                    session.evidence = max(session.evidence, candidate.evidence)
                    codeless.session = session
                    events.append(.updated(session))
                }
                codeless.candidate.evidence = max(codeless.candidate.evidence, candidate.evidence)
                state.meetings["meet-tab"] = nil
                state.meetings[candidate.key] = codeless
                continue
            }
            if var meeting = state.meetings[candidate.key] {
                meeting.missingSince = nil
                if candidate.evidence > meeting.candidate.evidence {
                    meeting.candidate.evidence = candidate.evidence
                    if var session = meeting.session {
                        session.evidence = candidate.evidence
                        meeting.session = session
                        events.append(.updated(session))
                    }
                }
                state.meetings[candidate.key] = meeting
            } else {
                state.meetings[candidate.key] = MeetingState(firstSeen: now, candidate: candidate)
            }
        }

        var meetEnded = false
        for (meetingKey, var meeting) in state.meetings where !seenKeys.contains(meetingKey) {
            guard complete else {
                // Not seen, but this reading can't say it's gone: no clock runs.
                meeting.missingSince = nil
                state.meetings[meetingKey] = meeting
                continue
            }
            guard let session = meeting.session else {
                state.meetings[meetingKey] = nil  // never started: its 3 s start over
                continue
            }
            let since = meeting.missingSince ?? now
            if now.timeIntervalSince(since) >= Self.endAfter {
                events.append(.ended(session))
                state.meetings[meetingKey] = nil
                meetEnded = true
            } else {
                meeting.missingSince = since
                state.meetings[meetingKey] = meeting
            }
        }
        if meetEnded && state.meetings.values.allSatisfy({ $0.session == nil }) && state.plainSession == nil {
            state.holdBackPlain = true
        }

        // Only a meeting seen in this poll starts: readings that can't see it
        // (partial, unavailable) don't count as it being there.
        for (meetingKey, var meeting) in state.meetings
        where meeting.session == nil && seenKeys.contains(meetingKey) && now.timeIntervalSince(meeting.firstSeen) >= Self.startAfter {
            let session = CallSession(id: makeID(), app: .meet, evidence: meeting.candidate.evidence,
                                      meetingCode: meeting.candidate.code, browser: key)
            meeting.session = session
            state.meetings[meetingKey] = meeting
            events.append(.started(session))
        }

        if state.plainSession == nil, !state.holdBackPlain, state.meetings.isEmpty,
           now.timeIntervalSince(state.firstSeen) >= Self.startAfter {
            let session = CallSession(id: makeID(), app: .browser, evidence: .none, browser: key)
            state.plainSession = session
            events.append(.started(session))
        }
        browsers[key] = state
    }
}
