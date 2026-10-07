import Foundation

/// `Wingman calendarcheck` lists today's events as Wingman sees them: title,
/// time, how many invited people come through, and whether a call link is found.
enum CalendarCheck {
    @MainActor
    static func run(_ args: [String]) async -> Int32 {
        if !CalendarLookup.isAuthorized {
            print("No calendar access yet — asking…")
            guard await CalendarLookup.requestAccess() else {
                print("Calendar access denied.")
                return 1
            }
        }
        let events = CalendarLookup.today()
        print(events.isEmpty ? "No timed events today." : "\(events.count) event(s) today:")
        for event in events {
            let time = "\(event.start.formatted(date: .omitted, time: .shortened))–\(event.end.formatted(date: .omitted, time: .shortened))"
            print("• \(time)  \(event.title.isEmpty ? "(no title)" : event.title)")
            print("    organizer: \(event.organizer ?? "—"), invited: \(event.attendees.count), call link: \(event.link?.host ?? "none")")
        }
        if let now = CalendarLookup.currentMeeting() { print("\nRight now: \(now.title)") }
        let picks = CalendarLookup.todaysMeetings()
        print("\nMeeting menu (nearest first, cancelled and personal blocks left out): \(picks.count)")
        for meeting in picks {
            print("  \(meeting.start.formatted(date: .omitted, time: .shortened))–\(meeting.end.formatted(date: .omitted, time: .shortened))  \(meeting.title)")
        }
        return 0
    }
}
