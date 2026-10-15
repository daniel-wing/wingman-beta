import AppKit
import CoreGraphics

/// Development only: `open -a Wingman --args -WingmanStress <seconds>` fills the
/// transcript window with 50 lines, keeps a live line changing three times a
/// second, and resizes the window continuously, to reproduce layout hangs
/// (the 0.8.1 resize hang) and check fixes. Nothing is recorded or saved.
@MainActor
enum StressLayout {
    /// 0.8.1's transcript layout instead of the current one, to compare (development only).
    nonisolated static let oldLayout: Bool = {
        #if NO_DIAGNOSTICS
        return false
        #else
        return UserDefaults.standard.bool(forKey: "WingmanOldLayout")
        #endif
    }()

    #if !NO_DIAGNOSTICS
    static func run(recorder: Recorder, seconds: Double, showWindow: () -> Void) {
        let meeting = recorder.stressMeeting()
        recorder.showMeeting?(meeting)
        recorder.stressFill(lines: 50)
        let start = Date()
        var tick = 0
        Log.write("stress: \(Int(seconds)) s of live text and continuous resizing")
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { timer in
            MainActor.assumeIsolated {
                tick += 1
                let elapsed = Date().timeIntervalSince(start)
                guard elapsed < seconds else {
                    timer.invalidate()
                    Log.write("stress: done")
                    return
                }
                if tick % 20 == 0 { recorder.stressPartial(tick: tick / 20) }
                // -WingmanStressManual: lines only; a person drags the window edge.
                guard !UserDefaults.standard.bool(forKey: "WingmanStressManual"),
                      let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("meeting") == true }) else { return }
                var frame = window.frame
                frame.size.width = 520 + 300 * (0.5 + 0.5 * sin(elapsed * 2.5))
                frame.size.height = 520 + 160 * (0.5 + 0.5 * cos(elapsed * 1.7))
                window.setFrame(frame, display: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        if UserDefaults.standard.bool(forKey: "WingmanStressDrag") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { dragCorner(seconds: min(seconds - 4, 20)) }
            // Mute on and off, as in the incident: the status line comes and goes.
            Timer.scheduledTimer(withTimeInterval: 1.3, repeats: true) { t in
                MainActor.assumeIsolated {
                    if Date().timeIntervalSince(start) > seconds { t.invalidate(); recorder.micMuted = false; return }
                    recorder.micMuted.toggle()
                }
            }
        }
    }

    /// Drags the transcript window's bottom-right corner around with real mouse
    /// events — AppKit's live-resize loop, as a person's drag — from a background
    /// thread, so the drag ends (mouse up) even if the main thread freezes.
    static func dragCorner(seconds: Double) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("meeting") == true }),
              let screen = window.screen ?? NSScreen.main else { return }
        window.makeKeyAndOrderFront(nil)
        // Away from the screen's edges, so the corner can be dragged both ways.
        let visible = screen.visibleFrame
        window.setFrame(NSRect(x: visible.midX - 330, y: visible.midY - 260, width: 600, height: 520), display: true)
        // Global display coordinates have their origin at the top left; the
        // resize area starts just outside the corner.
        let frame = window.frame
        let top = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        let offset = UserDefaults.standard.double(forKey: "WingmanStressOffset")
        let corner = CGPoint(x: frame.maxX + offset, y: top - frame.minY + offset)
        Log.write("stress: dragging the window corner for \(Int(seconds)) s (may post events: \(CGPreflightPostEventAccess()), corner \(Int(corner.x)),\(Int(corner.y)))")
        Thread.detachNewThread {
            let source = CGEventSource(stateID: .hidSystemState)
            var last = corner
            func post(_ type: CGEventType, _ point: CGPoint) {
                guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
                if type != .mouseMoved { event.setIntegerValueField(.mouseEventClickState, value: 1) }
                event.setIntegerValueField(.mouseEventDeltaX, value: Int64(point.x - last.x))
                event.setIntegerValueField(.mouseEventDeltaY, value: Int64(point.y - last.y))
                last = point
                event.post(tap: .cghidEventTap)
            }
            post(.mouseMoved, corner)
            Thread.sleep(forTimeInterval: 0.3)
            post(.leftMouseDown, corner)
            Thread.sleep(forTimeInterval: 0.1)
            let start = Date()
            var point = corner
            while Date().timeIntervalSince(start) < seconds {
                let t = Date().timeIntervalSince(start)
                point = CGPoint(x: corner.x - 180 + 180 * cos(t * 2.2), y: corner.y - 120 + 120 * cos(t * 1.6))
                post(.leftMouseDragged, point)
                Thread.sleep(forTimeInterval: 1.0 / 60)
            }
            post(.leftMouseUp, point)
            let at = CGEvent(source: nil)?.location ?? .zero
            Log.write("stress: drag done, pointer at \(Int(at.x)),\(Int(at.y)) (last posted \(Int(point.x)),\(Int(point.y)))")
        }
    }
    #endif
}

#if !NO_DIAGNOSTICS
extension Recorder {
    /// `count` made-up final lines, alternating speakers, of varied lengths.
    func stressFill(lines count: Int) {
        let words = "the quick brown fox jumps over the lazy dog while we review the quarterly numbers and the plan".split(separator: " ")
        stressLines = (0..<count).map { i in
            let n = 4 + (i * 7) % 28
            let text = (0..<n).map { words[($0 + i) % words.count] }.joined(separator: " ")
            return TranscriptLine(id: UUID(), speaker: i % 3 == 0 ? .me : .them, start: Double(i) * 6, end: Double(i) * 6 + 5,
                                  text: text.prefix(1).uppercased() + text.dropFirst() + ".", isFinal: true)
        }
    }

    /// A live (partial) line that grows, like someone talking.
    func stressPartial(tick: Int) {
        let text = (0...(tick % 40)).map { _ in "talking" }.joined(separator: " ")
        stressLiveLine(text, at: Double(stressLineCount) * 6)
    }
}
#endif
