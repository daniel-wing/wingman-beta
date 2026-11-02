import Foundation
import Testing
@testable import Wingman

/// After the call: about how long finishing takes, said upfront.
@Suite struct FinishTimingTests {
    @Test func noHistoryNoEstimate() {
        #expect(FinishTiming.estimate(minutes: 30, rate: nil) == nil)
        #expect(FinishTiming.remaining(estimate: nil, elapsed: 3) == nil)
    }

    @Test func estimateGrowsWithTheCall() {
        #expect(FinishTiming.estimate(minutes: 30, rate: 1.5) == 48)
        #expect(FinishTiming.estimate(minutes: 1, rate: 0.5) == 5, "never less than 5 s")
    }

    @Test func recentCallsCountMore() {
        #expect(FinishTiming.updated(rate: nil, took: 60, minutes: 30) == 2)
        #expect(FinishTiming.updated(rate: 2, took: 30, minutes: 30) == 1.6)
        #expect(FinishTiming.updated(rate: 2, took: 10, minutes: 0.5) == 2, "a call under a minute is left out")
    }

    @Test func whatTheUserReads() {
        #expect(FinishTiming.remaining(estimate: 48, elapsed: 2) == "about 50 s")
        #expect(FinishTiming.remaining(estimate: 200, elapsed: 10) == "about 3 min")
        #expect(FinishTiming.remaining(estimate: 48, elapsed: 44) == "almost done")
        #expect(FinishTiming.remaining(estimate: 48, elapsed: 60) == "taking a little longer")
    }

    @Test func theLightLineChangesEveryFewSeconds() {
        #expect(FinishTiming.quip(elapsed: 0) == FinishTiming.quip(elapsed: 2.9))
        #expect(FinishTiming.quip(elapsed: 0) != FinishTiming.quip(elapsed: 3))
    }
}
