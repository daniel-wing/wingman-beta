import EventKit
import Foundation

/// The calendar event a recording belongs to.
struct MeetingInfo: Equatable, Sendable, Identifiable {
    /// Stable per occurrence (recurring meetings share an event identifier).
    let id: String
    let title: String
    let start: Date
    let end: Date
    let organizer: String?
    /// Invited people other than you, by name (or email when there's no name).
    let attendees: [String]
    let link: URL?
}

/// Finds the calendar event happening now, using whatever calendars macOS
/// Calendar shows (including Outlook/Exchange accounts added there). Read-only.
enum CalendarLookup {
    private static let store = EKEventStore()

    static var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    static var hasBeenAsked: Bool {
        EKEventStore.authorizationStatus(for: .event) != .notDetermined
    }

    @discardableResult
    static func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// What choosing between events looks at, so the choice can be tested
    /// without EventKit.
    struct Choice: Equatable {
        let start: Date
        /// Invitees (2) plus a call link (1): how meeting-like it is.
        let score: Int
        /// You organized it, or it's your own entry with nobody invited.
        let yours: Bool
        let title: String
        var end: Date? = nil
        /// Google Meet codes in its link, location or notes.
        var meetCodes: Set<String> = []
    }

    /// The event for a Google Meet call with this code: one in progress, else the
    /// nearest that starts within the next hour, else the most recent that ended
    /// within the last hour (a meeting joined early or running over). Nil if none
    /// has the code — then the usual choice applies.
    static func pickByMeetCode(_ choices: [Choice], code: String, at date: Date) -> Int? {
        let matching = choices.indices.filter { choices[$0].meetCodes.contains(code) }
        let running = matching.filter { choices[$0].start <= date && (choices[$0].end ?? .distantFuture) > date }
        if let best = running.min(by: { sameStartOrder(choices[$0], choices[$1]) }) { return best }
        let upcoming = matching.filter { choices[$0].start > date && choices[$0].start.timeIntervalSince(date) <= 3600 }
        if let best = upcoming.min(by: { choices[$0].start < choices[$1].start }) { return best }
        let ended = matching.filter {
            guard let end = choices[$0].end else { return false }
            return end <= date && date.timeIntervalSince(end) <= 3600
        }
        return ended.max(by: { (choices[$0].end ?? .distantPast) < (choices[$1].end ?? .distantPast) })
    }

    /// The most meeting-like event, then the closest start. Of several starting
    /// at that time: the one you organized, else the first by title (the
    /// calendar menu offers the others).
    static func pick(_ choices: [Choice], at date: Date) -> Int? {
        guard let best = choices.indices.min(by: { a, b in
            let (x, y) = (choices[a], choices[b])
            if x.score != y.score { return x.score > y.score }
            return abs(x.start.timeIntervalSince(date)) < abs(y.start.timeIntervalSince(date))
        }) else { return nil }
        return choices.indices
            .filter { abs(choices[$0].start.timeIntervalSince(choices[best].start)) < 60 }
            .min { sameStartOrder(choices[$0], choices[$1]) }
    }

    /// Meetings starting together: yours first, then by title.
    static func sameStartOrder(_ a: Choice, _ b: Choice) -> Bool {
        if a.yours != b.yours { return a.yours }
        return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }

    private static func choice(_ event: EKEvent) -> Choice {
        Choice(start: event.startDate, score: score(event),
               yours: event.organizer.map(\.isCurrentUser) ?? !event.hasAttendees,
               title: event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
               end: event.endDate, meetCodes: meetCodes(in: event))
    }

    /// The Google Meet codes in an event's URL, location and notes.
    private static func meetCodes(in event: EKEvent) -> Set<String> {
        var codes = Set<String>()
        if let url = event.url, let code = MeetDetection.meetingCode(fromAddress: url.absoluteString) { codes.insert(code) }
        let text = [event.location, event.notes].compactMap { $0 }.joined(separator: " ")
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let url = match.url, let code = MeetDetection.meetingCode(fromAddress: url.absoluteString) { codes.insert(code) }
            }
        }
        return codes
    }

    /// Calendar events that can be meetings: timed, not cancelled, with invitees
    /// or a call link (personal blocks like "Lunch" have neither).
    private static func meetings(from start: Date, to end: Date) -> [EKEvent] {
        store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { !$0.isAllDay && $0.status != .canceled && !isCancelledTitle($0.title) && score($0) > 0 }
    }

    /// The event most likely to be the meeting starting or running at `date`:
    /// not all-day, started up to 10 minutes from now or already running, chosen
    /// by `pick`. With a Google Meet code, the event with that Meet link comes first.
    static func currentMeeting(at date: Date = Date(), meetCode: String? = nil) -> MeetingInfo? {
        guard isAuthorized else { return nil }
        if let meetCode {
            let nearby = meetings(from: date.addingTimeInterval(-12 * 3600), to: date.addingTimeInterval(3600))
            if let index = pickByMeetCode(nearby.map(choice), code: meetCode, at: date) { return info(nearby[index]) }
        }
        let predicate = store.predicateForEvents(
            withStart: date.addingTimeInterval(-12 * 3600), end: date.addingTimeInterval(15 * 60), calendars: nil)
        let candidates = store.events(matching: predicate).filter {
            !$0.isAllDay && $0.startDate <= date.addingTimeInterval(10 * 60) && $0.endDate > date
                && $0.status != .canceled && !isCancelledTitle($0.title)
                // Personal blocks ("Lunch", "Focus time") have no invitees or call link: not a meeting.
                && score($0) > 0
        }
        return pick(candidates.map(choice), at: date).map { info(candidates[$0]) }
    }

    /// Today's events, for checking what the calendar provides.
    static func today() -> [MeetingInfo] {
        guard isAuthorized else { return [] }
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
            .map(info)
    }

    /// Today's meetings — with invitees or a call link, not cancelled — nearest to
    /// `date` first, for choosing which meeting a recording belongs to. Meetings
    /// at the same time are in `sameStartOrder`, so the automatic pick comes first;
    /// with a Google Meet code, events with that Meet link come before all others.
    static func todaysMeetings(around date: Date = Date(), meetCode: String? = nil) -> [MeetingInfo] {
        guard isAuthorized else { return [] }
        let start = Calendar.current.startOfDay(for: date)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        return meetings(from: start, to: end)
            .map { (event: $0, choice: choice($0)) }
            .sorted {
                if let meetCode {
                    let (a, b) = ($0.choice.meetCodes.contains(meetCode), $1.choice.meetCodes.contains(meetCode))
                    if a != b { return a }
                }
                let (a, b) = (distance($0.event, to: date), distance($1.event, to: date))
                return a != b ? a < b : sameStartOrder($0.choice, $1.choice)
            }
            .map { info($0.event) }
    }

    /// 0 while the meeting is on, otherwise minutes to its start or since its end.
    private static func distance(_ event: EKEvent, to date: Date) -> TimeInterval {
        if event.startDate <= date && event.endDate >= date { return 0 }
        return min(abs(event.startDate.timeIntervalSince(date)), abs(event.endDate.timeIntervalSince(date)))
    }

    /// Outlook keeps cancelled meetings, marking them only in the title.
    static func isCancelledTitle(_ title: String?) -> Bool {
        let lower = (title ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return ["canceled:", "cancelled:", "cancelado:", "cancelada:", "annulé:", "abgesagt:"].contains { lower.hasPrefix($0) }
    }

    private static func score(_ event: EKEvent) -> Int {
        (event.hasAttendees ? 2 : 0) + (callLink(in: event) != nil ? 1 : 0)
    }

    private static func info(_ event: EKEvent) -> MeetingInfo {
        let people = (event.attendees ?? []).filter { !$0.isCurrentUser }.map(name)
        var seen = Set<String>()
        return MeetingInfo(
            id: "\(event.eventIdentifier ?? UUID().uuidString)@\(event.startDate.timeIntervalSince1970)",
            title: event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            start: event.startDate,
            end: event.endDate,
            organizer: event.organizer.flatMap { $0.isCurrentUser ? nil : name($0) },
            attendees: people.filter { seen.insert($0).inserted },
            link: callLink(in: event))
    }

    private static func name(_ participant: EKParticipant) -> String {
        if let name = participant.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty, !name.contains("@") {
            return name
        }
        let address = participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
        return address.removingPercentEncoding ?? address
    }

    /// A Teams, Zoom, Meet or Webex link from the event's URL, location or notes.
    private static func callLink(in event: EKEvent) -> URL? {
        if let url = event.url, isCallLink(url) { return url }
        let text = [event.location, event.notes].compactMap { $0 }.joined(separator: " ")
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap(\.url)
            .first(where: isCallLink)
    }

    /// A web link on a call service's own domain — "zoom.us" or "acme.zoom.us",
    /// but not a lookalike such as "zoom.us.example.com". (http too: a link
    /// typed without "https://" comes out of the text detector as http.)
    static func isCallLink(_ url: URL) -> Bool {
        let hosts = ["teams.microsoft.com", "teams.live.com", "zoom.us", "meet.google.com", "webex.com"]
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""), let host = url.host?.lowercased() else { return false }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
