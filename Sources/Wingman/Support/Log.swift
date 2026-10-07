import Foundation
import MachO

/// Wingman's own log of audio events (devices, formats, restarts), written to
/// ~/Library/Logs/Wingman/wingman.log so problems on real calls can be
/// diagnosed afterwards. Contains no audio or transcript text.
enum Log {
    static let file = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Wingman/wingman.log")
    private static let queue = DispatchQueue(label: "wingman.log")

    /// Testers attach this log to public reports, and error messages can carry
    /// file paths: the home folder becomes ~, and a meeting's file name (often
    /// its calendar title) is left out.
    static func redacted(_ message: String) -> String {
        var text = message.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        text = text.replacingOccurrences(of: #"Meeting Notes/[^"',;)\]\n]+"#, with: "Meeting Notes/…",
                                         options: .regularExpression)
        // The same path inside an NSURL, percent-encoded…
        text = text.replacingOccurrences(of: #"Meeting%20Notes/[^\s,;)\]}"']+"#, with: "Meeting%20Notes/…",
                                         options: .regularExpression)
        // …and a bare file name quoted in an error message ("“08-01 Weekly sync.md” couldn't be…").
        text = text.replacingOccurrences(of: #"[“"][^”"\n]*\.(md|m4a|wav|vtt|srt)[”"]"#, with: "“…”",
                                         options: .regularExpression)
        return text
    }
    /// Unit tests feed made-up audio events; keep them out of the real log. Look for
    /// the loaded test bundle: without Xcode, Swift Testing runs without XCTest.
    private static let disabled = NSClassFromString("XCTestCase") != nil
        || (0..<_dyld_image_count()).contains { i in
            _dyld_get_image_name(i).map { String(cString: $0).contains(".xctest/") } ?? false
        }
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        guard !disabled else { return }
        let line = "\(formatter.string(from: Date()))  \(redacted(message))\n"
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let attributes = try? fm.attributesOfItem(atPath: file.path),
               (attributes[.size] as? Int ?? 0) > 2_000_000 {
                try? fm.removeItem(at: file.deletingPathExtension().appendingPathExtension("old.log"))
                try? fm.moveItem(at: file, to: file.deletingPathExtension().appendingPathExtension("old.log"))
            }
            // The throwing calls: the older seekToEndOfFile()/write(_:) raise an
            // Objective-C exception on a full disk, which would crash Wingman.
            if let handle = try? FileHandle(forWritingTo: file) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: file)
            }
        }
    }
}
