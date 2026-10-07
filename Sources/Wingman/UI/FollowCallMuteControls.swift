#if !APP_STORE
import AppKit
import SwiftUI

/// The "follow my Teams/Zoom mute" switch with its Accessibility permission
/// and live status — shared by Settings and the welcome guide.
struct FollowCallMuteControls: View {
    @Bindable var monitor: CallMuteMonitor
    let permissions: Permissions
    var showsStatus = true

    var body: some View {
        Toggle("Mute Wingman when I mute in the Teams or Zoom app", isOn: $monitor.enabled)
            .onChange(of: monitor.enabled) { _, on in
                // Switching it on is the opt-in: ask macOS right away rather than
                // leave it on but unable to work until "Allow…" is also clicked.
                if on, permissions.accessibility != .granted, permissions.accessibility != .waiting {
                    Task { await permissions.requestAccessibility() }
                }
            }
        if monitor.enabled {
            if permissions.accessibility == .granted {
                if showsStatus {
                    LabeledContent("Status") { Text(monitor.status.description).foregroundStyle(.secondary) }
                }
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(permissions.accessibility == .waiting
                             ? "Waiting for Accessibility permission…"
                             : "Needs Accessibility permission to read Teams' and Zoom's mute button.")
                            .foregroundStyle(.secondary)
                        Text("If Wingman is already listed and switched on there but this still shows, select it, remove it with −, then click Allow… again — an entry left over from an older copy of the app doesn't count.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Allow…") { Task { await permissions.requestAccessibility() } }
                    Button("Open Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            }
        }
    }
}
/// Recognizing Google Meet reads Chrome's tab titles, which needs Accessibility;
/// without it Meet calls count as browser calls. Shown while Meet isn't Off.
struct MeetAccessibilityHint: View {
    let watcher: CallWatcher
    let permissions: Permissions

    var body: some View {
        if watcher.policy(for: .meet) != .off, permissions.accessibility != .granted {
            HStack {
                Text(permissions.accessibility == .waiting
                     ? "Waiting for Accessibility permission…"
                     : "Wingman needs Accessibility to tell a Google Meet call from other browser use. Until then, Meet calls count as browser calls.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Allow…") { Task { await permissions.requestAccessibility() } }
            }
        }
    }
}
#endif
