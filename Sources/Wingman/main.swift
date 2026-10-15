import AppKit
import Foundation

// `Wingman bakeoff <audio file> [--lang es-ES]` compares speech engines
// on a recording; `simulate` and `audiocheck` are diagnostics. With no
// arguments it starts the menu-bar app.
//
// The tools run with Wingman's permissions (microphone, system audio,
// calendar), so builds for other people leave them out: install.sh with
// RELEASE=1 or APP_STORE=1 passes NO_DIAGNOSTICS.
let arguments = Array(CommandLine.arguments.dropFirst())
#if !NO_DIAGNOSTICS && !APP_STORE
let allTools: [String: ([String]) async -> Int32] = [
    "bakeoff": BakeOff.run, "simulate": Simulate.run, "audiocheck": AudioCheck.run, "clip": Clip.run, "recordtest": RecordTest.run, "devicewatch": DeviceWatch.run, "mix": MixTool.run, "whosmic": WhosMic.run, "voicecompare": VoiceCompare.run, "transcribe": TranscribeTool.run, "calendarcheck": CalendarCheck.run, "langtest": LangTest.run,
    "axdump": AXDump.run, "reportdialog": ReportDialog.run, "notecheck": NoteCheck.run, "voicerecover": VoiceRecoverTool.run, "windowtree": WindowTree.run,
]
#else
let allTools: [String: ([String]) async -> Int32] = [:]
// A tool name would otherwise start a second copy of the app.
if let first = arguments.first, !first.hasPrefix("-") {
    print("Wingman's diagnostic tools aren't included in this build.")
    exit(2)
}
#endif
if arguments.first == "--recover-voices", arguments.count == 2 {
    // A voice search for an older meeting, started by the app (VoiceRecoveryRunner).
    Task { exit(await VoiceRecovery.runJob(arguments[1])) }
    dispatchMain()
} else if let first = arguments.first, let tool = allTools[first] {
    setvbuf(stdout, nil, _IOLBF, 0)  // line-buffered, so progress shows up in logs right away
    Task { @MainActor in
        exit(await tool(Array(arguments.dropFirst())))
    }
    dispatchMain()
} else {
    // One Wingman at a time: a second copy (opened again, or another install)
    // would record the same calls and write the same files. It brings the
    // running one forward instead.
    if let id = Bundle.main.bundleIdentifier,
       let running = NSRunningApplication.runningApplications(withBundleIdentifier: id)
        .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }) {
        running.activate()
        exit(0)
    }
    WingmanApp.main()
}
