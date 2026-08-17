import AppKit

/// Owns the user-facing handoff after an interrupted recording is recovered.
/// Recovery is intentionally local and reversible: closing the alert keeps the
/// movie, Open and Show in Finder leave it untouched, and Discard requires a
/// second confirmation before deleting the recovered copy.
@available(macOS 15.0, *)
@MainActor
final class RecorderRecoveryCoordinator {
    static let shared = RecorderRecoveryCoordinator()

    private var pending: [RecorderRecoveredRecording] = []
    private var isPresenting = false

    private init() {}

    func recoverAtLaunch() {
        Task { @MainActor [weak self] in
            let recovered = await RecorderRecovery.recoverStaleRecordings(
                in: RecorderRecovery.knownDirectories()
            )
            guard !recovered.isEmpty else { return }
            self?.enqueue(recovered, delay: 0.6)
        }
    }

    func scanAndPresent() {
        Task { @MainActor [weak self] in
            let recovered = await RecorderRecovery.recoverStaleRecordings(
                in: RecorderRecovery.knownDirectories()
            )
            guard let self else { return }
            guard !recovered.isEmpty else {
                Feedback.flash(message: L10n.t("recording.recovery.none"))
                return
            }
            enqueue(recovered)
        }
    }

    private func enqueue(_ recovered: [RecorderRecoveredRecording], delay: TimeInterval = 0) {
        pending.append(contentsOf: recovered)
        guard !isPresenting else { return }
        isPresenting = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.presentNext()
        }
    }

    private func presentNext() {
        guard let recording = pending.first else {
            isPresenting = false
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t("recording.recovery.title")
        alert.informativeText = L10n.t(
            "recording.recovery.message",
            recording.url.lastPathComponent,
            Self.formatDuration(recording.duration)
        )
        alert.addButton(withTitle: L10n.t("recording.recovery.open"))
        alert.addButton(withTitle: L10n.t("recording.recovery.showInFinder"))
        alert.addButton(withTitle: L10n.t("recording.recovery.discard"))

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        pending.removeFirst()
        switch response {
        case .alertFirstButtonReturn:
            PlayerWindowController.shared.show(url: recording.url)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting([recording.url])
        case .alertThirdButtonReturn:
            confirmDiscard(recording)
        default:
            break
        }

        DispatchQueue.main.async { [weak self] in
            self?.presentNext()
        }
    }

    private func confirmDiscard(_ recording: RecorderRecoveredRecording) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t("recording.recovery.discard.title")
        alert.informativeText = L10n.t(
            "recording.recovery.discard.message",
            recording.url.lastPathComponent
        )
        alert.addButton(withTitle: L10n.t("recording.recovery.discard.confirm"))
        alert.addButton(withTitle: L10n.t("action.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try FileManager.default.removeItem(at: recording.url)
            RecorderRecovery.markDiscarded(recording)
            PlayerLibraryStore.shared.reload()
        } catch {
            Feedback.flash(message: L10n.t("recording.recovery.discard.failed"))
            Log.error("could not discard recovered recording: \(error.localizedDescription)")
        }
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }
}
