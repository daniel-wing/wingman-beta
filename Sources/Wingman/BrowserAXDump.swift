#if !APP_STORE
import AppKit
import ApplicationServices
import Foundation

/// `axdump` for browsers and their web apps (Chrome, the Google Meet app, …), to
/// measure what Google Meet support can rely on before it's built. It prints
/// window and tab titles, page addresses and button labels to the terminal (or
/// the file `open --stdout` sends it to) only — never to Wingman's log.
///
///     axdump chrome|edge|brave|arc|opera|meet   (or --bundle <id>, --pid <n>)
///       --windows [--no-web]    windows, tabs, address field and web areas, without
///                               going into pages (--no-web doesn't touch web areas at all)
///       --lazy                  web areas' child counts at 0, 1, 3 and 6 s, changing nothing
///       --match <text> [--first] [--depth N]   elements whose text contains <text>
///       --watch --match <text>  follow the first matching button, plus tab and window changes
///       --evidence              Google Meet call signals, printed when they change
///       --seconds N             how long --watch (90) and --evidence (60) run
///     Page access, with any of the above:
///       --web-ax (AXManualAccessibility) or --enhanced (AXEnhancedUserInterface),
///       --set-on target|chrome|<pid> (default target), --wait S (default 2).
///       Whatever the tool switches on is switched back off when it ends — normally,
///       on its time limit, on an error or on SIGINT/SIGTERM — unless --keep. It never
///       changes a value it couldn't read (unless --force-unreadable), and it leaves
///       the setting on if VoiceOver or Switch Control was turned on meanwhile.
///       --reset switches the attribute off now if it reads on (for experiments).
@MainActor
enum BrowserAXDump {
    static let browsers = ["chrome": "com.google.Chrome", "edge": "com.microsoft.edgemac", "brave": "com.brave.Browser",
                           "arc": "company.thebrowser.Browser", "opera": "com.operasoftware.Opera"]
    static let meetAppID = "kjgfgldnnfoeklkmfkjfagphfepbbdan"

    static let usage = """
        Usage: Wingman axdump chrome|edge|brave|arc|opera|meet [--bundle id] [--pid n]
                 [--windows [--no-web] | --lazy | --match text [--first] | --watch --match text | --evidence | --inspector]
                 [--seconds N] [--web-ax | --enhanced] [--set-on target|chrome|pid] [--wait S] [--keep] [--force-unreadable] [--reset]
        """

    static func handles(_ first: String) -> Bool {
        browsers[first.lowercased()] != nil || first.lowercased() == "meet" || first.hasPrefix("--")
    }

    struct Target {
        let label: String
        let pid: pid_t
        let bundleID: String
    }

    static func run(_ args: [String]) async -> Int32 {
        defer { PageAccessChange.restoreAll() }
        PageAccessChange.installSignalHandlers()
        print("Accessibility permission: \(AXIsProcessTrusted() ? "granted" : "NOT granted")")
        guard let target = resolve(args) else {
            print("No such app running.\n\(usage)")
            return 1
        }
        print("Target: \(target.label) — \(target.bundleID), pid \(target.pid)")
        if args.contains("--web-ax") || args.contains("--enhanced") {
            await switchOnPageAccess(args, target: target)
            if args.contains("--reset") { return 0 }
        }
        let seconds = value(after: "--seconds", in: args).flatMap(Double.init)
        if args.contains("--watch"), let text = value(after: "--match", in: args) {
            await watch(target, text: text.lowercased(), seconds: seconds ?? 90)
        } else if args.contains("--evidence") {
            await evidence(target, seconds: seconds ?? 60, noWeb: args.contains("--no-web"))
        } else if args.contains("--lazy") {
            await lazy(target)
        } else if let text = value(after: "--match", in: args) {
            let depth = value(after: "--depth", in: args).flatMap(Int.init) ?? 40
            match(target, text: text.lowercased(), first: args.contains("--first"), maxDepth: depth)
        } else if args.contains("--windows") {
            windows(target, noWeb: args.contains("--no-web"))
        } else if args.contains("--app") {
            appElement(target)
        } else if args.contains("--focus") {
            focus(target)
        } else if args.contains("--inspector") {
            await inspector(target, seconds: seconds ?? 0)
        } else {
            print(usage)
            return 2
        }
        return 0
    }

    // MARK: - Targets

    private static func resolve(_ args: [String]) -> Target? {
        if let pid = value(after: "--pid", in: args).flatMap({ pid_t($0) }) {
            let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "-"
            return Target(label: "pid \(pid)", pid: pid, bundleID: id)
        }
        if let id = value(after: "--bundle", in: args) {
            return running(id).map { Target(label: id, pid: $0.processIdentifier, bundleID: id) }
        }
        guard let name = args.first?.lowercased() else { return nil }
        if name == "meet", let app = meetApp() {
            return Target(label: "Google Meet app", pid: app.processIdentifier, bundleID: app.bundleIdentifier ?? "-")
        }
        if let id = browsers[name] {
            return running(id).map { Target(label: name, pid: $0.processIdentifier, bundleID: id) }
        }
        return nil
    }

    private static func running(_ bundleID: String) -> NSRunningApplication? {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        return apps.first { $0.activationPolicy == .regular } ?? apps.first
    }

    /// A running Chromium web app that opens meet.google.com (the Google Meet app).
    private static func meetApp() -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications.filter { shortcutHost($0) == "meet.google.com" }
        return apps.first { $0.bundleIdentifier?.hasSuffix("." + meetAppID) == true } ?? apps.first
    }

    private static func shortcutHost(_ app: NSRunningApplication) -> String? {
        guard let url = app.bundleURL,
              let shortcut = Bundle(url: url)?.object(forInfoDictionaryKey: "CrAppModeShortcutURL") as? String
        else { return nil }
        return URL(string: shortcut)?.host
    }

    /// The browser a web app belongs to ("com.google.Chrome.app.<id>" → Chrome).
    private static func browser(of target: Target) -> NSRunningApplication? {
        guard let range = target.bundleID.range(of: ".app.") else { return NSRunningApplication(processIdentifier: target.pid) }
        return running(String(target.bundleID[..<range.lowerBound]))
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    // MARK: - Page access

    private static func switchOnPageAccess(_ args: [String], target: Target) async {
        let attribute = args.contains("--enhanced") ? "AXEnhancedUserInterface" : "AXManualAccessibility"
        let setOn = value(after: "--set-on", in: args) ?? "target"
        let app: NSRunningApplication?
        switch setOn {
        case "target": app = NSRunningApplication(processIdentifier: target.pid)
        case "chrome", "browser": app = browser(of: target)
        default: app = pid_t(setOn).flatMap { NSRunningApplication(processIdentifier: $0) }
        }
        guard let app else {
            print("\(attribute): no app to set it on (--set-on \(setOn))")
            return
        }
        let change = PageAccessChange(pid: app.processIdentifier, attribute: attribute,
                                      label: "\(app.bundleIdentifier ?? "-") pid \(app.processIdentifier)",
                                      keep: args.contains("--keep"))
        if args.contains("--reset") {
            change.reset()
            return
        }
        change.switchOn(force: args.contains("--force-unreadable"))
        let wait = value(after: "--wait", in: args).flatMap(Double.init) ?? 2
        try? await Task.sleep(for: .seconds(wait))
    }

    // MARK: - Reading

    private static func application(_ target: Target) -> AXUIElement {
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, 1)
        return app
    }

    private static func read(_ element: AXUIElement, _ attribute: String) -> (value: CFTypeRef?, error: AXError) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return (error == .success ? value : nil, error)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        read(element, attribute).value as? String
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        (read(element, attribute).value as? NSNumber)?.boolValue
    }

    private static func childCount(_ element: AXUIElement) -> Int? {
        var count: CFIndex = 0
        return AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count) == .success ? count : nil
    }

    private static func url(_ element: AXUIElement) -> String? {
        let value = read(element, "AXURL").value
        return (value as? URL)?.absoluteString ?? value.map { "\($0)" }
    }

    /// The app's windows. Chrome has answered with an empty window list while its
    /// focused and main windows were readable, so those are added (once each).
    private static func windowsOf(_ target: Target) -> (windows: [AXUIElement], error: AXError) {
        let app = application(target)
        let result = read(app, kAXWindowsAttribute)
        var windows = (result.value as? [AXUIElement]) ?? []
        for attribute in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            guard let value = read(app, attribute).value, CFGetTypeID(value) == AXUIElementGetTypeID() else { continue }
            let window = value as! AXUIElement
            if !windows.contains(where: { CFEqual($0, window) }) { windows.append(window) }
        }
        let listed = (result.value as? [AXUIElement])?.count ?? 0
        if listed != windows.count { print("(window list had \(listed); added main/focused → \(windows.count))") }
        return (windows, windows.isEmpty ? result.error : .success)
    }

    private static func isTabLike(role: String, subrole: String?) -> Bool {
        role == kAXTabGroupRole || role == kAXRadioButtonRole || role == "AXTab" || (subrole?.contains("Tab") ?? false)
    }

    /// One line describing an element: role, subrole, texts, value, address.
    private static func describe(_ element: AXUIElement) -> String {
        var parts: [String] = [string(element, kAXRoleAttribute) ?? "?"]
        if let subrole = string(element, kAXSubroleAttribute) { parts.append("[\(subrole)]") }
        if let roleDescription = string(element, kAXRoleDescriptionAttribute) { parts.append("(\(roleDescription))") }
        for (key, attribute) in [("title", kAXTitleAttribute), ("desc", kAXDescriptionAttribute),
                                 ("help", kAXHelpAttribute), ("id", kAXIdentifierAttribute)] {
            if let text = string(element, attribute), !text.isEmpty { parts.append("\(key)=“\(text)”") }
        }
        if let value = read(element, kAXValueAttribute).value {
            let text = "\(value)".prefix(80)
            if !text.isEmpty { parts.append("value=\(text)") }
        }
        if let selected = bool(element, kAXSelectedAttribute) { parts.append("selected=\(selected)") }
        if let url = url(element) { parts.append("url=\(url)") }
        return parts.joined(separator: " ")
    }

    // MARK: - --app

    /// What the application element itself exposes: its attribute names, the
    /// window list, children, and the focused and main windows.
    private static func appElement(_ target: Target) {
        let app = application(target)
        var names: CFArray?
        let status = AXUIElementCopyAttributeNames(app, &names)
        print("attribute names (\(status == .success ? "ok" : "AXError \(status.rawValue)")): " +
              ((names as? [String]) ?? []).joined(separator: ", "))
        for attribute in [kAXRoleAttribute, kAXTitleAttribute, kAXFrontmostAttribute, kAXHiddenAttribute,
                          kAXWindowsAttribute, kAXChildrenAttribute, kAXFocusedWindowAttribute, kAXMainWindowAttribute,
                          "AXEnhancedUserInterface", "AXManualAccessibility"] {
            let (value, error) = read(app, attribute)
            let text: String
            if let list = value as? [AXUIElement] {
                text = "\(list.count) element(s)" + (list.isEmpty ? "" : ": " + list.prefix(5).map { describe($0) }.joined(separator: " | "))
            } else if let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                text = describe(value as! AXUIElement)
            } else {
                text = value.map { "\($0)" } ?? "—"
            }
            print("  \(attribute): \(error == .success ? text : "AXError \(error.rawValue)")")
        }
    }

    // MARK: - --inspector

    /// What Wingman's own Meet reader (`MeetInspector`, the code the app runs) sees
    /// in this browser: complete or partial, and each Meet call with its code and
    /// evidence. With --seconds, printed whenever it changes.
    private static func inspector(_ target: Target, seconds: Double) async {
        let family = CallApp.browserFamily(of: target.bundleID) ?? target.bundleID
        let end = Date().addingTimeInterval(seconds)
        var last = ""
        repeat {
            let scan = await MeetInspector.shared.scan(browserPID: target.pid, family: family)
            let text: String
            switch scan {
            case .unavailable: text = "unavailable"
            case .partial(let found): text = "partial: " + describe(found)
            case .complete(let found): text = "complete: " + describe(found)
            }
            report(&last, text)
            if seconds > 0 { try? await Task.sleep(for: .seconds(1)) }
        } while Date() < end
    }

    private static func describe(_ candidates: [MeetCandidate]) -> String {
        candidates.isEmpty ? "no Meet call" : candidates.map {
            "\($0.source == .app ? "Meet app" : "tab") \($0.code ?? "(no code)") \($0.evidence == .strong ? "strong" : "weak")"
        }.joined(separator: ", ")
    }

    // MARK: - --focus

    /// Asks for the focused element (the app's, then the whole system's) and its
    /// ancestors, as window managers and other assistive apps do — to see whether
    /// that makes Chrome expose page content.
    private static func focus(_ target: Target) {
        let app = application(target)
        for (label, source) in [("app", app), ("system", AXUIElementCreateSystemWide())] {
            let (value, error) = read(source, kAXFocusedUIElementAttribute)
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
                print("\(label) focused element: AXError \(error.rawValue)")
                continue
            }
            var element = value as! AXUIElement
            print("\(label) focused element: \(describe(element))")
            for _ in 0..<30 {
                guard let parent = read(element, kAXParentAttribute).value, CFGetTypeID(parent) == AXUIElementGetTypeID()
                else { break }
                element = parent as! AXUIElement
                let role = string(element, kAXRoleAttribute) ?? "?"
                print("  ↑ \(role)\(role == "AXWebArea" ? " url=\(url(element) ?? "-") children=\(childCount(element).map(String.init) ?? "?")" : "")")
            }
        }
    }

    // MARK: - --windows

    private static func windows(_ target: Target, noWeb: Bool) {
        let (windows, error) = windowsOf(target)
        guard error == .success else {
            print("Windows: unreadable (AXError \(error.rawValue))")
            return
        }
        print("\(windows.count) window(s)")
        for (index, window) in windows.enumerated() {
            print("Window \(index + 1): \(windowLine(window))")
            var visited = 0
            shallow(window, depth: 1, visited: &visited, noWeb: noWeb) { depth, line in
                print(String(repeating: "  ", count: depth) + line)
            }
            print("  (\(visited) nodes, pages not entered)")
        }
    }

    private static func windowLine(_ window: AXUIElement) -> String {
        var parts = ["“\(string(window, kAXTitleAttribute) ?? "")”"]
        if let subrole = string(window, kAXSubroleAttribute) { parts.append(subrole) }
        for (key, attribute) in [("main", kAXMainAttribute), ("focused", kAXFocusedAttribute),
                                 ("minimized", kAXMinimizedAttribute)] {
            if let flag = bool(window, attribute) { parts.append("\(key)=\(flag)") }
        }
        return parts.joined(separator: " ")
    }

    /// Walks the browser's own UI (tab strip, toolbar) without going into pages.
    private static func shallow(_ element: AXUIElement, depth: Int, visited: inout Int, noWeb: Bool,
                                report: (Int, String) -> Void) {
        guard depth <= 12, visited < 3_000 else { return }
        for child in (read(element, kAXChildrenAttribute).value as? [AXUIElement]) ?? [] {
            visited += 1
            let role = string(child, kAXRoleAttribute) ?? "?"
            let subrole = string(child, kAXSubroleAttribute)
            if role == "AXWebArea" {
                if noWeb {
                    report(depth, "AXWebArea (not read)")
                } else {
                    let count = childCount(child).map(String.init) ?? "?"
                    report(depth, "AXWebArea title=“\(string(child, kAXTitleAttribute) ?? "")” url=\(url(child) ?? "-") children=\(count)")
                }
                continue
            }
            if isTabLike(role: role, subrole: subrole) || role == kAXTextFieldRole || role == kAXComboBoxRole {
                report(depth, describe(child))
            }
            shallow(child, depth: depth + 1, visited: &visited, noWeb: noWeb, report: report)
        }
    }

    // MARK: - --lazy

    private static func lazy(_ target: Target) async {
        var areas: [AXUIElement] = []
        for window in windowsOf(target).windows { collectWebAreas(window, depth: 0, into: &areas) }
        print("\(areas.count) web area(s); child counts over time (nothing is set):")
        let start = Date()
        for moment in [0.0, 1, 3, 6] {
            let wait = moment - Date().timeIntervalSince(start)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            let counts = areas.map { childCount($0).map(String.init) ?? "?" }
            print("  t=\(Int(moment)) s: \(counts.joined(separator: ", "))")
        }
    }

    private static func collectWebAreas(_ element: AXUIElement, depth: Int, into areas: inout [AXUIElement]) {
        guard depth <= 12, areas.count < 50 else { return }
        for child in (read(element, kAXChildrenAttribute).value as? [AXUIElement]) ?? [] {
            if string(child, kAXRoleAttribute) == "AXWebArea" { areas.append(child) } else {
                collectWebAreas(child, depth: depth + 1, into: &areas)
            }
        }
    }

    // MARK: - --match

    private static func match(_ target: Target, text: String, first: Bool, maxDepth: Int) {
        let start = Date()
        var visited = 0, found = 0
        var firstAt: (visited: Int, ms: Int)?
        func walk(_ element: AXUIElement, depth: Int, path: [String]) -> Bool {
            visited += 1
            guard depth <= maxDepth, visited <= 30_000 else { return false }
            let line = describe(element)
            if line.lowercased().contains(text) {
                found += 1
                if firstAt == nil { firstAt = (visited, Int(Date().timeIntervalSince(start) * 1000)) }
                print("\(path.suffix(3).joined(separator: " › ")) › (depth \(depth))\n    \(line)")
                if first { return true }
            }
            let role = string(element, kAXRoleAttribute) ?? "?"
            for child in (read(element, kAXChildrenAttribute).value as? [AXUIElement]) ?? [] {
                if walk(child, depth: depth + 1, path: path + [role]) { return true }
            }
            return false
        }
        for window in windowsOf(target).windows {
            if walk(window, depth: 0, path: []) { break }
        }
        if let firstAt { print("— first match after \(firstAt.visited) nodes, \(firstAt.ms) ms") }
        print("— \(found) match(es), \(visited) nodes, \(Int(Date().timeIntervalSince(start) * 1000)) ms")
    }

    // MARK: - --watch

    private static func watch(_ target: Target, text: String, seconds: Double) async {
        print("Watching the first button containing “\(text)” for \(Int(seconds)) s — toggle it, switch tabs, minimize…")
        let end = Date().addingTimeInterval(seconds)
        var control: AXUIElement?
        var lastState = "", lastWindows = "", lastSearch = Date.distantPast
        while Date() < end {
            if let element = control {
                let name = read(element, kAXDescriptionAttribute)
                let title = string(element, kAXTitleAttribute)
                if name.error != .success && title == nil {
                    report(&lastState, "stale (AXError \(name.error.rawValue)), searching again")
                    control = nil
                } else {
                    let label = (name.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? title ?? ""
                    let value = read(element, kAXValueAttribute).value.map { " value=\($0)" } ?? ""
                    report(&lastState, "“\(label)”\(value)")
                }
            } else if Date().timeIntervalSince(lastSearch) >= 1 {
                lastSearch = Date()
                control = findButton(target, containing: text)
                if control == nil { report(&lastState, "not found") }
            }
            report(&lastWindows, "windows: " + windowSummary(target))
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private static func report(_ last: inout String, _ text: String) {
        guard text != last else { return }
        last = text
        print("\(timestamp())  \(text)")
    }

    private static func timestamp() -> String {
        Date().formatted(.dateTime.hour().minute().second().secondFraction(.fractional(2)))
    }

    private static func findButton(_ target: Target, containing text: String) -> AXUIElement? {
        for window in windowsOf(target).windows {
            var visited = 0
            if let found = AXTree.search(window, depth: 0, visited: &visited, maxDepth: 40, match: { element in
                guard let role = string(element, kAXRoleAttribute),
                      role == kAXButtonRole || role == kAXCheckBoxRole || role == "AXToggle",
                      let name = AXTree.name(element) else { return false }
                return name.lowercased().contains(text)
            }) { return found }
        }
        return nil
    }

    /// Each window's title, state and selected tab, to line up tab and window changes.
    private static func windowSummary(_ target: Target) -> String {
        let (windows, error) = windowsOf(target)
        guard error == .success else { return "unreadable (AXError \(error.rawValue))" }
        return windows.map { window in
            var selected = "-"
            forEachTab(window) { title, isSelected in if isSelected { selected = title } }
            return "[\(windowLine(window)) tab=“\(selected)”]"
        }.joined(separator: " ")
    }

    /// Calls `body` with each tab's title and whether it's the selected one.
    private static func forEachTab(_ window: AXUIElement, _ body: (String, Bool) -> Void) {
        var visited = 0
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth <= 12, visited < 3_000 else { return }
            for child in (read(element, kAXChildrenAttribute).value as? [AXUIElement]) ?? [] {
                visited += 1
                let role = string(child, kAXRoleAttribute) ?? "?"
                if role == "AXWebArea" { continue }
                if role == kAXRadioButtonRole || role == "AXTab" || (string(child, kAXSubroleAttribute)?.contains("Tab") ?? false) {
                    let title = AXTree.name(child) ?? ""
                    let selected = bool(child, kAXSelectedAttribute) ?? ((read(child, kAXValueAttribute).value as? NSNumber)?.intValue == 1)
                    body(title, selected)
                }
                walk(child, depth: depth + 1)
            }
        }
        walk(window, depth: 0)
    }

    // MARK: - --evidence

    private static let meetingCode = try! NSRegularExpression(pattern: #"\b[a-z]{3}-[a-z]{4}-[a-z]{3}\b"#)

    private static func hasMeetingCode(_ text: String) -> Bool {
        meetingCode.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Prints, when they change, the signals a Meet call could be recognized by:
    /// for each window and tab that looks like Meet — whether it has a meeting
    /// code, is selected or minimized, what its title says (Chrome may add a
    /// recording note), and whether an in-call control is visible (only when the
    /// page is already readable). Each is active, ended or unknown (with why).
    private static func evidence(_ target: Target, seconds: Double, noWeb: Bool) async {
        print("Recording Meet signals for \(Int(seconds)) s, printed when they change.")
        let end = Date().addingTimeInterval(seconds)
        var last = ""
        while Date() < end {
            report(&last, "\n" + evidenceSnapshot(target, noWeb: noWeb))
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private static func evidenceSnapshot(_ target: Target, noWeb: Bool) -> String {
        guard AXIsProcessTrusted() else { return "  meet: unknown — no Accessibility permission" }
        let (windows, error) = windowsOf(target)
        guard error == .success else { return "  meet: unknown — windows unreadable (AXError \(error.rawValue))" }
        var lines: [String] = []
        for (index, window) in windows.enumerated() {
            let title = string(window, kAXTitleAttribute) ?? ""
            let minimized = bool(window, kAXMinimizedAttribute).map(String.init) ?? "?"
            var tabs: [(String, Bool)] = []
            forEachTab(window) { tabs.append(($0, $1)) }
            var areas: [AXUIElement] = []
            if !noWeb { collectWebAreas(window, depth: 0, into: &areas) }
            let meetAreas = areas.filter { (url($0) ?? "").contains("meet.google.com") }
            let inCall: String
            if noWeb {
                inCall = "unknown (pages not read)"
            } else if meetAreas.isEmpty {
                inCall = areas.isEmpty ? "unknown (no page readable)" : "unknown (no Meet page readable)"
            } else if meetAreas.allSatisfy({ (childCount($0) ?? 0) == 0 }) {
                inCall = "unknown (page access off or page hidden)"
            } else {
                inCall = meetAreas.contains(where: { hasInCallControl($0) }) ? "present" : "absent"
            }
            let windowLooksMeet = title.contains("Meet") || hasMeetingCode(title)
            let meetTabs = tabs.filter { $0.0.contains("Meet") || hasMeetingCode($0.0) }
            guard windowLooksMeet || !meetTabs.isEmpty || !meetAreas.isEmpty else { continue }
            lines.append("  window \(index + 1) “\(title)” minimized=\(minimized) code=\(hasMeetingCode(title)) inCall=\(inCall)")
            for (tab, selected) in meetTabs {
                lines.append("    tab “\(tab)” selected=\(selected) code=\(hasMeetingCode(tab))")
            }
            for area in meetAreas {
                lines.append("    page url=\(url(area) ?? "-") children=\(childCount(area).map(String.init) ?? "?")")
            }
        }
        if lines.isEmpty { return "  meet: ended — windows readable, no Meet window, tab or page" }
        return "  meet: active\n" + lines.joined(separator: "\n")
    }

    private static func hasInCallControl(_ area: AXUIElement) -> Bool {
        var visited = 0
        return AXTree.search(area, depth: 0, visited: &visited, maxDepth: 40) { element in
            guard string(element, kAXRoleAttribute) == kAXButtonRole, let name = AXTree.name(element)?.lowercased()
            else { return false }
            return ["leave call", "salir de la llamada", "sair da chamada"].contains { name.hasPrefix($0) }
        } != nil
    }
}

/// The two decisions behind every page-access change the tools make, kept pure
/// so they can be tested.
enum PageAccess {
    enum Original: Equatable { case on, off, unreadable }

    /// Switch it on only from a value read as off; an unreadable value only when
    /// explicitly forced (being unable to read it says nothing about its state).
    static func shouldSwitchOn(_ original: Original, force: Bool) -> Bool {
        switch original {
        case .off: return true
        case .on: return false
        case .unreadable: return force
        }
    }

    /// Switch it back off only if this run turned it on from a known off, nobody
    /// asked to keep it, and no assistive app (VoiceOver, Switch Control) started
    /// meanwhile — that new need comes before the original baseline.
    static func shouldRestore(original: Original, changed: Bool, keep: Bool, assistiveStarted: Bool) -> Bool {
        changed && original == .off && !keep && !assistiveStarted
    }
}

/// One page-access attribute the tool switched on, and how to put it back.
@MainActor
final class PageAccessChange {
    private static var active: [PageAccessChange] = []
    private static var signalSources: [DispatchSourceSignal] = []

    let pid: pid_t
    let attribute: String
    let label: String
    let keep: Bool
    private(set) var original: PageAccess.Original = .unreadable
    private(set) var changed = false
    private let assistiveAtStart = PageAccessChange.assistiveRunning()

    init(pid: pid_t, attribute: String, label: String, keep: Bool) {
        self.pid = pid
        self.attribute = attribute
        self.label = label
        self.keep = keep
    }

    private var element: AXUIElement { AXUIElementCreateApplication(pid) }

    func switchOn(force: Bool) {
        original = read()
        print("\(attribute) on \(label): before = \(original)")
        guard PageAccess.shouldSwitchOn(original, force: force) else {
            print("  not changed (\(original == .on ? "already on" : "couldn't read it — use --force-unreadable to set it anyway"))")
            return
        }
        let status = AXUIElementSetAttributeValue(element, attribute as CFString, kCFBooleanTrue)
        let after = read()
        // Chrome has answered "not implemented" (-25208) and switched it on anyway:
        // what it reads back counts, not the error code.
        changed = status == .success || (original == .off && after == .on)
        print("  set → \(status == .success ? "ok" : "AXError \(status.rawValue)"); read back = \(after)"
              + (changed && status != .success ? " (counted as changed)" : ""))
        if changed { Self.active.append(self) }
    }

    /// For experiments: switch it off now if it reads on, whoever switched it on.
    func reset() {
        let before = read()
        guard before != .off else {
            print("\(attribute) on \(label): \(before), nothing to reset")
            return
        }
        let status = AXUIElementSetAttributeValue(element, attribute as CFString, kCFBooleanFalse)
        print("\(attribute) on \(label): reset from \(before) → \(status == .success ? "ok" : "AXError \(status.rawValue)"); read back = \(read())")
    }

    func restore() {
        let assistiveStarted = Self.assistiveRunning() && !assistiveAtStart
        guard PageAccess.shouldRestore(original: original, changed: changed, keep: keep, assistiveStarted: assistiveStarted)
        else {
            if changed {
                let why = keep ? "--keep" : assistiveStarted ? "VoiceOver or Switch Control started meanwhile"
                    : "its original value was unknown — relaunch the browser to reset it"
                print("\(attribute) on \(label): left on (\(why))")
            }
            return
        }
        let status = AXUIElementSetAttributeValue(element, attribute as CFString, kCFBooleanFalse)
        print("\(attribute) on \(label): restored → \(status == .success ? "off" : "AXError \(status.rawValue)"); read back = \(read())")
        changed = false
    }

    private func read() -> PageAccess.Original {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let flag = value as? NSNumber else { return .unreadable }
        return flag.boolValue ? .on : .off
    }

    private static func assistiveRunning() -> Bool {
        NSWorkspace.shared.isVoiceOverEnabled || NSWorkspace.shared.isSwitchControlEnabled
    }

    static func restoreAll() {
        for change in active { change.restore() }
        active = []
    }

    /// SIGINT, SIGTERM and SIGHUP restore before exiting.
    static func installSignalHandlers() {
        guard signalSources.isEmpty else { return }
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { restoreAll() }
                exit(128 + number)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
#endif
