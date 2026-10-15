import Foundation

/// Changes a file the user owns (a note, its subtitles) as safely as Wingman
/// can: a backup copy first, then — inside one coordinated write, so iCloud
/// Drive, Dropbox and other apps that coordinate wait — the current bytes are
/// read, changed, written to a temporary file next to it, and swapped in, only
/// if the file hasn't changed since it was read. Afterwards the result is read
/// back, and Finder tags, permissions and the creation date are checked against
/// what they were, and restored if the swap lost them.
enum NoteFile {
    enum Failure: Error, Equatable {
        /// The file isn't on this Mac (not downloaded) and didn't arrive in time.
        case notDownloaded
        case unreadable
        /// It changed while being written: nothing was swapped in.
        case changedWhileWriting
        /// The file read back isn't what was written.
        case verifyFailed
        case writeFailed(String)
    }

    struct Result {
        /// The bytes before and after.
        let old: Data
        let new: Data
        /// Tags, permissions or the creation date that couldn't be put back.
        let attributesLost: [String]
    }

    /// Reads `url` the way a coordinated reader should (waits for a sync
    /// provider to finish, downloads a file that's only in the cloud).
    static func read(_ url: URL, timeout: TimeInterval = 20) throws -> Data {
        var data: Data?
        try coordinate(url, writing: false, timeout: timeout) { url in data = try? Data(contentsOf: url) }
        guard let data else { throw Failure.unreadable }
        return data
    }

    /// Applies `change` to the file's current bytes and swaps the result in. If
    /// `change` throws, nothing is written and its error comes back. `before`
    /// runs just before the swap (a test hook for "changed meanwhile").
    @discardableResult
    static func rewrite(_ url: URL, timeout: TimeInterval = 20, before: (() -> Void)? = nil,
                        change: @escaping (Data) throws -> Data) throws -> Result {
        var outcome: Swift.Result<Result, Error> = .failure(Failure.unreadable)
        try coordinate(url, writing: true, timeout: timeout) { url in
            outcome = Swift.Result { try swap(url, before: before, change: change) }
        }
        return try outcome.get()
    }

    private static func swap(_ url: URL, before: (() -> Void)?, change: (Data) throws -> Data) throws -> Result {
        let fm = FileManager.default
        guard let old = try? Data(contentsOf: url) else { throw Failure.unreadable }
        let attributes = Attributes(url)
        let new = try change(old)
        guard new != old else { return Result(old: old, new: new, attributesLost: []) }

        let temp = url.deletingLastPathComponent().appendingPathComponent(".wingman-edit-\(UUID().uuidString)-\(url.lastPathComponent)")
        do {
            try new.write(to: temp)
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
        defer { try? fm.removeItem(at: temp) }
        before?()
        // Last check: an app that doesn't coordinate may have written meanwhile.
        let now = Attributes(url)
        guard now.modified == attributes.modified, now.size == attributes.size else { throw Failure.changedWhileWriting }
        do {
            _ = try fm.replaceItemAt(url, withItemAt: temp)
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
        guard (try? Data(contentsOf: url)) == new else { throw Failure.verifyFailed }
        return Result(old: old, new: new, attributesLost: attributes.restore(on: url))
    }

    /// What a user would notice losing: Finder tags, permissions, creation date.
    struct Attributes {
        let modified: Date?
        let size: Int?
        let created: Date?
        let tags: [String]?
        let permissions: Int?

        init(_ url: URL) {
            let fresh = URL(fileURLWithPath: url.path)
            let values = try? fresh.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .creationDateKey, .tagNamesKey])
            modified = values?.contentModificationDate
            size = values?.fileSize
            created = values?.creationDate
            tags = values?.tagNames
            permissions = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
        }

        /// Puts back what changed; returns what couldn't be.
        func restore(on url: URL) -> [String] {
            var lost: [String] = []
            let now = Attributes(url)
            var file = URL(fileURLWithPath: url.path)
            if (now.tags ?? []) != (tags ?? []) {
                var values = URLResourceValues()
                values.tagNames = tags ?? []
                if (try? file.setResourceValues(values)) == nil { lost.append("Finder tags") }
            }
            if let permissions, now.permissions != permissions {
                if (try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)) == nil {
                    lost.append("permissions")
                }
            }
            if let created, let current = now.created, abs(current.timeIntervalSince(created)) > 1 {
                if (try? FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: url.path)) == nil {
                    lost.append("creation date")
                }
            }
            return lost
        }
    }

    /// Runs `body` inside an NSFileCoordinator read or write, giving up after
    /// `timeout` if access wasn't granted by then (a file still downloading,
    /// another app holding it). Once `body` has started it always finishes, and
    /// its own result is what comes back.
    private static func coordinate(_ url: URL, writing: Bool, timeout: TimeInterval, body: @escaping (URL) throws -> Void) throws {
        let coordinator = NSFileCoordinator()
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        enum State { case waiting, running, cancelled }
        var state = State.waiting
        var coordinationError: NSError?
        var bodyError: Error?
        let run = { (url: URL) in
            lock.lock()
            guard state != .cancelled else { lock.unlock(); return }
            state = .running
            lock.unlock()
            do { try body(url) } catch { bodyError = error }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            if writing {
                coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError, byAccessor: run)
            } else {
                coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError, byAccessor: run)
            }
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            lock.lock()
            let waiting = state == .waiting
            if waiting { state = .cancelled }
            lock.unlock()
            if waiting { coordinator.cancel() }
            done.wait()
            if waiting { throw Failure.notDownloaded }
        }
        if let bodyError { throw bodyError }
        if let coordinationError { throw Failure.writeFailed(coordinationError.localizedDescription) }
    }

    // MARK: - Backups

    /// Copies of notes taken before Wingman changed them, in Wingman's own
    /// folder (not the notes folder, which is often synced), readable only by
    /// you; each kept 30 days, at most 10 per meeting.
    static let backupsFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Wingman/Note Backups", isDirectory: true)
    static let keepBackupsDays = 30
    static let backupsPerMeeting = 10

    /// Copies `files` (those that exist) into a new backup for the meeting,
    /// in a folder named after when it was taken.
    static func backUp(_ files: [URL], meeting: UUID, in folder: URL = backupsFolder, now: Date = Date()) throws {
        let fm = FileManager.default
        let target = folder.appendingPathComponent(meeting.uuidString)
            .appendingPathComponent("\(stampFormatter.string(from: now)) \(UUID().uuidString.prefix(4))")
        try fm.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        for file in files where fm.fileExists(atPath: file.path) {
            try fm.copyItem(at: file, to: target.appendingPathComponent(file.lastPathComponent))
        }
        prune(meeting: meeting, in: folder, now: now)
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter
    }()

    /// Removes backups past 30 days, and all but the newest 10 per meeting.
    static func prune(meeting: UUID? = nil, in folder: URL = backupsFolder, now: Date = Date()) {
        let fm = FileManager.default
        let meetings = meeting.map { [folder.appendingPathComponent($0.uuidString)] }
            ?? ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
        let cutoff = now.addingTimeInterval(-Double(keepBackupsDays) * 86_400)
        for meetingFolder in meetings {
            let backups = ((try? fm.contentsOfDirectory(at: meetingFolder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
                .map { ($0, stampFormatter.date(from: String($0.lastPathComponent.prefix(19))) ?? .distantPast) }
                .sorted { $0.1 > $1.1 }
            for (index, (url, taken)) in backups.enumerated() where index >= backupsPerMeeting || taken < cutoff {
                try? fm.removeItem(at: url)
            }
            if (try? fm.contentsOfDirectory(atPath: meetingFolder.path))?.isEmpty == true { try? fm.removeItem(at: meetingFolder) }
        }
    }

    /// The backups, newest first, for Show Backups….
    static func backups(in folder: URL = backupsFolder) -> [URL] {
        let fm = FileManager.default
        let meetings = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return meetings.flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
