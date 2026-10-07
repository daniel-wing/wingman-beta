import Foundation

/// `Wingman mix <note.md or folder>…` creates the combined .m4a for meetings
/// recorded before Wingman saved one, from their -me.wav and -them.wav tracks.
enum MixTool {
    static func run(_ args: [String]) async -> Int32 {
        guard !args.isEmpty else {
            print("Usage: Wingman mix <meeting note .md, or a folder of notes>…")
            return 2
        }
        let fm = FileManager.default
        var notes: [URL] = []
        for arg in args {
            let url = URL(fileURLWithPath: (arg as NSString).expandingTildeInPath)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let items = (fm.enumerator(at: url, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
                notes += items.filter { $0.pathExtension == "md" }
            } else if url.pathExtension == "md" {
                notes.append(url)
            }
        }
        var made = 0
        for note in notes.sorted(by: { $0.path < $1.path }) {
            let base = note.deletingPathExtension()
            let folder = base.deletingLastPathComponent()
            let tracks = ["me", "them"]
                .map { folder.appendingPathComponent("\(base.lastPathComponent)-\($0).wav") }
                .filter { fm.fileExists(atPath: $0.path) }
            let output = base.appendingPathExtension("m4a")
            guard !tracks.isEmpty, !fm.fileExists(atPath: output.path) else { continue }
            do {
                try AudioMix.mix(tracks, to: output)
                print("Created \(output.lastPathComponent)")
                made += 1
            } catch {
                print("Failed \(note.lastPathComponent): \(error.localizedDescription)")
            }
        }
        print(made == 0 ? "Nothing to do." : "Done: \(made) file(s).")
        return 0
    }
}
