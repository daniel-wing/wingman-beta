import Foundation
import Testing
@testable import Wingman

/// Teams' call timer decides whether a window change is a new call.
@Suite struct CallTimerTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func reading(_ seconds: Int, after: TimeInterval) -> CallTimer.Reading {
        CallTimer.Reading(seconds: seconds, at: t0.addingTimeInterval(after))
    }

    @Test func readsTheToolbarFormats() {
        #expect(CallTimer.seconds("00:22") == 22)
        #expect(CallTimer.seconds("03:47") == 227)
        #expect(CallTimer.seconds("1:02:03") == 3723)
        #expect(CallTimer.seconds(" 12:05 ") == 725)
        // Not a timer: times of day with words, impossible minutes, other text.
        #expect(CallTimer.seconds("6:26 PM") == nil)
        #expect(CallTimer.seconds("03:75") == nil)
        #expect(CallTimer.seconds("Mute mic") == nil)
        #expect(CallTimer.seconds("1:2:3:4") == nil)
        #expect(CallTimer.seconds("٠٣:٤٧") == nil)
    }

    @Test func aShareOrCompactViewKeepsTheSameCall() {
        // Measured 2026-10-15: 01:3x in the compact view, 03:09 back in the
        // meeting window 97 s later — the same call.
        let before = reading(92, after: 0)
        #expect(!CallTimer.isDifferentCall(previous: before, now: reading(189, after: 97)))
        // Read again after the window was minimized for ten minutes.
        #expect(!CallTimer.isDifferentCall(previous: before, now: reading(692, after: 600)))
        // A display that's a second or two behind.
        #expect(!CallTimer.isDifferentCall(previous: before, now: reading(93, after: 3)))
    }

    @Test func aNewCallRestartsTheTimer() {
        let longCall = reading(25 * 60, after: 0)
        // Straight into a new meeting: its own timer from the start.
        #expect(CallTimer.isDifferentCall(previous: longCall, now: reading(5, after: 20)))
        #expect(CallTimer.isDifferentCall(previous: reading(90, after: 0), now: reading(10, after: 30)))
    }

    @Test func aTimerAheadOfTheClockIsNotANewCall() {
        // A stale reading (the hidden meeting window's timer stops while
        // sharing: 00:24 while the call was at 02:15), then the live one.
        #expect(!CallTimer.isDifferentCall(previous: reading(24, after: 0), now: reading(152, after: 10)))
        // A meeting joined late, already running longer: kept in the same note.
        #expect(!CallTimer.isDifferentCall(previous: reading(10 * 60, after: 0), now: reading(45 * 60, after: 30)))
    }
}
