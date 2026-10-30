import AppKit
import CoreAudio
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
    static func run(recorder: Recorder, seconds: Double) {
        let meeting = recorder.stressMeeting()
        recorder.showMeeting?(meeting)
        recorder.stressFill(lines: 50)
        let start = Date()
        if UserDefaults.standard.bool(forKey: "WingmanStressFollow") {
            follow(meeting, recorder: recorder, seconds: seconds, start: start)
            return
        }
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
                      let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.identifier?.rawValue == "live-transcript" }) else { return }
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

    /// `-WingmanStressFollow YES`: a call as the field Mac sees it, without any
    /// resizing. Two people talk over each other: each has a live line revised
    /// several times a second that becomes final after a few seconds, and the
    /// transcript follows them. Wingman's mute goes on and off every few
    /// seconds, so the status line above the list comes and goes, as when
    /// following a call's mute. Leave another app in front, as during a call.
    private static func follow(_ meeting: Meeting, recorder: Recorder, seconds: Double, start: Date) {
        let words = "so the numbers for this quarter look better than we expected but we still need to check the plan".split(separator: " ")
        struct Voice { var id = UUID(); var began: TimeInterval; var words = 0 }
        let speakers: [Speaker] = [.them, .me]
        var voices = [Voice(began: 300), Voice(began: 301.5)]
        var tick = 0
        Log.write("stress: \(Int(seconds)) s of two overlapping live lines, no resizing")
        let timer = Timer(timeInterval: 0.25, repeats: true) { timer in
            MainActor.assumeIsolated {
                tick += 1
                let elapsed = Date().timeIntervalSince(start)
                guard elapsed < seconds else {
                    timer.invalidate()
                    recorder.micMuted = false
                    Log.write("stress: done, \(meeting.lines.count) lines")
                    return
                }
                if tick % 11 == 0 { recorder.micMuted.toggle() }
                let i = tick % 2
                voices[i].words += 1 + tick % 3
                let text = (0..<voices[i].words).map { words[($0 + tick) % words.count] }.joined(separator: " ")
                let now = 300 + elapsed
                let final = voices[i].words > 8 + (tick % 7) * 3
                meeting.handle(TranscriptEvent(utteranceID: voices[i].id, speaker: speakers[i], start: voices[i].began,
                                               end: now, text: text, isFinal: final))
                if final { voices[i] = Voice(began: now) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        // -WingmanStressMinimize: minimized a few seconds in, as during a call.
        if UserDefaults.standard.bool(forKey: "WingmanStressMinimize") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                NSApp.windows.first { $0.identifier?.rawValue == "live-transcript" }?.orderOut(nil)
                Log.write("stress: Live Transcript hidden")
            }
        }
    }

    /// Drags the transcript window's bottom-right corner around with real mouse
    /// events — AppKit's live-resize loop, as a person's drag — from a background
    /// thread, so the drag ends (mouse up) even if the main thread freezes.
    static func dragCorner(seconds: Double) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.identifier?.rawValue == "live-transcript" }),
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
/// Development only: `-WingmanHangTest YES` records for about a minute with the
/// main thread blocked for 30 s in the middle, to check that the watchdog lets
/// go of the microphone and call audio while it's hung and that capture comes
/// back afterwards. Results go to wingman.log ("hang test: …"); run
/// `Wingman whosmic --watch 90` alongside to see the microphone let go and
/// come back. Uses the microphone and system audio: never during a call.
@MainActor
enum HangTest {
    static func run(recorder: Recorder) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            await recorder.start()
            guard recorder.isRecording else {
                Log.write("hang test: the recording didn't start (\(recorder.lastError ?? "no error"))")
                return
            }
            recorder.current?.meetingName = "hang test"
            recorder.current?.applyMeetingName()
            try? await Task.sleep(for: .seconds(10))
            Log.write("hang test: before the hang — \(holding())")
            for after in [12.0, 26.0] {
                DispatchQueue.global().asyncAfter(deadline: .now() + after) {
                    Log.write("hang test: \(Int(after)) s into the hang — \(holding())")
                }
            }
            Log.write("hang test: blocking the main thread for 30 s")
            blockMainThread(seconds: 30)
            try? await Task.sleep(for: .seconds(8))
            Log.write("hang test: 8 s after the hang — \(holding()); notice shown: \(recorder.current?.notice != nil)")
            try? await Task.sleep(for: .seconds(12))
            let meeting = await recorder.stop()
            await meeting?.waitUntilDone()
            Log.write("hang test: done, note \(meeting?.currentNote?.path ?? "none")")
        }
    }

    /// A hang as the field Mac had them: the main thread does nothing else.
    private static func blockMainThread(seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// How many call-audio devices this process has; callable from any thread.
    /// (Whether it holds the microphone shows from outside, with `whosmic`:
    /// Wingman's own process list leaves itself out.)
    nonisolated private static func holding() -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices)
        let taps = devices.filter { device in
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                         mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let status = withUnsafeMutablePointer(to: &name) { AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, $0) }
            return status == noErr && (name as String) == "Wingman Tap"
        }.count
        return "call-audio devices: \(taps)"
    }
}

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
