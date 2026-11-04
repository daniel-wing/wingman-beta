import Foundation

/// Where Wingman keeps what it writes. A development copy can be pointed
/// elsewhere with `-WingmanTestData <folder>`, so a test with a real recording
/// (a crash mid-call, say) never touches the real notes, meeting index, voices
/// or note backups. The speech models are only read, so they stay shared.
enum DataFolders {
    nonisolated static let testRoot: URL? = {
        #if NO_DIAGNOSTICS
        return nil
        #else
        guard let path = UserDefaults.standard.string(forKey: "WingmanTestData"), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
        #endif
    }()

    /// Application Support/Wingman.
    nonisolated static let support = testRoot?.appendingPathComponent("Support", isDirectory: true)
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wingman", isDirectory: true)

    /// ~/Meeting Notes.
    nonisolated static let notes = testRoot?.appendingPathComponent("Meeting Notes", isDirectory: true)
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Meeting Notes", isDirectory: true)

    /// Caches/Wingman.
    nonisolated static let caches = testRoot?.appendingPathComponent("Caches", isDirectory: true)
        ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wingman", isDirectory: true)
}
