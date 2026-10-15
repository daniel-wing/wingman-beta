import Foundation

/// Finishes, at the next launch, the audio of a recording that Wingman didn't
/// get to finish (a crash, a force quit, the Mac shutting down).
///
/// While recording, Wingman keeps a small record next to its scratch audio:
/// which note the meeting is, which tracks it writes, and whether audio is
/// kept. At launch, for each record still there:
/// 1. each track's header is fixed (`WAVRepair`), so players see all the audio;
/// 2. with *Save meeting audio* on, the meeting's combined `.m4a` is made if missing;
/// 3. kept separate tracks become `.m4a` like after any meeting; scratch tracks go.
/// Tracks from 0.8, which had no record, are found by their broken headers in
/// the notes folder and finished the same way. Notes are never touched.
enum RecordingRecovery {
    struct Record: Codable, Equatable {
        var note: URL
        var tracks: [URL]
        let keepAudio: Bool
        /// The tracks are the meeting's own separate tracks (next to the note), not scratch files.
        let tracksKept: Bool
        let started: Date
    }

    struct Outcome: Equatable {
        let note: URL
        let seconds: Double
        let combinedSaved: Bool
    }

    static func recordURL(for id: UUID, in folder: URL) -> URL {
        folder.appendingPathComponent("recording-\(id.uuidString).json")
    }

    static func save(_ record: Record, id: UUID, in folder: URL) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(record).write(to: recordURL(for: id, in: folder), options: .atomic)
        } catch {
            Log.write("couldn't save the recording's recovery record: \(Log.describe(error))")
        }
    }

    static func remove(id: UUID, in folder: URL) {
        try? FileManager.default.removeItem(at: recordURL(for: id, in: folder))
    }

    /// The records left by recordings that didn't finish. Read at launch,
    /// before anything can start a new recording.
    static func leftovers(in folder: URL) -> [(url: URL, record: Record)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("recording-") && $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url), let record = try? JSONDecoder().decode(Record.self, from: data) else {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            return (url, record)
        }
    }

    /// Kept tracks with a broken header in the last `days` day folders and no
    /// record (left by 0.8), grouped by meeting.
    static func orphanedTracks(in notes: URL, days: Int = 30, now: Date = Date()) -> [Record] {
        let fm = FileManager.default
        let first = Recorder.dayFolderName(for: Calendar.current.date(byAdding: .day, value: -days, to: now)!)
        var byNote: [URL: [URL]] = [:]
        for day in ((try? fm.contentsOfDirectory(atPath: notes.path)) ?? []) where NoteNaming.isDay(day) && day >= first {
            let folder = notes.appendingPathComponent(day, isDirectory: true)
            for name in ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []) where name.hasSuffix("-me.wav") || name.hasSuffix("-them.wav") {
                let track = folder.appendingPathComponent(name)
                guard needsRepair(track) else { continue }
                let base = String(name.dropLast(name.hasSuffix("-me.wav") ? 7 : 9))
                byNote[folder.appendingPathComponent(base + ".md"), default: []].append(track)
            }
        }
        return byNote.map { Record(note: $0.key, tracks: $0.value.sorted { $0.path < $1.path }, keepAudio: true, tracksKept: true, started: now) }
    }

    /// Whether a WAV's header sizes disagree with its length (left unfinished).
    static func needsRepair(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let length = try? handle.seekToEnd(), length > 12, (try? handle.seek(toOffset: 4)) != nil,
              let size = try? handle.read(upToCount: 4), size.count == 4 else { return false }
        let riff = UInt32(size[0]) | UInt32(size[1]) << 8 | UInt32(size[2]) << 16 | UInt32(size[3]) << 24
        return UInt64(riff) + 8 != length
    }

    /// Finishes one recording's audio. Slow (it compresses audio): run it off the main thread.
    static func finish(_ record: Record, mix: ([URL], URL) throws -> Void = AudioMix.mix) -> Outcome {
        let fm = FileManager.default
        let tracks = record.tracks.filter { fm.fileExists(atPath: $0.path) }
        var seconds = 0.0
        for track in tracks {
            do {
                if let result = try WAVRepair.repair(track) { seconds = max(seconds, result.seconds) }
            } catch {
                Log.write("couldn't repair an interrupted track: \(Log.describe(error))")
            }
        }
        var combinedSaved = false
        let combined = record.note.deletingPathExtension().appendingPathExtension("m4a")
        if record.keepAudio, !tracks.isEmpty, fm.fileExists(atPath: record.note.deletingLastPathComponent().path) {
            if fm.fileExists(atPath: combined.path) {
                combinedSaved = true
            } else {
                do {
                    try mix(tracks, combined)
                    combinedSaved = true
                } catch {
                    Log.write("couldn't save the interrupted meeting's audio: \(Log.describe(error))")
                }
            }
        }
        for track in tracks {
            if record.tracksKept {
                let compressed = track.deletingPathExtension().appendingPathExtension("m4a")
                do {
                    if !fm.fileExists(atPath: compressed.path) { try mix([track], compressed) }
                    try fm.removeItem(at: track)
                } catch {
                    // The repaired WAV stays: it plays as it is.
                    Log.write("kept an interrupted track as WAV: \(Log.describe(error))")
                }
            } else if combinedSaved || !record.keepAudio {
                try? fm.removeItem(at: track)
            } else {
                // Audio was wanted and couldn't be mixed: keep the track next to the note.
                let kept = record.note.deletingPathExtension().lastPathComponent
                    + (track.lastPathComponent.hasSuffix("-me.wav") ? "-me.wav" : "-them.wav")
                try? fm.moveItem(at: track, to: record.note.deletingLastPathComponent().appendingPathComponent(kept))
            }
        }
        return Outcome(note: record.note, seconds: seconds, combinedSaved: combinedSaved)
    }
}
