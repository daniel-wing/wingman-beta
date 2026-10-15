import Foundation

/// Writes one meeting track (16 kHz mono Float32 WAV) on its own queue, fed
/// straight from the capture thread — not by transcription, and never waiting
/// for the main thread, so a frozen window or a slow speech model can't stop a
/// recording.
///
/// The file is playable at any moment: its header's sizes are rewritten every
/// couple of seconds, so a crash or a force quit loses at most the last ~2.5 s
/// (and `WAVRepair` fixes even that at the next launch).
///
/// The newest half second is held back, so `redact` can still erase it when it
/// turns out you'd muted a moment ago — the same rule the transcript follows.
final class TrackWriter: @unchecked Sendable {
    static let sampleRate = 16_000
    private static let holdBack = 8_000        // 0.5 s
    private static let headerEvery = 32_000    // samples written between header updates (2 s)

    private let queue: DispatchQueue
    private let handle: FileHandle
    let url: URL
    private var unwritten: [Float] = []
    private var written = 0
    private var sinceHeader = 0
    private var failed = false
    private var closed = false
    /// Told once, on the first write that fails (full disk, folder gone).
    private let onProblem: @Sendable (String) -> Void

    init(url: URL, onProblem: @escaping @Sendable (String) -> Void) throws {
        self.url = url
        self.onProblem = onProblem
        queue = DispatchQueue(label: "wingman.track.\(url.lastPathComponent.hashValue)", qos: .userInitiated)
        guard FileManager.default.createFile(atPath: url.path, contents: WAVFormat.header(samples: 0)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    /// Queues audio to write. Returns at once.
    func append(_ samples: [Float]) {
        queue.async { [self] in
            guard !closed else { return }
            unwritten += samples
            if unwritten.count > Self.holdBack {
                let ready = unwritten.count - Self.holdBack
                write(Array(unwritten.prefix(ready)))
                unwritten.removeFirst(ready)
            }
        }
    }

    /// Queues the audio in one of Wingman's finished track files (after its
    /// header), as if it had been appended: for joining a split back. Audio
    /// appended after this call follows it. `done` says (on the writer's queue)
    /// whether exactly `expected` samples were read and nothing failed to write,
    /// so the caller knows whether `file` can go.
    func appendContents(of file: URL, expected: Int, read: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) },
                        done: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            guard !closed, let data = try? read(file), data.count >= WAVFormat.headerSize else { return done(false) }
            let body = data.dropFirst(WAVFormat.headerSize)
            guard body.count / 4 == expected else { return done(false) }
            let samples = body.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(body.count / 4)) }
            unwritten += samples
            if unwritten.count > Self.holdBack {
                let ready = unwritten.count - Self.holdBack
                write(Array(unwritten.prefix(ready)))
                unwritten.removeFirst(ready)
            }
            done(!failed)
        }
    }

    /// Silences the latest `seconds` that haven't been written yet.
    func redact(seconds: Double) {
        queue.async { [self] in
            let n = min(Int(seconds * Double(Self.sampleRate)), unwritten.count)
            guard n > 0 else { return }
            for i in (unwritten.count - n)..<unwritten.count { unwritten[i] = 0 }
        }
    }

    /// Writes what's left, finalizes the header and closes the file. Waits for
    /// the queue; returns the number of samples in the file.
    @discardableResult
    func finish() -> Int {
        queue.sync { [self] in
            guard !closed else { return written }
            write(unwritten)
            unwritten.removeAll()
            updateHeader()
            try? handle.synchronize()
            try? handle.close()
            closed = true
            return written
        }
    }

    /// Tests: a copy of the file as it is on disk now, without finishing it
    /// (what a force quit leaves).
    func finishCopyForTesting(to copy: URL) -> Bool {
        queue.sync { (try? FileManager.default.copyItem(at: url, to: copy)) != nil }
    }

    /// Tests: writes fail from now on.
    func closeHandleForTesting() {
        queue.sync { try? handle.close() }
    }

    private func write(_ samples: [Float]) {
        guard !samples.isEmpty, !failed else { return }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        do {
            try handle.write(contentsOf: data)
            written += samples.count
            sinceHeader += samples.count
            if sinceHeader >= Self.headerEvery { updateHeader() }
        } catch {
            failed = true
            onProblem("couldn't write: \(Log.describe(error))")
        }
    }

    /// Rewrites the sizes in the header for what's in the file now.
    private func updateHeader() {
        sinceHeader = 0
        do {
            let end = try handle.offset()
            try WAVFormat.patchSizes(handle, samples: written)
            try handle.seek(toOffset: end)
        } catch {
            if !failed {
                failed = true
                onProblem("couldn't update the file: \(Log.describe(error))")
            }
        }
    }
}

/// Which file a track's audio goes to right now. The capture side appends
/// through it; a split points it at the new meeting's file between two
/// buffers, so no audio is lost or doubled, and a join puts the old file back.
final class WriterSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var writer: TrackWriter?
    private var count = 0

    /// Samples appended since the recording started (all meetings).
    var appended: Int { lock.withLock { count } }

    func append(_ samples: [Float]) {
        lock.lock()
        count += samples.count
        writer?.append(samples)
        lock.unlock()
    }

    func redact(seconds: Double) {
        lock.withLock { writer?.redact(seconds: seconds) }
    }

    /// Points the slot at `new`; returns the writer it replaced (still open).
    @discardableResult
    func swap(_ new: TrackWriter?) -> TrackWriter? {
        lock.withLock {
            let old = writer
            writer = new
            return old
        }
    }

    /// Undoes a split: what the current writer's file holds is appended to
    /// `old`, ahead of any audio still to come, and `old` takes over again.
    /// `done` gets whether that worked and the file it came from, which must
    /// stay until it did (it's never read after `done`).
    func rejoin(_ old: TrackWriter, read: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) },
                done: @escaping @Sendable (Bool, URL?) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if let current = writer {
            let samples = current.finish()
            let url = current.url
            old.appendContents(of: url, expected: samples, read: read) { done($0, url) }
        } else {
            done(true, nil)
        }
        writer = old
    }
}

/// The WAV layout Wingman writes: RIFF, an 18-byte `fmt ` chunk for 32-bit IEEE
/// float mono at 16 kHz, a `fact` chunk with the sample count, then `data`.
enum WAVFormat {
    static let headerSize = 58
    private static let riffSizeOffset: UInt64 = 4
    private static let factCountOffset: UInt64 = 46
    private static let dataSizeOffset: UInt64 = 54

    static func header(samples: Int) -> Data {
        var d = Data()
        func put(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let dataBytes = UInt32(samples * 4)
        put("RIFF"); u32(UInt32(headerSize - 8) + dataBytes); put("WAVE")
        put("fmt "); u32(18); u16(3); u16(1); u32(UInt32(TrackWriter.sampleRate)); u32(UInt32(TrackWriter.sampleRate * 4)); u16(4); u16(32); u16(0)
        put("fact"); u32(4); u32(UInt32(samples))
        put("data"); u32(dataBytes)
        return d
    }

    static func patchSizes(_ handle: FileHandle, samples: Int) throws {
        func put(_ value: UInt32, at offset: UInt64) throws {
            try handle.seek(toOffset: offset)
            try withUnsafeBytes(of: value.littleEndian) { try handle.write(contentsOf: Data($0)) }
        }
        let dataBytes = UInt32(samples * 4)
        try put(UInt32(headerSize - 8) + dataBytes, at: riffSizeOffset)
        try put(UInt32(samples), at: factCountOffset)
        try put(dataBytes, at: dataSizeOffset)
    }
}

/// Fixes a WAV whose header sizes don't match what's in the file — a track left
/// by a crash or a force quit (Wingman's own files, and those 0.8 wrote with
/// AVAudioFile, which only writes the sizes when the file is closed).
enum WAVRepair {
    struct Result: Equatable {
        /// The header was wrong and has been fixed.
        let repaired: Bool
        /// Seconds of audio in the file.
        let seconds: Double
    }

    /// nil if it isn't a WAV this can read.
    static func repair(_ url: URL) throws -> Result? {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        guard let head = try handle.read(upToCount: 65_536), head.count >= 12,
              head.prefix(4) == Data("RIFF".utf8), head[8..<12] == Data("WAVE".utf8) else { return nil }

        var offset = 12
        var blockAlign = 4, rate = 16_000
        var factOffset: Int?
        while offset + 8 <= head.count {
            let id = String(decoding: head[offset..<(offset + 4)], as: UTF8.self)
            let size = Int(head.u32(at: offset + 4))
            if id == "fmt ", offset + 24 <= head.count {
                rate = Int(head.u32(at: offset + 12))
                blockAlign = max(1, Int(head.u16(at: offset + 20)))
            } else if id == "fact" {
                factOffset = offset + 8
            } else if id == "data" {
                let dataStart = offset + 8
                let available = (Int(length) - dataStart) / blockAlign * blockAlign
                let seconds = Double(available / blockAlign) / Double(max(rate, 1))
                let riff = UInt32(clamping: Int(length) - 8)
                guard size != available || head.u32(at: 4) != riff else { return Result(repaired: false, seconds: seconds) }
                func put(_ value: UInt32, at position: Int) throws {
                    try handle.seek(toOffset: UInt64(position))
                    try withUnsafeBytes(of: value.littleEndian) { try handle.write(contentsOf: Data($0)) }
                }
                try put(riff, at: 4)
                try put(UInt32(clamping: available), at: offset + 4)
                if let factOffset { try put(UInt32(clamping: available / blockAlign), at: factOffset) }
                return Result(repaired: true, seconds: seconds)
            }
            // A size the file doesn't have (unfinished chunk): can't go on.
            guard size >= 0, offset + 8 + size <= head.count || id == "data" else { return nil }
            offset += 8 + size + (size % 2)
        }
        return nil
    }
}

private extension Data {
    func u32(at i: Int) -> UInt32 {
        UInt32(self[startIndex + i]) | UInt32(self[startIndex + i + 1]) << 8
            | UInt32(self[startIndex + i + 2]) << 16 | UInt32(self[startIndex + i + 3]) << 24
    }
    func u16(at i: Int) -> UInt16 { UInt16(self[startIndex + i]) | UInt16(self[startIndex + i + 1]) << 8 }
}
