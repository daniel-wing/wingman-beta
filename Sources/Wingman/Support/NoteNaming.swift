import Foundation

/// How meeting files are named: `2026-10-07_01_Weekly sync.md`, where `01` is the
/// meeting's number that day (its day folder is `2026-10-07`). Notes from before
/// 0.9 are named by time, `13-31 Weekly sync.md`; both keep working everywhere,
/// and existing files are never renamed.
enum NoteNaming {
    /// "2026-10-07_01" (three digits from 100).
    static func prefix(day: String, number: Int) -> String {
        "\(day)_\(String(format: "%02d", number))"
    }

    /// "<prefix>_<name>", or the prefix alone for a meeting with no name.
    static func base(prefix: String, name: String) -> String {
        name.isEmpty ? prefix : "\(prefix)_\(name)"
    }

    /// The number and name in a new-style base, if it is one for this day folder:
    /// a date in the name that isn't the folder's (a file copied from elsewhere)
    /// doesn't count.
    static func parse(base: String, day: String) -> (number: Int, name: String)? {
        guard base.hasPrefix(day + "_") else { return nil }
        let rest = base.dropFirst(day.count + 1)
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard digits.count >= 2, let number = Int(digits) else { return nil }
        let after = rest.dropFirst(digits.count)
        if after.isEmpty { return (number, "") }
        guard after.first == "_" else { return nil }
        return (number, String(after.dropFirst()))
    }

    /// The meeting's name as people see it, from a file base of either style:
    /// "2026-10-07_01_Weekly sync" and "13-31 (2) Weekly sync" are both "Weekly sync".
    static func displayName(base: String) -> String {
        let day = String(base.prefix(10))
        if isDay(day), let parsed = parse(base: base, day: day) {
            return parsed.name.isEmpty ? "Meeting" : parsed.name
        }
        if AudioCleanup.started(day: "2000-01-01", base: base) != nil {
            var rest = base.dropFirst(5).drop { $0 == " " }
            if rest.hasPrefix("("), let close = rest.firstIndex(of: ")") {
                rest = rest[rest.index(after: close)...].drop { $0 == " " }
            }
            return rest.isEmpty ? "Meeting" : String(rest)
        }
        return base
    }

    /// "2026-10-07".
    static func isDay(_ text: String) -> Bool {
        text.count == 10 && text.enumerated().allSatisfy { i, c in i == 4 || i == 7 ? c == "-" : c.isASCII && c.isNumber }
    }

    /// The number the next meeting in a day folder gets: one more than both the
    /// highest number used and the number of meetings there, so meetings recorded
    /// before 0.9 (named by time) count too. Hidden files and Wingman's own
    /// temporary rename files don't.
    static func nextNumber(fileNames: [String], day: String) -> Int {
        var highest = 0
        var meetings = Set<String>()
        for name in fileNames where !name.hasPrefix(".") {
            let base = baseName(of: name)
            meetings.insert(base)
            if let parsed = parse(base: base, day: day) { highest = max(highest, parsed.number) }
        }
        return max(highest, meetings.count) + 1
    }

    /// The meeting a file belongs to: its name without a companion suffix.
    static func baseName(of fileName: String) -> String {
        for suffix in companionSuffixes where fileName.hasSuffix(suffix) && fileName.count > suffix.count {
            return String(fileName.dropLast(suffix.count))
        }
        return (fileName as NSString).deletingPathExtension
    }

    /// Longest first, so "-them.m4a" isn't taken for ".m4a".
    static let companionSuffixes = ["-them.m4a", "-them.wav", "-me.m4a", "-me.wav", ".m4a", ".md", ".vtt", ".srt"]

    enum ReserveError: Error { case noFreeNumber }

    /// Picks the next number in `folder` and claims it by creating the note
    /// exclusively (`O_EXCL`): if that name — or any of its companion files —
    /// already exists, the next number is tried, so nothing is ever overwritten,
    /// even with two recordings starting at once. Returns the base (no extension)
    /// and its prefix. The note is created empty; the caller writes it.
    static func reserve(in folder: URL, day: String, name: String) throws -> (base: URL, prefix: String) {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        var number = nextNumber(fileNames: names, day: day)
        while number <= 999 {
            let prefix = prefix(day: day, number: number)
            let base = folder.appendingPathComponent(self.base(prefix: prefix, name: name))
            let taken = companionSuffixes.contains { fm.fileExists(atPath: base.path + $0) }
            if !taken {
                let fd = open(base.path + ".md", O_CREAT | O_EXCL | O_WRONLY, 0o644)
                if fd >= 0 {
                    close(fd)
                    return (base, prefix)
                }
                guard errno == EEXIST else { throw CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)]) }
            }
            number += 1
        }
        throw ReserveError.noFreeNumber
    }
}
