import Foundation

/// What happens after a call, said upfront: the steps as they tick off, and
/// about how long it takes, learned from this Mac's earlier calls (seconds of
/// finishing per minute of call). The first call has no estimate yet.
enum FinishStep: Int, CaseIterable, Comparable {
    case transcript, languages, speakers, audio

    var title: String {
        switch self {
        case .transcript: "Transcript"
        case .languages: "Languages"
        case .speakers: "Speakers"
        case .audio: "Audio"
        }
    }

    static func < (a: FinishStep, b: FinishStep) -> Bool { a.rawValue < b.rawValue }
}

enum FinishTiming {
    static let key = "finishSecondsPerMinute"

    /// Seconds per minute of call, from earlier calls on this Mac.
    static var rate: Double? {
        let value = UserDefaults.standard.double(forKey: key)
        return value > 0 ? value : nil
    }

    /// How long finishing should take for a call this long, or nil without history.
    static func estimate(minutes: Double, rate: Double?) -> TimeInterval? {
        guard let rate, minutes > 0 else { return nil }
        return max(5, rate * minutes + 3)
    }

    /// The rate after a call that took `took` seconds to finish: recent calls
    /// count more. Calls under a minute say little and are left out.
    static func updated(rate: Double?, took: TimeInterval, minutes: Double) -> Double? {
        guard minutes >= 1, took > 0 else { return rate }
        let latest = took / minutes
        return rate.map { $0 * 0.6 + latest * 0.4 } ?? latest
    }

    static func record(took: TimeInterval, minutes: Double) {
        if let new = updated(rate: rate, took: took, minutes: minutes) { UserDefaults.standard.set(new, forKey: key) }
    }

    /// "about 40 s", "about 2 min", "almost done", "taking a little longer";
    /// nil when there's no estimate.
    static func remaining(estimate: TimeInterval?, elapsed: TimeInterval) -> String? {
        guard let estimate else { return nil }
        let left = estimate - elapsed
        if left < -5 { return "taking a little longer" }
        if left < 8 { return "almost done" }
        if left < 60 { return "about \(Int((left / 5).rounded(.up)) * 5) s" }
        return "about \(Int((left / 60).rounded())) min"
    }

    /// A light line under the real step, changing every few seconds.
    static let quips = [
        "Untangling voices…",
        "Matching voices to names…",
        "Dusting off the commas…",
        "Checking the flight log…",
        "Counting who said what…",
        "Folding the paper plane…",
        "Straightening the timestamps…",
        "Smoothing out the ums…",
    ]

    static func quip(elapsed: TimeInterval) -> String {
        quips[Int(max(0, elapsed) / 3) % quips.count]
    }
}
