import Foundation
import UserNotifications

/// Wingman's notifications: asking whether to record a detected call, and
/// telling you when a call is being recorded, with buttons to act on both.
/// Each one carries the call or recording it's about, so a late click can't
/// act on a different one; clicking a banner itself only opens Wingman.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    enum Action: String {
        case record, ignore, stop, discard
        /// The banner itself was clicked: show the question or recording in the window.
        case open
    }

    private static let askCategory = "CALL_DETECTED"
    private static let recordingCategory = "RECORDING"
    private static let askPrefix = "wingman.ask."
    private static let recordingID = "wingman.recording"
    private static let warningID = "wingman.warning"
    /// userInfo key for the call session or recording a notification is about.
    nonisolated private static let subjectKey = "subject"

    private let center = UNUserNotificationCenter.current()
    /// The action, and the call session (ask) or recording (recording) it's for.
    var onAction: ((Action, UUID?) -> Void)?
    /// Questions posted and not yet withdrawn.
    private var askIDs: Set<String> = []

    override init() {
        super.init()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.askCategory,
                actions: [
                    UNNotificationAction(identifier: Action.record.rawValue, title: "Record", options: []),
                    UNNotificationAction(identifier: Action.ignore.rawValue, title: "Ignore", options: []),
                ],
                intentIdentifiers: []),
            UNNotificationCategory(
                identifier: Self.recordingCategory,
                actions: [
                    UNNotificationAction(identifier: Action.stop.rawValue, title: "Stop", options: []),
                    UNNotificationAction(identifier: Action.discard.rawValue, title: "Stop & Discard", options: [.destructive]),
                ],
                intentIdentifiers: []),
        ])
    }

    var isAuthorized: Bool {
        get async { await center.notificationSettings().authorizationStatus == .authorized }
    }

    var hasBeenAsked: Bool {
        get async { await center.notificationSettings().authorizationStatus != .notDetermined }
    }

    @discardableResult
    func requestAccess() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func askToRecord(_ session: CallSession, meeting: String?) {
        let content = UNMutableNotificationContent()
        content.title = "\(session.app.callTitle) detected"
        content.body = meeting.map { "Record \"\($0)\"?" } ?? "Record and transcribe this call?"
        #if !APP_STORE
        // Weak Meet evidence: say it's a guess.
        if session.isUnsureMeet {
            content.title = "Google Meet call?"
            if meeting == nil { content.body = "Looks like a Google Meet call. Record and transcribe it?" }
        }
        #endif
        content.categoryIdentifier = Self.askCategory
        content.sound = .default
        content.userInfo = [Self.subjectKey: session.id.uuidString]
        let id = Self.askPrefix + session.id.uuidString
        askIDs.insert(id)
        post(id, content)
    }

    func announceRecording(_ app: CallApp?, meeting: String?, recording: UUID) {
        withdrawAsk()
        let content = UNMutableNotificationContent()
        content.title = "Wingman is recording"
        if let app {
            let what = "your \(app.shortName) call"
            content.body = meeting.map { "\"\($0)\" — \(what). It stops when the call ends." } ?? "Recording \(what). It stops when the call ends."
        } else {
            content.body = meeting.map { "\"\($0)\". Stop it here or from the menu bar when you're done." }
                ?? "Stop it here or from the menu bar when you're done."
        }
        content.categoryIdentifier = Self.recordingCategory
        content.userInfo = [Self.subjectKey: recording.uuidString]
        post(Self.recordingID, content)
    }

    func announceSaved(_ name: String, warning: String? = nil) {
        withdrawRecording()
        let content = UNMutableNotificationContent()
        content.title = "Meeting saved"
        content.body = warning.map { "\(name) — \($0)" } ?? name
        post("wingman.saved.\(UUID().uuidString)", content)
    }

    /// The note couldn't be written: the transcript is still in the window.
    func announceNotSaved() {
        withdrawRecording()
        let content = UNMutableNotificationContent()
        content.title = "The meeting wasn't saved"
        content.body = "Wingman couldn't write the note. Open Wingman to save the transcript somewhere else."
        content.sound = .default
        post("wingman.notsaved.\(UUID().uuidString)", content)
    }

    /// A problem worth knowing about during a call, e.g. mute not being followed.
    func warn(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        post(Self.warningID, content)
    }

    func withdrawWarning() {
        center.removeDeliveredNotifications(withIdentifiers: [Self.warningID])
    }

    /// Withdraws the question about one call, or all of them.
    func withdrawAsk(_ session: UUID? = nil) {
        let ids = session.map { [Self.askPrefix + $0.uuidString] } ?? Array(askIDs)
        guard !ids.isEmpty else { return }
        askIDs.subtract(ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    func withdrawRecording() {
        center.removeDeliveredNotifications(withIdentifiers: [Self.recordingID])
    }

    private func post(_ id: String, _ content: UNNotificationContent) {
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // Show banners even while a Wingman window is in front.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let id = response.actionIdentifier
        let subject = (response.notification.request.content.userInfo[Self.subjectKey] as? String).flatMap(UUID.init)
        await MainActor.run {
            if let action = Action(rawValue: id), action != .open {
                onAction?(action, subject)
            } else if id == UNNotificationDefaultActionIdentifier {
                // Clicking a banner only opens Wingman: recording needs the Record button.
                onAction?(.open, subject)
            }
        }
    }
}
