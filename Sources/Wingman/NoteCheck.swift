import Foundation

/// `Wingman notecheck <note .md, or a folder of notes>…`: checks that Wingman can
/// read each note back exactly and rename its speakers without touching anything
/// else. Read-only: every rename is tried in memory and undone. Prints counts and
/// day folders, never note names (they're usually calendar titles).
enum NoteCheck {
    static func run(_ args: [String]) async -> Int32 {
        guard !args.isEmpty else {
            print("Usage: Wingman notecheck <meeting note .md, or a folder of notes>…")
            return 2
        }
        let fm = FileManager.default
        var notes: [URL] = []
        for arg in args {
            let url = URL(fileURLWithPath: (arg as NSString).expandingTildeInPath)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let items = (fm.enumerator(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)?.allObjects as? [URL]) ?? []
                notes += items.filter { $0.pathExtension == "md" }
            } else if url.pathExtension == "md" {
                notes.append(url)
            }
        }

        var readable = 0, lines = 0, speakers = 0, failures = 0, subtitles = 0, subtitleSkips = 0
        var readOnly: [String: Int] = [:]
        for (index, note) in notes.sorted(by: { $0.path < $1.path }).enumerated() {
            let place = "\(note.deletingLastPathComponent().lastPathComponent) #\(index + 1)"
            guard let data = try? Data(contentsOf: note) else {
                print("  \(place): couldn't be read")
                failures += 1
                continue
            }
            let parsed = MeetingNote.parse(data)
            guard parsed.data == data || parsed.readOnly == .tooLarge || parsed.readOnly == .notText else {
                print("  \(place): FAILED the round trip")
                failures += 1
                continue
            }
            if let reason = parsed.readOnly {
                readOnly[reason.reason, default: 0] += 1
                continue
            }
            readable += 1
            lines += parsed.lines.count
            speakers += parsed.speakers.count
            // Every speaker: rename to a test name and back, in memory.
            for speaker in parsed.speakers {
                do {
                    let there = try NoteRewriter.renameSpeaker(in: data, from: speaker, to: "Zz Check")
                    let back = try NoteRewriter.renameSpeaker(in: there, from: "Zz Check", to: speaker)
                    if back != data {
                        print("  \(place): renaming a speaker and back changed the note")
                        failures += 1
                    }
                } catch {
                    print("  \(place): renaming a speaker failed (\(error))")
                    failures += 1
                }
            }
            for format in SubtitleExport.Format.allCases {
                let file = note.deletingPathExtension().appendingPathExtension(format.rawValue)
                guard let subtitle = try? Data(contentsOf: file), let speaker = parsed.speakers.first else { continue }
                subtitles += 1
                do {
                    let there = try SubtitleRewriter.renameSpeaker(in: subtitle, format: format, note: parsed, from: speaker, to: "Zz Check")
                    let renamed = MeetingNote.parse(try NoteRewriter.renameSpeaker(in: data, from: speaker, to: "Zz Check"))
                    let back = try SubtitleRewriter.renameSpeaker(in: there, format: format, note: renamed, from: "Zz Check", to: speaker)
                    if back != subtitle {
                        print("  \(place): renaming in its .\(format.rawValue) and back changed it")
                        failures += 1
                    }
                } catch SubtitleRewriter.Failure.doesNotLineUp {
                    print("  \(place): its .\(format.rawValue) doesn't line up with the note (would be skipped)")
                    subtitleSkips += 1
                } catch {
                    print("  \(place): renaming in its .\(format.rawValue) failed (\(error))")
                    failures += 1
                }
            }
        }
        print("\(notes.count) notes: \(readable) can be renamed (\(lines) transcript lines, \(speakers) speakers), "
              + "\(readOnly.values.reduce(0, +)) read-only, \(failures) failures")
        for (reason, count) in readOnly.sorted(by: { $0.key < $1.key }) { print("  read-only, \(reason): \(count)") }
        print("subtitles: \(subtitles) checked, \(subtitleSkips) wouldn't be updated")
        return failures == 0 ? 0 : 1
    }
}
