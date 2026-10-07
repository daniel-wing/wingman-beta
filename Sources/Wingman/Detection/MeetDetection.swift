import Foundation

/// How sure Wingman is that a browser's microphone use is a Google Meet call,
/// from measurements of Chrome 155 in English. Pure: everything here works on
/// titles and addresses already read, so it's the same in every build.
enum MeetEvidence: Int, Comparable, Sendable {
    /// No Meet evidence (or nothing readable): a plain browser call.
    case none
    /// Looks like Meet, but its identity or its capturing isn't confirmed: a
    /// Meet-looking tab that isn't the selected one, a Meet tab whose recording
    /// note isn't readable, the Meet app whose indicator isn't readable.
    case weak
    /// A recording tab whose own address is meet.google.com/<its code> (it's the
    /// selected tab of its window), or the Meet app showing its capture indicator.
    case strong

    static func < (a: MeetEvidence, b: MeetEvidence) -> Bool { a.rawValue < b.rawValue }
}

/// One tab as Chrome's tab strip shows it.
struct BrowserTab: Equatable, Sendable {
    var title: String
    var isSelected: Bool
}

/// One browser window: its tabs and its address bar (the selected tab's address).
struct BrowserWindowScan: Equatable, Sendable {
    var tabs: [BrowserTab]
    var address: String?
}

/// A Meet call one scan found: by its code, or without one yet (a tab titled
/// just "Meet" until its page is drawn; the Meet app, whose code isn't readable).
struct MeetCandidate: Equatable, Sendable {
    enum Source: Equatable, Sendable { case tab, app }
    var code: String?
    var evidence: MeetEvidence
    var source: Source

    /// What a session is tracked by: the code, else where it was seen.
    var key: String {
        if let code { return "code:\(code)" }
        return source == .app ? "meet-app" : "meet-tab"
    }
}

/// What the Meet app's title bar says, if it's running.
enum MeetAppIndicator: Equatable, Sendable {
    /// "This page is accessing your microphone." is showing.
    case capturing
    /// Read, and not showing.
    case idle
    /// Running, but the indicator couldn't be read (or isn't in a known language).
    case unknown
}

enum MeetDetection {
    /// The Google Meet app installed from Chrome ("app shim"), the same id everywhere.
    static let meetAppID = "kjgfgldnnfoeklkmfkjfagphfepbbdan"

    private static let codePattern = try! NSRegularExpression(pattern: #"(?<![a-z0-9-])([a-z]{3}-[a-z]{4}-[a-z]{3})(?![a-z0-9-])"#)

    /// A meeting code anywhere in `text` ("abc-defg-hij").
    static func meetingCode(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = codePattern.firstMatch(in: text, range: range),
              let found = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[found])
    }

    /// The code of a Meet address: the host must be exactly meet.google.com and
    /// the code the first path component. Accepts what the address bar shows
    /// ("meet.google.com/abc-defg-hij?authuser=0") and full URLs.
    static func meetingCode(fromAddress address: String) -> String? {
        let text = address.trimmingCharacters(in: .whitespaces)
        let withScheme = text.contains("://") ? text : "https://" + text
        guard let url = URL(string: withScheme), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.lowercased() == "meet.google.com" else { return nil }
        let first = url.path.split(separator: "/").first.map(String.init) ?? ""
        guard let code = meetingCode(in: first), code == first else { return nil }
        return code
    }

    /// Whether a tab title is Meet's: "Meet" alone or followed by a separator.
    /// Meet's own formats (measured): en "Meet – code", es "Meet - code",
    /// pt-BR "Meet: code"; before its page is drawn a tab may say just "Meet".
    static func isMeetTitle(_ title: String) -> Bool {
        guard title.hasPrefix("Meet") else { return false }
        let rest = title.dropFirst(4)
        return rest.isEmpty || rest.hasPrefix(" – ") || rest.hasPrefix(" - ") || rest.hasPrefix(": ")
    }

    /// The code right after "Meet" and its separator, or nil.
    static func meetTitleCode(_ title: String) -> String? {
        guard isMeetTitle(title) else { return nil }
        for separator in [" – ", " - ", ": "] where title.dropFirst(4).hasPrefix(separator) {
            let rest = title.dropFirst(4 + separator.count)
            let code = String(rest.prefix(12))
            if code.count == 12, meetingCode(in: code) == code { return code }
        }
        return nil
    }

    /// Chrome's notes on a tab that captures the microphone. English is measured
    /// (Chrome 155); the others are Chrome's translations of the same strings and
    /// not measured. A camera-only note doesn't count: it says nothing about the mic.
    static let recordingNotes: [(language: String, notes: [String], measured: Bool)] = [
        ("en", ["Camera and microphone recording", "Microphone recording"], true),
    ]

    /// Whether a tab title carries a microphone recording note.
    static func hasRecordingNote(_ title: String) -> Bool {
        recordingNotes.contains { entry in entry.notes.contains { title.contains(" - " + $0) } }
    }

    /// The Meet app's title-bar indicator (English measured, Chrome 155): "This page
    /// is accessing your microphone." or "…your camera and microphone."
    static func isCaptureIndicator(_ label: String) -> Bool {
        label.hasPrefix("This page is accessing your") && label.contains("microphone")
    }

    /// Whether Chrome's notes are in a language this table has, judged by the
    /// browser's UI language (its own `AppleLanguages`, else the Mac's): Chrome uses
    /// the first preferred language it supports.
    static func notesReadable(preferredLanguages: [String]) -> Bool {
        guard let first = preferredLanguages.first?.lowercased() else { return false }
        return recordingNotes.contains { first == $0.language || first.hasPrefix($0.language + "-") }
    }

    /// The Meet calls one browser scan shows. A tab counts only while it carries a
    /// recording note; it is strong only when it's its window's selected tab and that
    /// same window's address is meet.google.com/<the same code> — the address also
    /// gives the code while Meet hasn't put it in the title yet (a page that hasn't
    /// been drawn, e.g. in a window that's not on screen, is titled just "Meet"). The
    /// selected tab's address never vouches for another tab. When Chrome's notes
    /// aren't readable (another UI language), a Meet tab with a code is weak — it may
    /// or may not be capturing — so Wingman can ask but never records on its own.
    static func candidates(in windows: [BrowserWindowScan], meetApp: MeetAppIndicator?,
                           notesReadable: Bool = true) -> [MeetCandidate] {
        var found: [String: MeetCandidate] = [:]
        func add(_ candidate: MeetCandidate) {
            if let existing = found[candidate.key], existing.evidence >= candidate.evidence { return }
            found[candidate.key] = candidate
        }
        for window in windows {
            let addressCode = window.address.flatMap(meetingCode(fromAddress:))
            for tab in window.tabs where isMeetTitle(tab.title) {
                let ownAddressCode = tab.isSelected ? addressCode : nil
                let code = meetTitleCode(tab.title) ?? ownAddressCode
                if notesReadable {
                    guard hasRecordingNote(tab.title) else { continue }
                    let verified = ownAddressCode != nil && code == ownAddressCode
                    add(MeetCandidate(code: code, evidence: verified ? .strong : .weak, source: .tab))
                } else if let code, meetApp != .capturing {
                    add(MeetCandidate(code: code, evidence: .weak, source: .tab))
                }
            }
        }
        switch meetApp {
        case .capturing: add(MeetCandidate(code: nil, evidence: .strong, source: .app))
        case .unknown: add(MeetCandidate(code: nil, evidence: .weak, source: .app))
        case .idle, nil: break
        }
        return found.values.sorted { $0.key < $1.key }
    }

    /// For the log: what a scan found, by kind only — never titles or codes.
    static func summary(_ candidates: [MeetCandidate]) -> String {
        guard !candidates.isEmpty else { return "no Meet call" }
        return candidates.map { candidate in
            let kind = candidate.source == .app ? "Meet app" : "Meet tab"
            let evidence = candidate.evidence == .strong ? "strong" : "weak"
            return "\(kind) \(evidence)" + (candidate.source == .tab && candidate.code == nil ? " (no code yet)" : "")
        }.joined(separator: ", ")
    }

    /// What a Meet session's evidence allows, given the two Settings choices:
    /// strong follows the Meet setting; weak never records on its own — at most it
    /// asks, and an Off in either setting wins; no evidence follows Browser calls.
    static func effectivePolicy(evidence: MeetEvidence, meet: AutoRecordPolicy, browser: AutoRecordPolicy) -> AutoRecordPolicy {
        switch evidence {
        case .strong: return meet
        case .weak: return [meet, browser, .ask].min(by: { $0.strength < $1.strength })!
        case .none: return browser
        }
    }

    /// Whether a running app is Google Meet installed from a browser: its bundle is a
    /// web-app shim of the Meet app, or its shortcut opens meet.google.com.
    static func isMeetApp(bundleID: String?, shortcutURL: String?) -> Bool {
        if let bundleID, bundleID.hasSuffix(".app." + meetAppID) { return true }
        guard let shortcutURL, let url = URL(string: shortcutURL) else { return false }
        return url.host?.lowercased() == "meet.google.com"
    }
}

extension AutoRecordPolicy {
    /// Off < Ask me first < Record automatically.
    var strength: Int {
        switch self {
        case .off: return 0
        case .ask: return 1
        case .automatic: return 2
        }
    }
}
