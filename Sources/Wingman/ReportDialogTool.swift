#if !NO_DIAGNOSTICS && !APP_STORE
import AppKit
import Foundation

/// `reportdialog [--png file] [--seconds N]`: opens "Report a problem with this
/// call" with a made-up Google Meet call, to check how it looks. With --png it saves
/// a picture of the dialog and closes it after N seconds (default 2), choosing
/// nothing, so the clipboard and browser aren't touched.
enum ReportDialog {
    @MainActor static func run(_ args: [String]) async -> Int32 {
        let png = args.firstIndex(of: "--png").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        let seconds = args.firstIndex(of: "--seconds").flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil } ?? 2
        NSApplication.shared.setActivationPolicy(.accessory)
        let start = Date().addingTimeInterval(-185)
        var call = CallReport(id: UUID(), app: .meet, started: start)
        call.add("Seen: " + CallWatcher.seen(CallSession(id: call.id, app: .meet, evidence: .strong, meetingCode: nil, browser: nil)), at: start)
        call.add("Recording automatically: Google Meet is set to Record automatically", at: start.addingTimeInterval(1))
        call.add("Recording started", at: start.addingTimeInterval(1))
        call.add("No calendar event found, so the note is named by time", at: start.addingTimeInterval(1))
        call.add("Call ended", at: start.addingTimeInterval(180))
        call.add("Note saved", at: start.addingTimeInterval(185))
        call.ended = start.addingTimeInterval(180)
        call.outcome = .recorded
        let context = ProblemReport.Context(
            version: Feedback.appVersion, system: Feedback.systemDescription,
            settings: CallApp.shown.map { "\($0.name): Ask me first" } + ["Follow my mute: on", "Name meetings from my calendar: on"],
            permissions: ["Microphone allowed", "System audio allowed", "Notifications allowed", "Calendar allowed", "Accessibility allowed"],
            meetChecks: ["com.google.Chrome: Meet tab strong; browser in en"])
        ProblemReporter.present(call: call, context: context) { alert in
            guard let png else { return }
            let timer = Timer(timeInterval: seconds, repeats: false) { _ in
                MainActor.assumeIsolated {
                    if let view = alert.window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: png))
                        print("saved \(png)")
                    }
                    NSApp.abortModal()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
        print(ProblemReport.text(sentence: "(the tester's sentence)", call: call, context: context))
        return 0
    }
}
#endif
