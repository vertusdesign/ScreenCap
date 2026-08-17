import AppKit
@preconcurrency import UserNotifications

/// Local, privacy-preserving system notifications for terminal recording
/// results. Progress remains in the in-app HUD; this coordinator is deliberately
/// limited to outcomes that may matter after the user has switched away from
/// ScreenCap.
@MainActor
final class SystemNotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let shared = SystemNotificationCoordinator()

    private enum Category {
        static let recordingResult = "recording-result"
        static let open = "recording-result.open"
        static let showInFinder = "recording-result.showInFinder"
    }

    private enum Storage {
        static let pathPrefix = "systemNotification.recording.path."
        static let ids = "systemNotification.recording.ids"
        static let maximumStoredTargets = 20
    }

    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard

    private override init() {
        super.init()
    }

    /// Configure the delegate before the first notification. Authorization is
    /// not requested here: asking only when a terminal result is eligible
    /// avoids a surprising permission prompt on a fresh launch.
    func configure() {
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Category.recordingResult,
                actions: [
                    UNNotificationAction(
                        identifier: Category.open,
                        title: L10n.t("notification.action.open"),
                        options: [.foreground]
                    ),
                    UNNotificationAction(
                        identifier: Category.showInFinder,
                        title: L10n.t("notification.action.showInFinder"),
                        options: [.foreground]
                    )
                ],
                intentIdentifiers: [],
                options: []
            )
        ])
    }

    func postRecordingResult(
        url: URL,
        warning: Bool,
        recovered: Bool,
        destinationWasOpened: Bool
    ) {
        let important = warning || recovered
        // A normal success is useful as a system notification only when the
        // user has moved to another app and no configured after-capture action
        // already opened a destination. Warnings/recoveries remain visible.
        guard important || (!destinationWasOpened && !NSApp.isActive) else { return }

        let targetID = storeTarget(url)
        let titleKey: String
        let bodyKey: String
        if recovered {
            titleKey = "notification.recording.recovered.title"
            bodyKey = "notification.recording.recovered.body"
        } else if warning {
            titleKey = "notification.recording.warning.title"
            bodyKey = "notification.recording.warning.body"
        } else {
            titleKey = "notification.recording.saved.title"
            bodyKey = "notification.recording.saved.body"
        }

        deliver(
            title: L10n.t(titleKey),
            body: L10n.t(bodyKey, url.lastPathComponent),
            targetID: targetID
        )
    }

    func postRecordingFailure(reason _: String?) {
        // Keep diagnostic details in the in-app HUD/log only. Error strings
        // can contain a user-chosen folder or filename, which should not be
        // copied into a system notification body.
        deliver(
            title: L10n.t("notification.recording.failed.title"),
            body: L10n.t("notification.recording.failed.body"),
            targetID: nil
        )
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Warning/recovered/failure notifications are intentionally visible
        // even when the Player window is currently frontmost. Ordinary success
        // is filtered before scheduling, so this does not create HUD+banner
        // duplication for the common case.
        completionHandler([.banner])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        let targetID = response.notification.request.content.userInfo["recordingTargetID"] as? String
        // Tell UserNotifications that delivery is handled immediately. The
        // actual AppKit work is dispatched afterwards and never captures the
        // framework's completion handler across an actor boundary.
        completionHandler()
        Task { @MainActor [weak self] in
            self?.handleResponse(action: action, targetID: targetID)
        }
    }

    private func deliver(title: String, body: String, targetID: String?) {
        center.getNotificationSettings { [weak self] settings in
            let status = settings.authorizationStatus
            Task { @MainActor [weak self] in
                self?.schedule(
                    title: title,
                    body: body,
                    targetID: targetID,
                    authorizationStatus: status
                )
            }
        }
    }

    private func schedule(
        title: String,
        body: String,
        targetID: String?,
        authorizationStatus: UNAuthorizationStatus
    ) {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            add(
                makeRequest(title: title, body: body, targetID: targetID),
                targetID: targetID
            )
        case .notDetermined:
            center.requestAuthorization(options: [.alert]) { [weak self] granted, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard granted else {
                        if let targetID { self.removeTarget(targetID) }
                        return
                    }
                    self.add(
                        self.makeRequest(title: title, body: body, targetID: targetID),
                        targetID: targetID
                    )
                }
            }
        case .denied:
            // The in-app HUD remains the fallback when the user disabled
            // notifications in System Settings.
            if let targetID { removeTarget(targetID) }
        @unknown default:
            if let targetID { removeTarget(targetID) }
        }
    }

    private func makeRequest(title: String, body: String, targetID: String?) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = targetID == nil ? "" : Category.recordingResult
        content.threadIdentifier = "recording-results"
        if let targetID {
            content.userInfo = ["recordingTargetID": targetID]
        }

        return UNNotificationRequest(
            identifier: "recording-result-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
    }

    private func add(_ request: UNNotificationRequest, targetID: String?) {
        center.add(request) { [weak self] error in
            if let error {
                Log.error("system notification could not be scheduled: \(error.localizedDescription)")
                if let targetID {
                    Task { @MainActor [weak self] in
                        self?.removeTarget(targetID)
                    }
                }
            }
        }
    }

    private func handleResponse(action: String, targetID: String?) {
        // Failure notifications intentionally have no target or actions. A
        // default click only dismisses them; it must not claim that a file is
        // missing when no playable file ever existed.
        guard let targetID else { return }
        guard let path = defaults.string(forKey: Storage.pathPrefix + targetID) else {
            Feedback.flash(message: L10n.t("notification.recording.unavailable"))
            return
        }

        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            removeTarget(targetID)
            Feedback.flash(message: L10n.t("notification.recording.unavailable"))
            return
        }

        switch action {
        case Category.showInFinder:
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case Category.open, UNNotificationDefaultActionIdentifier:
            PlayerWindowController.shared.show(url: url)
        default:
            break
        }
        removeTarget(targetID)
    }

    private func storeTarget(_ url: URL) -> String {
        let id = UUID().uuidString
        defaults.set(url.path, forKey: Storage.pathPrefix + id)

        var ids = defaults.stringArray(forKey: Storage.ids) ?? []
        ids.append(id)
        if ids.count > Storage.maximumStoredTargets {
            let stale = ids.dropLast(Storage.maximumStoredTargets)
            for staleID in stale {
                defaults.removeObject(forKey: Storage.pathPrefix + staleID)
            }
            ids = Array(ids.suffix(Storage.maximumStoredTargets))
        }
        defaults.set(ids, forKey: Storage.ids)
        return id
    }

    private func removeTarget(_ id: String) {
        defaults.removeObject(forKey: Storage.pathPrefix + id)
        var ids = defaults.stringArray(forKey: Storage.ids) ?? []
        ids.removeAll { $0 == id }
        defaults.set(ids, forKey: Storage.ids)
    }
}
