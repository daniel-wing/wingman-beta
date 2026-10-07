import Foundation

/// What Wingman saw and did for one call, kept for the day so a tester can report a
/// problem with it in two clicks (menu bar → Report a Problem with a Call, or next to
/// the note) instead of digging out the log and saying when it happened. Categories
/// only, like the log: no meeting titles, codes, links or what was said.
struct CallReport: Identifiable, Equatable, Sendable {
    struct Step: Equatable, Sendable {
        let time: Date
        let text: String
    }

    enum Outcome: String, Sendable {
        case seen = "seen"
        case asked = "asked"
        case recorded = "recorded"
        case ignored = "ignored"
        case notRecorded = "not recorded"
    }

    /// The call session it's about.
    let id: UUID
    var app: CallApp
    let started: Date
    var ended: Date?
    var outcome: Outcome = .seen
    private(set) var steps: [Step] = []
    /// The note its recording saved, to offer the report next to that note.
    var note: URL?

    init(id: UUID, app: CallApp, started: Date) {
        self.id = id
        self.app = app
        self.started = started
    }

    mutating func add(_ text: String, at time: Date = Date()) {
        steps.append(Step(time: time, text: text))
    }

    /// "13:31 Google Meet call — recorded", for the menu.
    func menuTitle(timeZone: TimeZone = .current) -> String {
        "\(ProblemReport.time(started, seconds: false, timeZone: timeZone)) \(app.callTitle) — \(outcome.rawValue)"
    }
}

/// The text a tester sends: their sentence, the call's steps, and what explains them
/// (version, Mac, settings, permissions, what Meet detection last saw). They see all
/// of it before it goes anywhere.
enum ProblemReport {
    struct Context: Equatable {
        var version: String
        var system: String
        /// "Teams: Record automatically", in the order Settings shows them.
        var settings: [String]
        /// "Microphone allowed", "Accessibility not allowed"…
        var permissions: [String]
        /// The last "Meet check" per browser, if any (direct-download builds).
        var meetChecks: [String] = []
    }

    static func text(sentence: String, call: CallReport?, context: Context, timeZone: TimeZone = .current) -> String {
        var lines: [String] = []
        let what = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("What went wrong: \(what.isEmpty ? "(not described)" : what)")
        lines.append("")
        lines.append("Wingman \(context.version) · \(context.system)")
        if let call {
            let end = call.ended.map { "–" + time($0, seconds: false, timeZone: timeZone) } ?? " (still going)"
            lines.append("")
            lines.append("Call: \(call.app.callTitle), \(time(call.started, seconds: false, timeZone: timeZone))\(end)")
            for step in call.steps {
                lines.append("  \(time(step.time, seconds: true, timeZone: timeZone))  \(step.text)")
            }
        }
        lines.append("")
        lines.append("Settings: " + context.settings.joined(separator: " · "))
        lines.append("Permissions: " + context.permissions.joined(separator: " · "))
        for check in context.meetChecks {
            lines.append("Meet check: \(check)")
        }
        return lines.joined(separator: "\n")
    }

    static func time(_ date: Date, seconds: Bool, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = seconds ? "HH:mm:ss" : "HH:mm"
        return formatter.string(from: date)
    }
}
