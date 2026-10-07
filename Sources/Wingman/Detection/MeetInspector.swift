#if !APP_STORE
import AppKit
import ApplicationServices
import Foundation

/// Recognizes Google Meet calls in a Chromium browser by reading what the browser
/// itself shows — its tab strip, each window's address bar, and the Meet app's
/// title-bar capture indicator — never the pages. Read-only: it sets nothing in the browser, so Chrome's accessibility modes
/// stay as they are (measured). Errors come back with each read; it never touches
/// `AXTree.lastError`, so it can't disturb the Teams/Zoom mute probe. Titles and
/// addresses stay in memory; nothing is logged.
actor MeetInspector {
    static let shared = MeetInspector()

    private static let perElementTimeout: Float = 0.25
    private static let timeBudget: TimeInterval = 0.6
    private static let maxDepth = 12
    private static let maxNodes = 3_000

    /// The last "Meet check" logged per browser, so the log gets a line only when
    /// what Wingman sees changes, not on every poll.
    private var logged: [pid_t: String] = [:]

    /// What one browser's windows show right now. Partial whenever anything couldn't
    /// be read in full, so that missing meetings never count as ended.
    func scan(browserPID: pid_t, family: String) -> BrowserScan {
        guard AXIsProcessTrusted() else {
            log("Accessibility is off, so Meet calls count as browser calls", browser: browserPID, family: family)
            return .unavailable
        }
        var reading = Reading(deadline: Date().addingTimeInterval(Self.timeBudget))
        guard let windows = Self.windows(of: browserPID, reading: &reading) else {
            log("Accessibility is off, so Meet calls count as browser calls", browser: browserPID, family: family)
            return .unavailable
        }
        let scans = windows.map { Self.scanWindow($0, reading: &reading) }
        let languages = Self.languages(of: family)
        let notesReadable = MeetDetection.notesReadable(preferredLanguages: languages)
        var indicator: MeetAppIndicator?
        for app in Self.meetApps(of: family) {
            let found = Self.captureIndicator(of: app.processIdentifier, notesReadable: notesReadable, reading: &reading)
            if indicator != .capturing { indicator = found == .idle && indicator == .unknown ? .unknown : found }
        }
        let candidates = MeetDetection.candidates(in: scans, meetApp: indicator, notesReadable: notesReadable)
        // The language only, never the region.
        let language = languages.first.map { String($0.prefix { $0 != "-" && $0 != "_" }) } ?? "unknown"
        log("\(MeetDetection.summary(candidates)); browser in \(language)"
                + (notesReadable ? "" : " (not measured yet, so Meet is asked about, never recorded on its own)"),
            browser: browserPID, family: family, detail: reading.complete ? nil : "tabs read in part")
        return reading.complete ? .complete(candidates) : .partial(candidates)
    }

    /// What each browser showed last (categories only), for a problem report.
    func lastChecks() -> [String] {
        logged.values.sorted()
    }

    /// Logs what this browser shows when it changes (categories only). A detail like
    /// a partial read is added to a line but doesn't make one by itself.
    private func log(_ text: String, browser pid: pid_t, family: String, detail: String? = nil) {
        let line = "\(family): \(text)"
        guard logged[pid] != line else { return }
        logged[pid] = line
        Log.write("Meet check: \(line)\(detail.map { "; \($0)" } ?? "")")
    }

    /// Tracks one scan's time budget and whether everything was read in full.
    struct Reading {
        let deadline: Date
        var complete = true
        var nodes = 0

        mutating func visit() -> Bool {
            nodes += 1
            if nodes > MeetInspector.maxNodes || Date() > deadline {
                complete = false
                return false
            }
            return true
        }
    }

    // MARK: - Reading the browser

    private static func read(_ element: AXUIElement, _ attribute: String) -> (value: CFTypeRef?, error: AXError) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return (error == .success ? value : nil, error)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        read(element, attribute).value as? String
    }

    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// The app's windows: its window list plus the main and focused windows (Chrome
    /// has listed none while in the background, with those two still readable — then
    /// the list is partial). Nil if Accessibility is off.
    static func windows(of pid: pid_t, reading: inout Reading) -> [AXUIElement]? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, perElementTimeout)
        let (list, error) = read(app, kAXWindowsAttribute)
        if error == .apiDisabled { return nil }
        var windows = (list as? [AXUIElement]) ?? []
        if error != .success || windows.isEmpty { reading.complete = false }
        for attribute in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            guard let window = element(read(app, attribute).value), !windows.contains(where: { CFEqual($0, window) })
            else { continue }
            windows.append(window)
            reading.complete = false
        }
        // Tooltips, bubbles and the like: untitled windows of an unknown kind.
        return windows.filter { string($0, kAXSubroleAttribute) != "AXUnknown" }
    }

    /// One window's tabs (title, selected) and its address bar, without entering pages.
    private static func scanWindow(_ window: AXUIElement, reading: inout Reading) -> BrowserWindowScan {
        var scan = BrowserWindowScan(tabs: [], address: nil)
        var fallbackAddress: String?
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth <= maxDepth else { reading.complete = false; return }
            let (children, error) = read(element, kAXChildrenAttribute)
            if error != .success && error != .noValue && error != .attributeUnsupported { reading.complete = false }
            for child in (children as? [AXUIElement]) ?? [] {
                guard reading.visit() else { return }
                let role = string(child, kAXRoleAttribute)
                if role == "AXWebArea" { continue }
                if role == kAXRadioButtonRole, string(child, kAXSubroleAttribute) == "AXTabButton" {
                    let title = string(child, kAXTitleAttribute) ?? string(child, kAXDescriptionAttribute) ?? ""
                    let value = (read(child, kAXValueAttribute).value as? NSNumber)?.intValue
                    let selected = (read(child, kAXSelectedAttribute).value as? NSNumber)?.boolValue
                    scan.tabs.append(BrowserTab(title: title, isSelected: value == 1 || selected == true))
                    continue
                }
                if role == kAXTextFieldRole, let value = string(child, kAXValueAttribute) {
                    let label = [string(child, kAXTitleAttribute), string(child, kAXDescriptionAttribute)]
                        .compactMap { $0?.lowercased() }.joined(separator: " ")
                    if label.contains("address") { scan.address = scan.address ?? value }
                    else { fallbackAddress = fallbackAddress ?? value }
                }
                walk(child, depth: depth + 1)
            }
        }
        walk(window, depth: 0)
        scan.address = scan.address ?? fallbackAddress
        return scan
    }

    // MARK: - The Meet app

    private static func meetApps(of family: String) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in
            guard let id = app.bundleIdentifier, id.hasPrefix(family + ".app.") else { return false }
            let shortcut = app.bundleURL.flatMap { Bundle(url: $0) }?.object(forInfoDictionaryKey: "CrAppModeShortcutURL") as? String
            return MeetDetection.isMeetApp(bundleID: id, shortcutURL: shortcut)
        }
    }

    /// The Meet app's title-bar button "This page is accessing your microphone."
    /// (read from the app's own process, with no page access — measured). Not finding
    /// it means idle only when everything was read and the label's language is known.
    private static func captureIndicator(of pid: pid_t, notesReadable: Bool, reading: inout Reading) -> MeetAppIndicator {
        var appReading = Reading(deadline: reading.deadline)
        guard let windows = windows(of: pid, reading: &appReading) else { return .unknown }
        var found = false
        func walk(_ element: AXUIElement, depth: Int) {
            guard !found, depth <= maxDepth else { if depth > maxDepth { appReading.complete = false }; return }
            for child in (read(element, kAXChildrenAttribute).value as? [AXUIElement]) ?? [] {
                guard !found, appReading.visit() else { return }
                let role = string(child, kAXRoleAttribute)
                if role == "AXWebArea" { continue }
                if role == kAXButtonRole {
                    let label = string(child, kAXTitleAttribute) ?? string(child, kAXDescriptionAttribute) ?? ""
                    if MeetDetection.isCaptureIndicator(label) { found = true; return }
                }
                walk(child, depth: depth + 1)
            }
        }
        for window in windows { walk(window, depth: 0) }
        if found { return .capturing }
        if !appReading.complete { reading.complete = false }
        return appReading.complete && notesReadable ? .idle : .unknown
    }

    /// The browser's UI languages: its own setting, else the Mac's.
    private static func languages(of family: String) -> [String] {
        UserDefaults(suiteName: family)?.stringArray(forKey: "AppleLanguages") ?? Locale.preferredLanguages
    }
}
#endif
