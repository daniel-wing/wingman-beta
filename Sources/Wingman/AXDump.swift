#if !APP_STORE
import ApplicationServices
import Foundation

/// `Wingman axdump teams|zoom [--match text] [--depth N] [--web-ax] [--watch]`
/// prints the app's accessibility tree (or only nodes matching `text`), to find
/// the real labels of its mute control. `--watch` runs the same reader the app
/// uses and prints each mute change for a minute. Read-only, except `--web-ax`,
/// which asks a web-based UI to build its accessibility tree. Browsers and the
/// Google Meet app (`axdump chrome|meet …`) are measured by `BrowserAXDump`.
///
/// Run it through the app bundle so the Accessibility permission is Wingman's:
///   open -n -W --stdout /dev/stdout /Applications/Wingman.app --args axdump teams --match mute
enum AXDump {
    static func run(_ args: [String]) async -> Int32 {
        if let first = args.first, await BrowserAXDump.handles(first) {
            return await BrowserAXDump.run(args)
        }
        guard let which = args.first, let app = ["teams": CallApp.teams, "zoom": .zoom][which.lowercased()] else {
            print("Usage: Wingman axdump teams|zoom [--match text] [--depth N] [--web-ax] [--watch]\n\(await BrowserAXDump.usage)")
            return 2
        }
        print("Accessibility permission: \(AXIsProcessTrusted() ? "granted" : "NOT granted")")
        guard let pid = AXTree.pid(for: app) else {
            print("\(app.name) isn't running.")
            return 1
        }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 1)
        if args.contains("--web-ax") {
            let status = AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            print("AXManualAccessibility → \(status == .success ? "set" : "error \(status.rawValue)")")
            try? await Task.sleep(for: .seconds(1))
        }

        // `--windows [seconds]`: every second, each window's kind, frame and
        // title, whether it holds the mute control, and any timer-like text
        // ("01:27") in it; printed when anything changes. For telling a screen
        // share or a compact view from a new call.
        if let i = args.firstIndex(of: "--windows") {
            let seconds = (i + 1 < args.count ? Double(args[i + 1]) : nil) ?? 120
            let end = Date().addingTimeInterval(seconds)
            var last = ""
            print("Watching \(app.name)'s windows for \(Int(seconds)) s.")
            while Date() < end {
                let summary = windowSummary(application, app: app)
                if summary != last {
                    print("— \(Date().formatted(date: .omitted, time: .standard))\n\(summary)")
                    last = summary
                }
                try? await Task.sleep(for: .seconds(1))
            }
            return 0
        }

        if args.contains("--watch") {
            let probe = AXProbe()
            var last = ""
            let end = Date().addingTimeInterval(60)
            print("Watching \(app.name)'s mute for 60 s — toggle it now.")
            while Date() < end {
                let reading = await probe.read(app)
                let text: String
                switch reading {
                case .state(let muted): text = muted ? "MUTED" : "unmuted"
                case .unknownLabel(let label): text = "unrecognized label “\(label)”"
                case .notFound: text = "mute control not found"
                case .noPermission: text = "no Accessibility permission"
                case .notRunning: text = "app not running"
                }
                if text != last {
                    print("\(Date().formatted(date: .omitted, time: .standard))  \(text)")
                    last = text
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            return 0
        }

        let match = args.firstIndex(of: "--match").flatMap { $0 + 1 < args.count ? args[$0 + 1].lowercased() : nil }
        let maxDepth = args.firstIndex(of: "--depth").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 25
        var roots: [AXUIElement] = (AXTree.value(application, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        if let menuBar = AXTree.value(application, kAXMenuBarAttribute) { roots.append(menuBar as! AXUIElement) }
        print("\(app.name): \(roots.count) root(s) (windows + menu bar)")
        var printed = 0, visited = 0
        for root in roots {
            dump(root, depth: 0, path: [], maxDepth: maxDepth, match: match, printed: &printed, visited: &visited)
        }
        print("— \(visited) nodes visited, \(printed) printed")
        return 0
    }

    private static func windowSummary(_ application: AXUIElement, app: CallApp) -> String {
        let windows = (AXTree.value(application, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        let mute = AXTree.findMuteControl(in: application, for: app)
        let muteWindow = mute.flatMap { AXTree.value($0, kAXWindowAttribute) }.map { $0 as! AXUIElement }
        let main = AXTree.value(application, kAXMainWindowAttribute).map { $0 as! AXUIElement }
        var lines: [String] = []
        for (n, window) in windows.enumerated() {
            var frame = ""
            if let p = AXTree.value(window, kAXPositionAttribute), let s = AXTree.value(window, kAXSizeAttribute) {
                var point = CGPoint.zero, size = CGSize.zero
                AXValueGetValue(p as! AXValue, .cgPoint, &point)
                AXValueGetValue(s as! AXValue, .cgSize, &size)
                frame = "\(Int(point.x)),\(Int(point.y)) \(Int(size.width))×\(Int(size.height))"
            }
            let subrole = AXTree.string(window, kAXSubroleAttribute) ?? "-"
            let title = AXTree.string(window, kAXTitleAttribute) ?? ""
            let minimized = (AXTree.value(window, kAXMinimizedAttribute) as? Bool) == true ? " minimized" : ""
            let isMute = muteWindow.map { CFEqual($0, window) } == true ? " [MUTE]" : ""
            let isMain = main.map { CFEqual($0, window) } == true ? " [main]" : ""
            let timers = timerTexts(in: window)
            lines.append("  #\(n) \(subrole) \(frame)\(minimized)\(isMute)\(isMain) “\(title)”"
                         + (timers.isEmpty ? "" : " timers: \(timers.joined(separator: ", "))"))
        }
        if let mute, case .success(let label) = AXTree.label(mute, for: app) { lines.append("  mute label: “\(label)”") }
        return lines.joined(separator: "\n")
    }

    /// Text like "01:27" or "1:02:03" anywhere in a window (a call timer).
    private static func timerTexts(in window: AXUIElement) -> [String] {
        var found: [String] = []
        var queue = [window], visited = 0
        let pattern = try! Regex("^[0-9]{1,2}:[0-9]{2}(:[0-9]{2})?$")
        while !queue.isEmpty, visited < 5000 {
            let node = queue.removeFirst()
            visited += 1
            for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                if let text = AXTree.string(node, attribute)?.trimmingCharacters(in: .whitespaces),
                   text.wholeMatch(of: pattern) != nil { found.append(text) }
            }
            queue += (AXTree.value(node, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        }
        return found
    }

    private static func describe(_ element: AXUIElement) -> String {
        var parts: [String] = [AXTree.string(element, kAXRoleAttribute) ?? "?"]
        if let subrole = AXTree.string(element, kAXSubroleAttribute) { parts.append("[\(subrole)]") }
        for (key, attribute) in [("title", kAXTitleAttribute), ("desc", kAXDescriptionAttribute),
                                 ("help", kAXHelpAttribute), ("id", kAXIdentifierAttribute)] {
            if let text = AXTree.string(element, attribute), !text.isEmpty { parts.append("\(key)=“\(text)”") }
        }
        if let value = AXTree.value(element, kAXValueAttribute) {
            let text = "\(value)".prefix(60)
            if !text.isEmpty { parts.append("value=\(text)") }
        }
        if let char = AXTree.string(element, kAXMenuItemCmdCharAttribute) {
            let mods = AXTree.value(element, kAXMenuItemCmdModifiersAttribute) as? Int ?? -1
            parts.append("shortcut=\(char) mods=\(mods)")
        }
        return parts.joined(separator: " ")
    }

    private static func dump(_ element: AXUIElement, depth: Int, path: [String], maxDepth: Int, match: String?,
                             printed: inout Int, visited: inout Int) {
        visited += 1
        guard depth <= maxDepth, visited <= 20_000 else { return }
        let line = describe(element)
        if let match {
            if line.lowercased().contains(match) {
                print("\(path.suffix(3).joined(separator: " › ")) ›\n    \(line)")
                printed += 1
            }
        } else {
            print(String(repeating: "  ", count: depth) + line)
            printed += 1
        }
        let role = AXTree.string(element, kAXRoleAttribute) ?? "?"
        for child in AXTree.children(element) {
            dump(child, depth: depth + 1, path: path + [role], maxDepth: maxDepth, match: match,
                 printed: &printed, visited: &visited)
        }
    }
}
#endif
