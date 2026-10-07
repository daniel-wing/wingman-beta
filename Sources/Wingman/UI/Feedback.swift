import AppKit
import Foundation

/// "Send Feedback…": opens a form in the beta's public GitHub repo with the
/// Wingman version, macOS version and Mac filled in, and can show the log file
/// so the tester can attach it (it has no audio or transcript text). Wingman
/// itself sends nothing — the tester reviews and submits the form.
enum Feedback {
    static let repo = "https://github.com/daniel-wing/wingman-beta"

    enum Kind: String {
        case problem = "problem.yml"
        case idea = "idea.yml"
    }

    /// The new-issue form for `kind`, with the system details pre-filled (the
    /// query names match the form fields' ids).
    static func url(_ kind: Kind) -> URL {
        var components = URLComponents(string: "\(repo)/issues/new")!
        components.queryItems = [
            URLQueryItem(name: "template", value: kind.rawValue),
            URLQueryItem(name: "version", value: appVersion),
            URLQueryItem(name: "system", value: systemDescription),
        ]
        return components.url!
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    /// e.g. "macOS 26.6.2, Apple M4, Mac16,12, 16 GB".
    static var systemDescription: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let memory = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
        return "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion), \(sysctl("machdep.cpu.brand_string") ?? "?"), \(sysctl("hw.model") ?? "?"), \(memory) GB"
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    @MainActor
    static func show() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Send feedback about Wingman"
        alert.informativeText = """
        This opens a short form on GitHub (a free account is needed) with your Wingman version and Mac \
        filled in. You see everything before you send it.

        For a problem, attaching Wingman's log helps a lot. It lists what the app did (devices, \
        permissions, timings) — never audio or what was said. It does include your audio devices' names \
        (like "Ana's AirPods"), so have a look before attaching it: reports are public.
        """
        alert.addButton(withTitle: "Report a Problem…")
        alert.addButton(withTitle: "Suggest an Idea…")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Show the log file so I can attach it"
        alert.suppressionButton?.state = .on

        let kind: Kind
        switch alert.runModal() {
        case .alertFirstButtonReturn: kind = .problem
        case .alertSecondButtonReturn: kind = .idea
        default: return
        }
        NSWorkspace.shared.open(url(kind))
        if alert.suppressionButton?.state == .on, FileManager.default.fileExists(atPath: Log.file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([Log.file])
        }
        Log.write("feedback form opened (\(kind == .problem ? "problem" : "idea"))")
    }
}

/// "Report a Problem with a Call": a short report of one call — what Wingman saw
/// and did, with its settings and permissions — plus the tester's one sentence.
/// The dialog shows everything that would be shared; the tester copies it into a
/// message or opens the GitHub form with it filled in. Nothing is sent by Wingman.
@MainActor
final class ProblemReporter {
    private let watcher: CallWatcher
    private let recorder: Recorder
    private let permissions: Permissions
    private let followMute: () -> Bool?

    init(watcher: CallWatcher, recorder: Recorder, permissions: Permissions, followMute: @escaping () -> Bool?) {
        self.watcher = watcher
        self.recorder = recorder
        self.permissions = permissions
        self.followMute = followMute
    }

    func report(_ call: CallReport?) {
        Task {
            let context = await context()
            Self.present(call: call, context: context)
        }
    }

    private func context() async -> ProblemReport.Context {
        await permissions.refresh()
        var settings = CallApp.shown.map { "\($0.name): \(watcher.policy(for: $0).name)" }
        if let followMute = followMute() { settings.append("Follow my mute: \(followMute ? "on" : "off")") }
        settings.append("Name meetings from my calendar: \(recorder.useCalendar ? "on" : "off")")
        var states: [(String, Permissions.State)] = [
            ("Microphone", permissions.microphone), ("System audio", permissions.systemAudio),
            ("Notifications", permissions.notifications), ("Calendar", permissions.calendar),
        ]
        #if !APP_STORE
        states.append(("Accessibility", permissions.accessibility))
        let checks = await MeetInspector.shared.lastChecks()
        #else
        let checks: [String] = []
        #endif
        let described = states.map { name, state in
            "\(name) " + (state == .granted ? "allowed" : state == .denied ? "not allowed" : state == .waiting ? "waiting" : "not allowed yet")
        }
        return ProblemReport.Context(version: Feedback.appVersion, system: Feedback.systemDescription,
                                     settings: settings, permissions: described, meetChecks: checks)
    }

    /// Shows the report dialog and does what the tester picks. `willShow` gets the
    /// dialog just before it opens (the `reportdialog` tool snapshots and closes it).
    static func present(call: CallReport?, context: ProblemReport.Context, willShow: ((NSAlert) -> Void)? = nil) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = call == nil ? "Report a problem" : "Report a problem with this call"
        alert.informativeText = """
        Say in a sentence what went wrong. Below is everything the report contains: what Wingman saw \
        and did, its settings and permissions. No meeting titles, links, names or what was said.
        """
        let sentence = NSTextField(string: "")
        sentence.placeholderString = "e.g. It kept recording after I left the call"
        sentence.translatesAutoresizingMaskIntoConstraints = false
        let preview = NSTextView()
        preview.isEditable = false
        preview.isSelectable = true
        preview.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        preview.string = ProblemReport.text(sentence: "", call: call, context: context)
            .components(separatedBy: "\n").dropFirst(2).joined(separator: "\n")
        preview.textContainerInset = NSSize(width: 4, height: 4)
        let scroll = NSScrollView()
        scroll.documentView = preview
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        preview.autoresizingMask = [.width]
        preview.isVerticallyResizable = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [sentence, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 460, height: 230)
        NSLayoutConstraint.activate([
            sentence.widthAnchor.constraint(equalToConstant: 460),
            scroll.widthAnchor.constraint(equalToConstant: 460),
            scroll.heightAnchor.constraint(equalToConstant: 196),
        ])
        alert.accessoryView = stack
        alert.addButton(withTitle: "Copy Report")
        alert.addButton(withTitle: "Open GitHub Form…")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = sentence
        willShow?(alert)

        let response = alert.runModal()
        let text = ProblemReport.text(sentence: sentence.stringValue, call: call, context: context)
        switch response {
        case .alertFirstButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            let done = NSAlert()
            done.messageText = "Report copied"
            done.informativeText = "Paste it wherever you send feedback about Wingman: a message, an email or the GitHub form."
            done.runModal()
            Log.write("problem report copied")
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(Feedback.problemURL(sentence: sentence.stringValue, report: text))
            Log.write("problem report opened in the GitHub form")
        default:
            break
        }
    }
}

extension Feedback {
    /// The problem form with the tester's sentence and the call report filled in.
    static func problemURL(sentence: String, report: String) -> URL {
        var components = URLComponents(url: url(.problem), resolvingAgainstBaseURL: false)!
        let what = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        // GitHub refuses very long addresses: keep the report's start, which has the call.
        let log = report.count > 5_000 ? String(report.prefix(5_000)) + "\n…" : report
        components.queryItems? += [
            URLQueryItem(name: "what", value: what),
            URLQueryItem(name: "log", value: "Report from Wingman:\n```\n\(log)\n```"),
        ]
        return components.url!
    }
}
