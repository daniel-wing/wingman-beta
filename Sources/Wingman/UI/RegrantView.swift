import AppKit
import SwiftUI

/// Shown once, on the first launch after Wingman's signature changed (0.8's
/// own certificate → Apple Developer ID): macOS treats the new copy as a new
/// app for privacy, so the permissions given to the old one have to be given
/// again. Lists them all, with what each is for; never shown on a fresh install.
struct RegrantView: View {
    let permissions: Permissions
    let done: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Allow Wingman Again").font(.title.weight(.semibold))
                            Text("A one-time step after this update.").foregroundStyle(.secondary)
                        }
                    }
                    Text("This version of Wingman is signed with an Apple Developer ID and checked by Apple, so it opens without warnings. macOS treats it as a new app, so it needs the permissions you gave the previous version once more. Your notes, settings and the voices you named are unchanged.")
                        .fixedSize(horizontal: false, vertical: true)
                    PermissionRow(
                        icon: "speaker.wave.2", title: "System audio", required: true,
                        why: "To transcribe the other people on the call.",
                        state: permissions.systemAudio, settingsPane: "Privacy_ScreenCapture",
                        note: permissions.systemAudioNote
                    ) { await permissions.requestSystemAudio() }
                    PermissionRow(
                        icon: "mic", title: "Microphone", required: true,
                        why: "To transcribe what you say.",
                        state: permissions.microphone, settingsPane: "Privacy_Microphone"
                    ) { await permissions.requestMicrophone() }
                    PermissionRow(
                        icon: "calendar", title: "Calendar", required: false,
                        why: "To name meetings after your calendar events.",
                        state: permissions.calendar, settingsPane: "Privacy_Calendars"
                    ) { await permissions.requestCalendar() }
                    #if !APP_STORE
                    PermissionRow(
                        icon: "accessibility", title: "Accessibility", required: false,
                        why: "To follow your Teams or Zoom mute, and to start a new note when a new call begins right after another. If System Settings already shows Wingman switched on, that entry is the previous version: select it, click −, then click Allow here.",
                        state: permissions.accessibility, settingsPane: "Privacy_Accessibility"
                    ) { await permissions.requestAccessibility() }
                    accessibilityFallback
                    #endif
                }
                .padding(28)
            }
            Divider()
            HStack {
                Text("You can change these later in Settings.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { done() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 580, height: 600)
        .task { await permissions.refresh() }
    }

    #if !APP_STORE
    /// When removing the old entry by hand doesn't take: a command that clears
    /// Wingman's Accessibility entry (only Wingman's), to run yourself.
    private var accessibilityFallback: some View {
        let command = "tccutil reset Accessibility \(Bundle.main.bundleIdentifier ?? "local.wingman.app")"
        return VStack(alignment: .leading, spacing: 4) {
            Text("Still not working? Run this in Terminal, then click Allow again:")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Text(command).font(.callout.monospaced()).textSelection(.enabled)
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                }
                .controlSize(.small)
            }
        }
        .padding(.leading, 38)
    }
    #endif
}
