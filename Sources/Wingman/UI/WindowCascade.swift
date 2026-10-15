import AppKit
import SwiftUI

extension View {
    /// Opens the window offset from any of Wingman's windows it would exactly
    /// cover. SwiftUI places a new window of a group relative to the main
    /// window, so two calls opened back to back (Wingman in the background)
    /// land on the same spot and look like one window.
    func cascadesOverOtherWindows() -> some View {
        background(CascadeAnchor())
    }
}

private struct CascadeAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Anchor() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Anchor: NSView {
        private var placed = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !placed, let window else { return }
            placed = true
            // After SwiftUI has given the window its own position.
            DispatchQueue.main.async { Self.moveClear(window) }
        }

        static func moveClear(_ window: NSWindow) {
            let others = NSApp.windows.filter {
                $0 !== window && $0.isVisible && $0.styleMask.contains(.titled)
            }
            func covers(_ origin: NSPoint) -> Bool {
                others.contains { abs($0.frame.minX - origin.x) < 4 && abs($0.frame.maxY - (origin.y + window.frame.height)) < 4 }
            }
            let step: CGFloat = 26
            var origin = window.frame.origin
            var tries = 0
            while covers(origin), tries < 20 {
                origin.x += step
                origin.y -= step
                tries += 1
            }
            guard tries > 0 else { return }
            // Back to the top left of the screen when it would run off it.
            if let visible = (window.screen ?? NSScreen.main)?.visibleFrame,
               origin.x + window.frame.width > visible.maxX || origin.y < visible.minY {
                origin = NSPoint(x: visible.minX + step, y: visible.maxY - window.frame.height - step)
            }
            window.setFrameOrigin(origin)
        }
    }
}

/// What a meeting window shows once its meeting is gone (deleted or
/// discarded): restoration is off, so this only happens while the window is
/// open, and it closes itself. (Through AppKit: SwiftUI's dismiss goes to the
/// confirmation sheet that's still closing.)
struct ClosedMeetingWindow: View {
    var body: some View {
        ContentUnavailableView("This Meeting Is Closed", systemImage: "doc.text",
                               description: Text("Find it in Meetings, or in your notes folder."))
            .background(Closer())
    }

    private struct Closer: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { Anchor() }
        func updateNSView(_ nsView: NSView, context: Context) {}

        final class Anchor: NSView {
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                guard let window else { return }
                Self.close(window, tries: 20)
            }

            static func close(_ window: NSWindow, tries: Int) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if window.attachedSheet != nil, tries > 0 {
                        close(window, tries: tries - 1)
                    } else {
                        window.close()
                    }
                }
            }
        }
    }
}
