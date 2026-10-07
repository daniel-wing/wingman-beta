import AVFoundation
import Foundation
import Testing
@testable import Wingman

private let now = Date(timeIntervalSince1970: 1_790_000_000)

private func meeting(_ key: String, daysAgo: Double, mb: Int64) -> AudioCleanup.Meeting {
    AudioCleanup.Meeting(key: key, started: now.addingTimeInterval(-daysAgo * 86_400), files: [], bytes: mb * 1_000_000)
}

@Suite struct AudioCleanupTests {
    @Test func bothRulesOffRemoveNothing() {
        let meetings = [meeting("a", daysAgo: 400, mb: 900), meeting("b", daysAgo: 1, mb: 900)]
        #expect(AudioCleanup.toRemove(meetings, now: now, maxAgeDays: 0, limitBytes: 0).isEmpty)
    }

    @Test func ageRuleRemovesOnlyOlderMeetings() {
        let meetings = [meeting("new", daysAgo: 2, mb: 10), meeting("old", daysAgo: 45, mb: 10),
                        meeting("older", daysAgo: 90, mb: 10)]
        let removed = AudioCleanup.toRemove(meetings, now: now, maxAgeDays: 30, limitBytes: 0).map(\.key)
        #expect(removed == ["older", "old"])
    }

    @Test func sizeLimitRemovesOldestUntilItFits() {
        let meetings = [meeting("c", daysAgo: 1, mb: 400), meeting("a", daysAgo: 3, mb: 400),
                        meeting("b", daysAgo: 2, mb: 400)]
        // 1.2 GB over a 0.5 GB limit: the two oldest go, 0.4 GB is left.
        let removed = AudioCleanup.toRemove(meetings, now: now, maxAgeDays: 0, limitBytes: 500_000_000).map(\.key)
        #expect(removed == ["a", "b"])
    }

    @Test func keptMeetingStaysButCountsTowardTheLimit() {
        let meetings = [meeting("shown", daysAgo: 5, mb: 600), meeting("other", daysAgo: 1, mb: 600)]
        let removed = AudioCleanup.toRemove(meetings, keep: ["shown"], now: now, maxAgeDays: 1,
                                            limitBytes: 1_000_000_000).map(\.key)
        #expect(removed == ["other"])
    }

    @Test func rulesCombine() {
        let meetings = [meeting("ancient", daysAgo: 400, mb: 1), meeting("recent1", daysAgo: 3, mb: 600),
                        meeting("recent2", daysAgo: 1, mb: 600)]
        let removed = AudioCleanup.toRemove(meetings, now: now, maxAgeDays: 365, limitBytes: 1_000_000_000).map(\.key)
        #expect(removed == ["ancient", "recent1"])
    }

    @Test func splitsTracksFromTheCombinedFile() {
        let split = { (name: String) in AudioCleanup.split(name).map { "\($0.base) | \($0.suffix)" } }
        #expect(split("14-30 Sync-me.m4a") == "14-30 Sync | -me.m4a")
        #expect(split("14-30 Sync-them.wav") == "14-30 Sync | -them.wav")
        #expect(split("14-30 Sync.m4a") == "14-30 Sync | .m4a")
        #expect(split("14-30 Sync.md") == nil)
        #expect(split("14-30 Sync.vtt") == nil)
        #expect(split(".m4a") == nil)
    }

    @Test func onlyWingmansNamesHaveAStart() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let expected = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 14, minute: 30))
        #expect(AudioCleanup.started(day: "2026-10-01", base: "14-30") == expected)
        #expect(AudioCleanup.started(day: "2026-10-01", base: "14-30 Weekly sync") == expected)
        #expect(AudioCleanup.started(day: "2026-10-01", base: "14-30 (2) Weekly sync") == expected)
        #expect(AudioCleanup.started(day: "2026-10-01", base: "14-30x") == nil)
        #expect(AudioCleanup.started(day: "2026-10-01", base: "Podcast") == nil)
        #expect(AudioCleanup.started(day: "Downloads", base: "14-30 Sync") == nil)
    }

    @Test func noteAndItsAudioShareAKey() {
        let folder = URL(fileURLWithPath: "/notes/2026-10-01")
        let note = AudioCleanup.key(for: folder.appendingPathComponent("14-30 Sync.md"))
        #expect(note == "2026-10-01/14-30 Sync")
        #expect(AudioCleanup.key(for: folder.appendingPathComponent("14-30 Sync-them.m4a")) == note)
        #expect(AudioCleanup.key(for: folder.appendingPathComponent("14-30 Sync.m4a")) == note)
    }

    @Test func scanGroupsAudioAndSkipsEverythingElse() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wingman-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let day = root.appendingPathComponent("2026-10-01")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        for (name, size) in [("14-30 Sync.md", 50), ("14-30 Sync.m4a", 100), ("14-30 Sync-me.m4a", 200),
                             ("14-30 Sync-them.wav", 300), ("14-30 Sync.vtt", 10), ("holiday.m4a", 999),
                             (".wingman-rename-x.m4a", 999)] {
            try Data(count: size).write(to: day.appendingPathComponent(name))
        }
        let meetings = AudioCleanup.scan(root)
        #expect(meetings.count == 1)
        #expect(meetings.first?.key == "2026-10-01/14-30 Sync")
        #expect(meetings.first?.bytes == 600)
        #expect(Set(meetings.first?.files.map(\.lastPathComponent) ?? []) ==
                ["14-30 Sync.m4a", "14-30 Sync-me.m4a", "14-30 Sync-them.wav"])
    }

    @Test func compressedTrackKeepsTheAudioInAFractionOfTheSpace() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wingman-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wav = dir.appendingPathComponent("t-me.wav"), m4a = dir.appendingPathComponent("t-me.m4a")
        let rate = Resampler.sampleRate
        let samples = (0..<Int(rate * 10)).map { Float(sin(Double($0) * 2 * .pi * 220 / rate)) * 0.3 }
        try AudioExtractor.write(samples, to: wav)
        try AudioMix.mix([wav], to: m4a)

        let size = { (url: URL) in (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0 }
        #expect(try size(m4a) * 8 < size(wav))
        let file = try AVAudioFile(forReading: m4a)
        #expect(abs(Double(file.length) / file.processingFormat.sampleRate - 10) < 0.2)
    }
}
