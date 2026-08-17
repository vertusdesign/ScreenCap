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
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var text = ""
    @Published private(set) var localeIdentifier: String = Locale.current.identifier

    private var recognitionTask: SFSpeechRecognitionTask?
    private var temporaryAudioURL: URL?

    deinit {
        recognitionTask?.cancel()
        if let temporaryAudioURL { try? FileManager.default.removeItem(at: temporaryAudioURL) }
    }

    func transcribe(url: URL, locale: Locale = .current) {
        recognitionTask?.cancel()
        cleanupTemporaryAudio()
        text = ""
        localeIdentifier = locale.identifier
        state = .requestingPermission

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.requestSpeechAuthorization()
                state = .extractingAudio
                let audioURL = try await self.extractAudio(from: url)
                temporaryAudioURL = audioURL
                state = .transcribing
                try await self.runRecognition(audioURL: audioURL, locale: locale)
            } catch {
                state = .failed(error.localizedDescription)
                cleanupTemporaryAudio()
            }
        }
    }

    func cancel() {
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
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        // Apple Speech exposes this switch on macOS. We deliberately require the
        // on-device path instead of silently uploading recordings to a service.
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    if let result {
                        self?.text = result.bestTranscription.formattedString
                    }
                    if let error {
                        self?.recognitionTask = nil
                        continuation.resume(throwing: error)
                    } else if result?.isFinal == true {
                        self?.recognitionTask = nil
                        self?.state = .finished
                        self?.cleanupTemporaryAudio()
                        continuation.resume()
                    }
                }
            }
        }
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
    case audioExtractionUnavailable
    case audioExtractionFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Speech Recognition permission was not granted."
        case .recognizerUnavailable:
            return "On-device speech recognition is unavailable for this language on this Mac."
        case .audioExtractionUnavailable:
            return "The recording does not contain an audio stream that can be transcribed."
        case .audioExtractionFailed:
            return "Audio could not be prepared for transcription."
        case .cancelled:
            return "Transcription was cancelled."
        }
    }
}
