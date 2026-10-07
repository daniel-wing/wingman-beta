import Foundation

/// Removes old meetings' audio when the user asks for it in Settings → Audio:
/// audio older than a chosen age, and/or the oldest audio once all meeting audio
/// passes a size limit. Notes and subtitles are never touched, and removed files
/// go to the Trash. Only files named the way Wingman names them are considered:
/// `<yyyy-MM-dd>/<HH-mm …><audio suffix>` in the notes folder.
enum AudioCleanup {
    /// Longest first, so a track isn't taken for a meeting's combined ".m4a".
    static let audioSuffixes = ["-them.m4a", "-them.wav", "-me.m4a", "-me.wav", ".m4a"]

    struct Meeting: Equatable {
        /// "<day folder>/<file name without suffix>", e.g. "2026-10-01/14-30 Weekly sync".
        let key: String
        let started: Date
        var files: [URL]
        var bytes: Int64
    }

    /// The meeting a note or audio file belongs to, in the form of `Meeting.key`.
    static func key(for file: URL) -> String {
        let name = file.lastPathComponent
        let base = split(name)?.base ?? file.deletingPathExtension().lastPathComponent
        return "\(file.deletingLastPathComponent().lastPathComponent)/\(base)"
    }

    /// "14-30 Sync-me.m4a" → ("14-30 Sync", "-me.m4a"); nil if it isn't audio.
    static func split(_ fileName: String) -> (base: String, suffix: String)? {
        guard let suffix = audioSuffixes.first(where: { fileName.hasSuffix($0) && fileName.count > $0.count })
        else { return nil }
        return (String(fileName.dropLast(suffix.count)), suffix)
    }

    /// When a meeting started (local time), from its day folder and the time its
    /// files start with: "14-30", "14-30 Name", "14-30 (2) Name". Nil otherwise.
    static func started(day: String, base: String) -> Date? {
        let rest = base.dropFirst(5)
        guard base.count >= 5, rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        return formatter.date(from: "\(day) \(base.prefix(5))")
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        formatter.isLenient = false
        return formatter
    }()

    /// The meetings whose audio goes, oldest first: those started before the age
    /// limit, then the oldest of the rest while all audio is over the size limit.
    /// 0 turns either rule off. Meetings in `keep` stay but still count toward the
    /// size.
    static func toRemove(_ meetings: [Meeting], keep: Set<String> = [], now: Date,
                         maxAgeDays: Int, limitBytes: Int64) -> [Meeting] {
        let cutoff = maxAgeDays > 0 ? Calendar.current.date(byAdding: .day, value: -maxAgeDays, to: now) : nil
        var total = meetings.reduce(Int64(0)) { $0 + $1.bytes }
        var remove: [Meeting] = []
        for meeting in meetings.sorted(by: { $0.started < $1.started }) where !keep.contains(meeting.key) {
            let tooOld = cutoff.map { meeting.started < $0 } ?? false
            let overLimit = limitBytes > 0 && total > limitBytes
            // Oldest first: once one meeting may stay, every newer one may too.
            guard tooOld || overLimit else { break }
            remove.append(meeting)
            total -= meeting.bytes
        }
        return remove
    }

    /// Every meeting's audio in the notes folder.
    static func scan(_ folder: URL) -> [Meeting] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let days = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                     options: .skipsHiddenFiles) else { return [] }
        var meetings: [String: Meeting] = [:]
        for day in days {
            guard let files = try? fm.contentsOfDirectory(at: day, includingPropertiesForKeys: keys,
                                                          options: .skipsHiddenFiles) else { continue }
            for file in files {
                guard let (base, _) = split(file.lastPathComponent),
                      let started = started(day: day.lastPathComponent, base: base),
                      let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true
                else { continue }
                let key = "\(day.lastPathComponent)/\(base)"
                meetings[key, default: Meeting(key: key, started: started, files: [], bytes: 0)].files.append(file)
                meetings[key]?.bytes += Int64(values.fileSize ?? 0)
            }
        }
        return Array(meetings.values)
    }

    /// Applies the rules to the notes folder and moves what goes to the Trash.
    static func run(in folder: URL, maxAgeDays: Int, limitGB: Int, keep: Set<String>, now: Date = Date()) {
        guard maxAgeDays > 0 || limitGB > 0 else { return }
        let remove = toRemove(scan(folder), keep: keep, now: now, maxAgeDays: maxAgeDays,
                              limitBytes: Int64(limitGB) * 1_000_000_000)
        guard !remove.isEmpty else { return }
        var moved = 0, bytes: Int64 = 0, failed = 0
        for meeting in remove {
            for file in meeting.files {
                do {
                    try FileManager.default.trashItem(at: file, resultingItemURL: nil)
                    moved += 1
                } catch {
                    failed += 1
                }
            }
            bytes += meeting.bytes
        }
        // Counts only: file names are usually calendar titles.
        Log.write("audio cleanup: \(moved) audio files of \(remove.count) meetings (\(bytes / 1_000_000) MB) moved to the Trash"
                  + (failed > 0 ? ", \(failed) couldn't be moved" : ""))
    }
}
