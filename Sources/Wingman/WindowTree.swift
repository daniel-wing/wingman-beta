import AppKit
import ApplicationServices

/// `Wingman windowtree <pid> [--depth N]`: every element of an app's windows with its
/// role, text and frame — for checking Wingman's own layout without a screenshot.
/// Prints to the terminal only.
enum WindowTree {
    static func run(_ args: [String]) async -> Int32 {
        guard let pid = args.first.flatMap({ pid_t($0) }) else {
            print("Usage: Wingman windowtree <pid> [--depth N]")
            return 2
        }
        let depth = args.firstIndex(of: "--depth").flatMap { Int(args[safe: $0 + 1] ?? "") } ?? 25
        let app = AXUIElementCreateApplication(pid)
        var windows: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
        for window in (windows as? [AXUIElement]) ?? [] { dump(window, level: 0, max: depth) }
        return 0
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return nil }
        if let s = value as? String { return s.isEmpty ? nil : String(s.prefix(60)) }
        if CFGetTypeID(value) == AXValueGetTypeID() {
            let v = value as! AXValue
            var point = CGPoint.zero, size = CGSize.zero
            if AXValueGetValue(v, .cgPoint, &point) { return "\(Int(point.x)),\(Int(point.y))" }
            if AXValueGetValue(v, .cgSize, &size) { return "\(Int(size.width))x\(Int(size.height))" }
        }
        return nil
    }

    private static func dump(_ element: AXUIElement, level: Int, max: Int) {
        let role = string(element, kAXRoleAttribute) ?? "?"
        let text = [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute].compactMap { string(element, $0) }.joined(separator: " | ")
        let frame = "@\(string(element, kAXPositionAttribute) ?? "-") \(string(element, kAXSizeAttribute) ?? "-")"
        print(String(repeating: "  ", count: level) + "\(role) \(frame) \(text)")
        guard level < max else { return }
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        for child in (children as? [AXUIElement]) ?? [] { dump(child, level: level + 1, max: max) }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
