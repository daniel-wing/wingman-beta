import Foundation
import Testing
@testable import Wingman

/// The field Mac's main-thread hangs during calls (0.9.1): the live list
/// following its newest line, the audio released while hung, and no automatic
/// recording straight after a restart from an interrupted recording.
@Suite struct HangSafetyTests {
    // MARK: Following the newest line

    @Test func distanceHasADeadBand() {
        // 500 pt visible of 2000 pt of content.
        func at(_ below: CGFloat) -> TranscriptFollower.Distance {
            TranscriptFollower.distance(offset: 2000 - 500 - below, visible: 500, content: 2000)
        }
        #expect(at(0) == .near)
        #expect(at(80) == .near)
        #expect(at(81) == .between)
        #expect(at(200) == .between)
        #expect(at(201) == .away)
        // Content shorter than the window is always at the bottom.
        #expect(TranscriptFollower.distance(offset: 0, visible: 500, content: 120) == .near)
    }

    @MainActor @Test func nearFlagIsWrittenOnceAfterTheLayoutPass() async {
        let follower = TranscriptFollower()
        var writes: [Bool] = []
        // A layout pass that re-measures back and forth, as in the hangs.
        for distance in [TranscriptFollower.Distance.away, .near, .between, .away, .near] {
            follower.settle(distance) { writes.append($0) }
        }
        #expect(writes.isEmpty, "nothing is written during the pass itself")
        await drainMainQueue()
        #expect(writes == [true], "one write, with the last value")

        follower.settle(.between) { writes.append($0) }
        await drainMainQueue()
        #expect(writes == [true], "the dead band never writes")
    }

    @MainActor @Test func followingScrollsAtMostOncePerInterval() async throws {
        let follower = TranscriptFollower()
        var scrolls: [(id: String, at: TimeInterval)] = []
        let record = { (id: String) in scrolls.append((id, ProcessInfo.processInfo.systemUptime)) }
        // A live line revised 20 times in a burst, then a new line.
        for i in 0..<20 { follower.follow("line-\(i)", scroll: record) }
        follower.follow("next", scroll: record)
        await drainMainQueue()
        #expect(scrolls.map(\.id) == ["next"], "one scroll, to the newest line")

        // Right after a scroll, the next one waits for the interval. (Checked
        // by the gap between the two, not by the clock: a busy test run can
        // be slower than the interval.)
        follower.follow("later", scroll: record)
        try await Task.sleep(for: .seconds(TranscriptFollower.followInterval + 0.3))
        #expect(scrolls.map(\.id) == ["next", "later"])
        if scrolls.count == 2 {
            #expect(scrolls[1].at - scrolls[0].at >= TranscriptFollower.followInterval - 0.01)
        }
    }

    /// Lets the main queue run what was scheduled with `async`.
    @MainActor private func drainMainQueue() async {
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
    }

    // MARK: Releasing the audio while hung

    @Test func audioIsReleasedOncePerHangOnlyWhileRecording() {
        let after = MainThreadWatchdog.releaseAudioAfter
        #expect(!MainThreadWatchdog.shouldReleaseAudio(blocked: after - 1, recording: true, alreadyReleased: false))
        #expect(MainThreadWatchdog.shouldReleaseAudio(blocked: after, recording: true, alreadyReleased: false))
        #expect(!MainThreadWatchdog.shouldReleaseAudio(blocked: after * 10, recording: true, alreadyReleased: true))
        #expect(!MainThreadWatchdog.shouldReleaseAudio(blocked: after * 10, recording: false, alreadyReleased: false))
    }

    @Test func emergencyStopRunsEachRegisteredStopOnce() {
        let stops = AudioEmergencyStop()
        let count = StopCounter()
        let mic = stops.register("microphone") { count.add() }
        _ = stops.register("call audio") { count.add() }
        let gone = stops.register("old capture") { count.add() }
        stops.unregister(gone)
        #expect(stops.stopAll() == ["call audio", "microphone"])
        #expect(count.value == 2)
        // Already stopped: nothing runs twice, and unregistering later is harmless.
        #expect(stops.stopAll().isEmpty)
        stops.unregister(mic)
        #expect(count.value == 2)
        #expect(stops.isEmpty)
    }

    @Test func emergencyStopWorksFromABackgroundThread() async {
        let stops = AudioEmergencyStop()
        let count = StopCounter()
        _ = stops.register("microphone") { count.add() }
        let names = await Task.detached { stops.stopAll() }.value
        #expect(names == ["microphone"])
        #expect(count.value == 1)
    }

    // MARK: After a restart from an interrupted recording

    @Test func asksBeforeRecordingRightAfterAnInterruptedRun() {
        let restarted = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(!CallWatcher.asksAfterRestart(restartedDuringRecording: nil, now: restarted))
        #expect(CallWatcher.asksAfterRestart(restartedDuringRecording: restarted, now: restarted.addingTimeInterval(3)))
        #expect(CallWatcher.asksAfterRestart(restartedDuringRecording: restarted, now: restarted.addingTimeInterval(119)))
        #expect(!CallWatcher.asksAfterRestart(restartedDuringRecording: restarted,
                                              now: restarted.addingTimeInterval(CallWatcher.askAfterRestartFor)))
    }
}

private final class StopCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}
