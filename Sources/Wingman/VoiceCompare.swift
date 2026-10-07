import Foundation

/// `Wingman voicecompare <a.wav> <b.wav> [name1,name2,…] [--invited name,…]`
/// separates the voices in two recordings and prints their similarity. With
/// names, it learns A's voices under those names (in a temporary library) and
/// shows who would be recognized in B — the same steps the app takes.
enum VoiceCompare {
    @MainActor
    static func run(_ args: [String]) async -> Int32 {
        let files = args.filter { $0.hasSuffix(".wav") }
        guard files.count == 2 else {
            print("Usage: Wingman voicecompare <a.wav> <b.wav> [name1,name2,…] [--invited name,…]")
            return 2
        }
        let names = args.first { !$0.hasSuffix(".wav") && !$0.hasPrefix("--") && args.firstIndex(of: $0).map { $0 == 0 || args[$0 - 1] != "--invited" } == true }?
            .split(separator: ",").map(String.init) ?? []
        let invited = args.firstIndex(of: "--invited").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }?
            .split(separator: ",").map(String.init) ?? []
        do {
            let separation = SpeakerSeparation()
            let a = try await separation.separate(URL(fileURLWithPath: files[0]))
            let b = try await separation.separate(URL(fileURLWithPath: files[1]))
            let orderA = SpeakerSeparation.speakerOrder(a.turns), orderB = SpeakerSeparation.speakerOrder(b.turns)
            print("        " + orderB.indices.map { String(format: "B%-6d", $0 + 1) }.joined())
            for (i, idA) in orderA.enumerated() {
                let row = orderB.map { idB -> String in
                    guard let va = a.voiceprints[idA], let vb = b.voiceprints[idB] else { return "  —    " }
                    return String(format: "%6.3f ", VoiceLibrary.similarity(va, vb))
                }
                print(String(format: "A%-6d ", i + 1) + row.joined())
            }
            guard !names.isEmpty else { return 0 }

            let file = FileManager.default.temporaryDirectory.appendingPathComponent("wingman-voices-test-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: file) }
            let library = VoiceLibrary(file: file)
            for (name, id) in zip(names, orderA) {
                if let print = a.voiceprints[id] { library.learn(name, voiceprint: print) }
            }
            print("\nLearned from A: \(library.people.map(\.name).joined(separator: ", "))")
            var voicesB: [String: [Float]] = [:]
            for (i, id) in orderB.enumerated() { voicesB["B\(i + 1)"] = b.voiceprints[id] }
            let matches = library.match(voicesB, invitees: invited)
            for label in voicesB.keys.sorted() {
                if let m = matches[label] {
                    print("\(label) → \(m.confident ? m.name : "\(m.name)?") (similarity \(String(format: "%.2f", m.similarity)))")
                } else {
                    print("\(label) → not recognized")
                }
            }
            return 0
        } catch {
            print("Failed: \(error.localizedDescription)")
            return 1
        }
    }
}
