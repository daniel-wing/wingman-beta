import Foundation
import Observation
import ServiceManagement

/// "Open Wingman at login", through macOS's own login items (System Settings
/// → General → Login Items). What's shown is always macOS's current answer,
/// never a remembered toggle: the user can switch it off there, and moving the
/// app changes it too.
@MainActor
@Observable
final class LoginItem {
    private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    private(set) var problem: String?

    var isOn: Bool { status == .enabled || status == .requiresApproval }
    var waitingForApproval: Bool { status == .requiresApproval }

    func refresh() { status = SMAppService.mainApp.status }

    func set(_ on: Bool) {
        problem = nil
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.write(on ? "open at login: on" : "open at login: off")
        } catch {
            Log.write("couldn't change open at login: \(Log.describe(error))")
            problem = "macOS didn't accept the change (\(error.localizedDescription))."
        }
        refresh()
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
