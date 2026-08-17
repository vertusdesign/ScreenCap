import AVFoundation
import Foundation

enum PlayerTrackKind: String, CaseIterable, Codable, Identifiable {
    case video
    case compositeAudio
    case microphone
    case systemAudio

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .video: return "film"
        case .compositeAudio: return "waveform"
        case .microphone: return "mic"
        case .systemAudio: return "speaker.wave.2"
        }
    }

    var fallbackTitle: String {
        switch self {
        case .video: return "Video"
        case .compositeAudio: return "Composite Audio"
        case .microphone: return "Microphone"
        case .systemAudio: return "System Audio"
        }
    }

    var isAudio: Bool { self != .video }
    var isDerived: Bool { self == .compositeAudio }
}

enum PlayerLibrarySourceKind: String, Codable {
    case video
    case folder
}

struct PlayerLibrarySource: Codable, Identifiable, Equatable {
    let id: UUID
    let kind: PlayerLibrarySourceKind
    let displayName: String
    var url: URL
    var bookmarkData: Data?

    init(url: URL, kind: PlayerLibrarySourceKind) {
        self.id = UUID()
        self.kind = kind
        self.displayName = url.deletingPathExtension().lastPathComponent
        self.url = url
        self.bookmarkData = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    var resolvedURL: URL {
        guard let bookmarkData else { return url }
        var stale = false
        guard let resolved = try? URL(
                  resolvingBookmarkData: bookmarkData,
                  options: [.withSecurityScope, .withoutUI],
                  relativeTo: nil,
                  bookmarkDataIsStale: &stale
              )
        else { return url }
        return resolved
    }
}

struct PlayerRecording: Identifiable, Hashable {
    let id: String
    let url: URL
    let displayName: String
    let folderName: String
    let sourceID: UUID
    let sourceKind: PlayerLibrarySourceKind

    init(url: URL, source: PlayerLibrarySource) {
        self.url = url
        self.id = url.standardizedFileURL.path
        self.displayName = url.deletingPathExtension().lastPathComponent
        self.folderName = source.kind == .folder
            ? source.displayName
            : url.deletingLastPathComponent().lastPathComponent
        self.sourceID = source.id
        self.sourceKind = source.kind
    }
}

struct PlayerTrackDescriptor: Identifiable, Equatable {
    let kind: PlayerTrackKind
    let title: String
    let subtitle: String?
    let index: Int?
    var isMuted: Bool
    var isRemoved: Bool
    var volume: Double

    init(
        kind: PlayerTrackKind,
        title: String,
        subtitle: String?,
        index: Int?,
        isMuted: Bool,
        isRemoved: Bool,
        volume: Double = 1
    ) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.index = index
        self.isMuted = isMuted
        self.isRemoved = isRemoved
        self.volume = volume
    }

    var id: String { kind.rawValue }
    var symbolName: String { kind.symbolName }

    static func gainText(for volume: Double) -> String {
        guard volume > 0.001 else { return "−∞" }
        let decibels = 20 * log10(volume)
        if abs(decibels) < 0.05 { return "0 dB" }
        return String(format: "%+.1f dB", decibels)
    }
}

struct PlayerMediaInfo {
    let duration: Double
    let naturalSize: CGSize
    let videoTrackCount: Int
    let audioTrackCount: Int
}

struct PlayerEditSnapshot: Equatable {
    let trimStart: Double
    let trimEnd: Double
    let mutedTracks: Set<PlayerTrackKind>
    let removedTracks: Set<PlayerTrackKind>
    let volumes: [PlayerTrackKind: Double]
    let compositeRebuildRequested: Bool
}

enum PlayerTranscriptionMode: String, CaseIterable, Codable, Identifiable {
    case off
    case onDemand
    case automatic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .onDemand: return "On demand"
        case .automatic: return "Automatic"
        }
    }
}
