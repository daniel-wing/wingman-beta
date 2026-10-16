import Foundation

/// Teams shows how long the call has lasted ("03:47", "1:02:03") in its
/// meeting toolbar. The timer belongs to the call, not to a window: sharing the
/// screen, the compact view, minimizing or popping out keep it counting, while
/// a different call shows its own, from 00:00. So a timer that restarts means
/// a new call: the one signal Wingman uses to start a new note on its own
/// (measured 2026-10-15: a share's compact view kept the same timer; 0.9.0
/// split on the window change and cut one call into three notes).
enum CallTimer {
    struct Reading: Equatable {
        let seconds: Int
        let at: Date
    }

    /// How far the timer may be from where the clock says it should be before
    /// it counts as another call (reads are a couple of seconds apart, and the
    /// display updates once a second).
    static let tolerance: TimeInterval = 30

    /// "03:47" → 227, "1:02:03" → 3723; nil for anything else.
    static func seconds(_ text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.count <= 2 && $0.allSatisfy(\.isASCII) }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count, numbers.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
        return numbers.reduce(0) { $0 * 60 + $1 }
    }

    /// A different call restarts the timer: it's behind where the clock says
    /// the previous call's would be. Only going back counts: a timer that
    /// jumps forward is just as likely a stale reading (while sharing, Teams
    /// hides the meeting window and its timer stops updating, measured
    /// 2026-10-15), so a meeting joined late, already running longer, stays in
    /// the same note, as before 0.9.
    static func isDifferentCall(previous: Reading, now: Reading) -> Bool {
        let expected = Double(previous.seconds) + now.at.timeIntervalSince(previous.at)
        return Double(now.seconds) < expected - tolerance
    }
}
