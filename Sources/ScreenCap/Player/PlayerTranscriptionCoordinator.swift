import AVFoundation
import Combine
import Foundation
import Speech

@MainActor
final class PlayerTranscriptionCoordinator: ObservableObject {
    enum State: Equatable {
        case idle
        case requestingPermission
        case extractingAudio
        case transcribing
        case finished
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .requestingPermission, .extractingAudio, .transcribing: return true
            default: return false
            }
        }

        var progressMessage: String? {
            switch self {
            case .requestingPermission: return L10n.t("player.transcript.requestingPermission")
            case .extractingAudio: return L10n.t("player.transcript.extractingAudio")
            case .transcribing: return L10n.t("player.transcript.transcribing")
            default: return nil
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var text = ""
    @Published private(set) var localeIdentifier: String = Locale.current.identifier

    private var recognitionTask: SFSpeechRecognitionTask?
    private var temporaryAudioURL: URL?
    private var operationID = UUID()

    deinit {
        recognitionTask?.cancel()
        if let temporaryAudioURL { try? FileManager.default.removeItem(at: temporaryAudioURL) }
    }

    func transcribe(url: URL, locale: Locale = .current) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            let error = TranscriptionError.recordingUnavailable
            state = .failed(error.localizedDescription)
            Feedback.flash(
                message: L10n.t("player.transcript.failed"),
                subtitle: error.localizedDescription
            )
            return
        }

        let currentOperationID = UUID()
        operationID = currentOperationID
        recognitionTask?.cancel()
        cleanupTemporaryAudio()
        text = ""
        localeIdentifier = locale.identifier
        state = .requestingPermission
        Feedback.flash(message: L10n.t("player.transcript.started"))

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.requestSpeechAuthorization()
                guard self.operationID == currentOperationID else { return }
                state = .extractingAudio
                let audioURL = try await self.extractAudio(from: url)
                guard self.operationID == currentOperationID else {
                    try? FileManager.default.removeItem(at: audioURL)
                    return
                }
                temporaryAudioURL = audioURL
                state = .transcribing
                try await self.runRecognition(audioURL: audioURL, locale: locale)
                guard self.operationID == currentOperationID else { return }
            } catch {
                guard self.operationID == currentOperationID else { return }
                state = .failed(error.localizedDescription)
                cleanupTemporaryAudio()
                Feedback.flash(
                    message: L10n.t("player.transcript.failed"),
                    subtitle: error.localizedDescription
                )
            }
        }
    }

    func cancel() {
        operationID = UUID()
        recognitionTask?.cancel()
        recognitionTask = nil
        cleanupTemporaryAudio()
        state = .idle
    }

    private func requestSpeechAuthorization() async throws {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current == .authorized { return }
        guard current == .notDetermined else { throw TranscriptionError.permissionDenied }

        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw TranscriptionError.permissionDenied }
    }

    private func extractAudio(from url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.load(.tracks)
        guard tracks.contains(where: { $0.mediaType == .audio }) else {
            throw TranscriptionError.audioExtractionUnavailable
        }
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionError.audioExtractionUnavailable
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("screencap-transcription-\(UUID().uuidString).m4a")
        exporter.outputURL = destination
        exporter.outputFileType = .m4a
        exporter.shouldOptimizeForNetworkUse = false

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exporter.exportAsynchronously {
                switch exporter.status {
                case .completed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: TranscriptionError.cancelled)
                default:
                    continuation.resume(throwing: exporter.error ?? TranscriptionError.audioExtractionFailed)
                }
            }
        }
        return destination
    }

    private func runRecognition(audioURL: URL, locale: Locale) async throws {
        guard let supportedLocale = Self.bestSupportedLocale(for: locale),
              let recognizer = SFSpeechRecognizer(locale: supportedLocale),
              recognizer.isAvailable
        else {
            throw TranscriptionError.recognizerUnavailable
        }
        localeIdentifier = supportedLocale.identifier
        guard recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.onDeviceRecognitionUnavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        // Apple Speech exposes this switch on macOS. We deliberately require the
        // on-device path instead of silently uploading recordings to a service.
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var didFinish = false
            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    if let result {
                        self?.text = result.bestTranscription.formattedString
                    }
                    guard !didFinish else { return }
                    if let error {
                        didFinish = true
                        self?.recognitionTask = nil
                        continuation.resume(throwing: error)
                    } else if result?.isFinal == true {
                        didFinish = true
                        self?.recognitionTask = nil
                        self?.state = .finished
                        self?.cleanupTemporaryAudio()
                        Feedback.flash(message: L10n.t("player.transcript.finished"))
                        continuation.resume()
                    }
                }
            }
        }
    }

    private static func bestSupportedLocale(for requested: Locale) -> Locale? {
        let supported = SFSpeechRecognizer.supportedLocales()
        if let exact = supported.first(where: { $0.identifier == requested.identifier }) {
            return exact
        }
        guard let language = requested.language.languageCode?.identifier else { return nil }
        return supported.first(where: { $0.language.languageCode?.identifier == language })
    }

    private func cleanupTemporaryAudio() {
        if let temporaryAudioURL {
            try? FileManager.default.removeItem(at: temporaryAudioURL)
        }
        temporaryAudioURL = nil
    }
}

enum TranscriptionError: LocalizedError {
    case permissionDenied
    case recognizerUnavailable
    case onDeviceRecognitionUnavailable
    case audioExtractionUnavailable
    case audioExtractionFailed
    case recordingUnavailable
    case cancelled

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Speech Recognition permission was not granted."
        case .recognizerUnavailable:
            return "On-device speech recognition is unavailable for this language on this Mac."
        case .onDeviceRecognitionUnavailable:
            return "This language is not available for on-device speech recognition on this Mac."
        case .audioExtractionUnavailable:
            return "The recording does not contain an audio stream that can be transcribed."
        case .audioExtractionFailed:
            return "Audio could not be prepared for transcription."
        case .recordingUnavailable:
            return "The selected recording is no longer available."
        case .cancelled:
            return "Transcription was cancelled."
        }
    }
}
