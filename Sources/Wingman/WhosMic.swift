#if !NO_DIAGNOSTICS && !APP_STORE
import AppKit
import Foundation

/// `Wingman whosmic [--watch [seconds]]` lists the processes using the
/// microphone as call detection sees them, with their pid, parent app and (for
/// Chromium helpers) process role, plus any running browser web apps (Chrome
/// "app shims", e.g. the Google Meet app) and the site they open. `--watch`
/// prints a timestamped snapshot whenever it changes (default 60 s), to time
/// when a call takes and releases the mic.
enum WhosMic {
    static func run(_ args: [String]) async -> Int32 {
        guard let index = args.firstIndex(of: "--watch") else {
            print(snapshot().joined(separator: "\n"))
            return 0
        }
        let seconds = args.dropFirst(index + 1).first.flatMap(Double.init) ?? 60
        let end = Date().addingTimeInterval(seconds)
        print("Watching for \(Int(seconds)) s…")
        var last: [String] = []
        while Date() < end {
            let now = snapshot()
            if now != last {
                print("— \(Date().formatted(.dateTime.hour().minute().second().secondFraction(.fractional(1))))")
                print(now.map { "  " + $0 }.joined(separator: "\n"))
                last = now
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return 0
    }

    private static func snapshot() -> [String] {
        let processes = CallDetector.microphoneProcesses()
        var lines = processes.isEmpty ? ["No app is using the microphone."] : processes.map(describe)
        let shims = browserWebApps()
        if !shims.isEmpty { lines.append("Browser web apps running:") }
        lines += shims.map { "  \($0)" }
        return lines
    }

    private static func describe(_ process: CallDetector.AudioProcess) -> String {
        var line = "\(process.bundleID)  pid \(process.pid)"
        if let parent = ProcessTree.parentPID(of: process.pid) {
            let app = NSRunningApplication(processIdentifier: parent)?.bundleIdentifier ?? "-"
            line += "  parent \(parent) \(app)"
        }
        if let role = ProcessTree.chromiumRole(of: process.pid) { line += "  [\(role)]" }
        if let app = CallApp.matching(bundleID: process.bundleID) { line += "  → \(app.name)" }
        return line
    }

    /// Running Chromium web apps ("app shims"), recognized by the
    /// `CrAppModeShortcutURL` in their Info.plist; only the site's host is shown.
    private static func browserWebApps() -> [String] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let url = app.bundleURL, let bundle = Bundle(url: url),
                  let shortcut = bundle.object(forInfoDictionaryKey: "CrAppModeShortcutURL") as? String
            else { return nil }
            let host = URL(string: shortcut)?.host ?? "?"
            return "\(app.bundleIdentifier ?? "-")  pid \(app.processIdentifier)  opens \(host)"
        }
    }
}
#endif
