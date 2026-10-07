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
