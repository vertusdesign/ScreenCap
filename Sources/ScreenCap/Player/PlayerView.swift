import AVKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PlayerView: View {
    @ObservedObject var viewModel: PlayerViewModel
    @State private var pendingRecording: PlayerRecording?
    @State private var showTranscript = false
    @State private var showReplaceConfirmation = false

    var body: some View {
        HSplitView {
            librarySidebar
                .frame(minWidth: 245, idealWidth: 280, maxWidth: 360)
            playerStage
                .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1050, minHeight: 680)
        .alert(
            L10n.t("player.track.remove.confirm.title"),
            isPresented: Binding(
                get: { viewModel.pendingTrackRemoval != nil },
                set: { if !$0 { viewModel.cancelRemoveTrack() } }
            )
        ) {
            Button(L10n.t("action.remove"), role: .destructive) { viewModel.confirmRemoveTrack() }
            Button(L10n.t("action.cancel"), role: .cancel) { viewModel.cancelRemoveTrack() }
        } message: {
            Text(viewModel.removingLastAudioTrack
                ? L10n.t("player.track.remove.confirm.message.lastAudio")
                : L10n.t("player.track.remove.confirm.message"))
        }
        .alert(
            L10n.t("player.unsaved.title"),
            isPresented: Binding(
                get: { pendingRecording != nil },
                set: { if !$0 { pendingRecording = nil } }
            )
        ) {
            Button(L10n.t("player.unsaved.saveCopy")) {
                viewModel.exportEditedCopy()
                if let pendingRecording { viewModel.select(pendingRecording) }
                pendingRecording = nil
            }
            Button(L10n.t("player.unsaved.discard"), role: .destructive) {
                if let pendingRecording { viewModel.select(pendingRecording) }
                pendingRecording = nil
            }
            Button(L10n.t("action.cancel"), role: .cancel) { pendingRecording = nil }
        } message: {
            Text(L10n.t("player.unsaved.message"))
        }
        .confirmationDialog(
            L10n.t("player.export.replace.title"),
            isPresented: $showReplaceConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.t("player.export.replace.confirm"), role: .destructive) {
                viewModel.replaceOriginal()
            }
            Button(L10n.t("action.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.t("player.export.replace.message"))
        }
    }

    private var librarySidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L10n.t("player.library"), systemImage: "rectangle.stack")
                    .font(.headline)
                Spacer()
                Menu {
                    Button(L10n.t("player.add.video"), systemImage: "film") { addVideo() }
                    Button(L10n.t("player.add.folder"), systemImage: "folder") { addFolder() }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .help(L10n.t("player.add"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()
            if viewModel.library.groupedRecordings.isEmpty {
                ContentUnavailableView(
                    L10n.t("player.library.empty.title"),
                    systemImage: "film.stack",
                    description: Text(L10n.t("player.library.empty.message"))
                )
                .padding(16)
            } else {
                List {
                    ForEach(viewModel.library.groupedRecordings, id: \.source.id) { group in
                        Section {
                            ForEach(group.recordings) { recording in
                                recordingRow(recording)
                            }
                        } header: {
                            HStack(spacing: 5) {
                                Image(systemName: group.source.kind == .folder ? "folder" : "film")
                                Text(group.source.displayName)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(group.recordings.count)")
                                    .foregroundStyle(.secondary)
                            }
                            .contextMenu {
                                Button(L10n.t("player.remove.folder"), role: .destructive) {
                                    viewModel.library.removeSource(group.source)
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .background(.regularMaterial)
    }

    private func recordingRow(_ recording: PlayerRecording) -> some View {
        Button {
            select(recording)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "film")
                    .foregroundStyle(.secondary)
                Text(recording.displayName)
                    .lineLimit(1)
                if viewModel.selectedRecording?.id == recording.id && viewModel.isDirty {
                    Circle().fill(.orange).frame(width: 6, height: 6)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(L10n.t("player.remove.video"), role: .destructive) {
                if viewModel.selectedRecording?.id == recording.id { viewModel.engine.pause() }
                viewModel.library.removeRecording(recording)
            }
            Button(L10n.t("player.reveal")) {
                NSWorkspace.shared.activateFileViewerSelecting([recording.url])
            }
        }
    }

    private var playerStage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { viewModel.engine.playPause() } label: {
                    Image(systemName: viewModel.engine.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 18)
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.selectedRecording == nil)
                Text(viewModel.selectedRecording?.displayName ?? L10n.t("player.noSelection"))
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Picker("", selection: $viewModel.transcriptionMode) {
                    ForEach(PlayerTranscriptionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
                .help(L10n.t("player.transcription.mode.help"))
                Button {
                    showTranscript.toggle()
                } label: {
                    Label(L10n.t("player.transcript"), systemImage: "text.quote")
                }
                .buttonStyle(.borderless)
                Menu {
                    Button(L10n.t("player.export.copy"), systemImage: "doc.on.doc") {
                        viewModel.exportEditedCopy()
                    }
                    Button(L10n.t("player.export.replace"), systemImage: "arrow.triangle.2.circlepath") {
                        showReplaceConfirmation = true
                    }
                    .disabled(viewModel.selectedRecording == nil || !viewModel.isDirty)
                } label: {
                    Label(L10n.t("player.export"), systemImage: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                Button {
                    viewModel.isTrackEditorVisible.toggle()
                } label: {
                    Image(systemName: viewModel.isTrackEditorVisible ? "rectangle.bottomhalf.inset.filled" : "rectangle.bottomhalf.inset.filled")
                }
                .buttonStyle(.borderless)
                .help(L10n.t("player.track.toggle"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()
            if showTranscript {
                TranscriptPanel(
                    mode: viewModel.transcriptionMode,
                    coordinator: viewModel.transcription,
                    onStart: { viewModel.transcribeSelected() }
                )
                    .frame(height: 104)
            }

            ZStack(alignment: .bottom) {
                if viewModel.selectedRecording == nil {
                    ContentUnavailableView(
                        L10n.t("player.noSelection"),
                        systemImage: "play.rectangle",
                        description: Text(L10n.t("player.noSelection.message"))
                    )
                } else {
                    PlayerVideoSurface(player: viewModel.engine.player)
                        .background(Color.black)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !viewModel.isTrackEditorVisible {
                HStack(spacing: 10) {
                    Text(viewModel.currentTimeText).monospacedDigit().font(.caption)
                    Slider(value: Binding(
                        get: { viewModel.progress },
                        set: { viewModel.seek(to: $0) }
                    ), in: 0...1)
                    Text(viewModel.durationText).monospacedDigit().font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }

            if viewModel.isTrackEditorVisible {
                TrackEditorView(viewModel: viewModel)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func select(_ recording: PlayerRecording) {
        guard viewModel.selectedRecording?.id != recording.id else { return }
        if viewModel.isDirty {
            pendingRecording = recording
        } else {
            viewModel.select(recording)
        }
    }

    private func addVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .quickTimeMovie, .mpeg4Movie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            panel.urls.compactMap { viewModel.library.addVideo(url: $0) }.last.map(viewModel.select)
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            _ = viewModel.library.addFolder(url: url)
        }
    }
}

private struct PlayerVideoSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.player = player
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

private struct TranscriptPanel: View {
    let mode: PlayerTranscriptionMode
    @ObservedObject var coordinator: PlayerTranscriptionCoordinator
    let onStart: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.green)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("player.transcript.title"))
                    .font(.subheadline.weight(.semibold))
                if !coordinator.text.isEmpty {
                    Text(coordinator.text)
                        .font(.caption)
                        .lineLimit(3)
                } else {
                    Text(mode == .automatic
                         ? L10n.t("player.transcript.automatic.message")
                         : L10n.t("player.transcript.ondemand.message"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if case .failed(let message) = coordinator.state {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                if let progressMessage = coordinator.state.progressMessage {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text(progressMessage)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if mode != .off {
                Button(coordinator.state.isBusy ? L10n.t("action.cancel") : L10n.t("player.transcript.start")) {
                    if coordinator.state.isBusy {
                        coordinator.cancel()
                    } else {
                        onStart()
                    }
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(.thinMaterial)
    }
}
