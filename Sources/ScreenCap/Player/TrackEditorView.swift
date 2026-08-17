import SwiftUI

struct TrackEditorView: View {
    @ObservedObject var viewModel: PlayerViewModel
    @State private var thumbnails: [NSImage] = []

    private let labelWidth: CGFloat = 230
    private let timelineWidth: CGFloat = 880

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // The timeline can be taller than the compact window (for example
            // when a recording has many audio tracks). Scroll vertically
            // inside the editor instead of allowing its bottom controls to be
            // clipped by the window edge.
            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 0) {
                            Text(L10n.t("player.track.header"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: labelWidth, alignment: .leading)
                            TimelineRuler(duration: viewModel.duration, width: timelineWidth)
                        }
                        ForEach(viewModel.tracks) { track in
                            TrackEditorRow(
                                track: track,
                                width: timelineWidth,
                                thumbnails: thumbnails,
                                onMute: { viewModel.toggleTrackMute(track.trackID) },
                                onRemove: { viewModel.requestRemoveTrack(track.trackID) },
                                onVolume: { viewModel.setTrackVolume($0, for: track.trackID) }
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    PlaybackPositionMarker(
                        progress: viewModel.progress,
                        labelWidth: labelWidth,
                        timelineWidth: timelineWidth,
                        topInset: 31,
                        height: CGFloat(max(viewModel.tracks.count, 1) * 46 + 8)
                    )
                    .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 72, maxHeight: .infinity)
            .layoutPriority(1)

            Divider()
            TrimRangeControl(
                start: viewModel.trimStart,
                end: viewModel.trimEnd,
                duration: viewModel.duration,
                onChange: { start, end in viewModel.setTrim(start: start, end: end) }
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(.thickMaterial)
        .task(id: viewModel.selectedRecording?.id) {
            guard let url = viewModel.selectedRecording?.url else {
                thumbnails = []
                return
            }
            thumbnails = await PlayerMediaInspector.thumbnails(url: url)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label(L10n.t("player.track.editor"), systemImage: "timeline.selection")
                .font(.headline)
            if viewModel.compositeRebuildRequested {
                Label(L10n.t("player.composite.rebuild.pending"), systemImage: "waveform.badge.plus")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
            Text(viewModel.currentTimeText)
                .monospacedDigit()
                .foregroundStyle(.primary)
            Text("/")
                .foregroundStyle(.secondary)
            Text(viewModel.durationText)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button { viewModel.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.isDirty == false)
            .help(L10n.t("player.edit.undo"))
            Button { viewModel.redo() } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .buttonStyle(.borderless)
            .help(L10n.t("player.edit.redo"))
            Button { viewModel.resetEdits() } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .disabled(!viewModel.isDirty)
            .help(L10n.t("player.edit.reset"))
            Button {
                viewModel.rebuildComposite()
            } label: {
                Label(L10n.t("player.composite.rebuild"), systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.tracks.filter { $0.kind.isAudio && !$0.kind.isDerived }.isEmpty)
            .help(L10n.t("player.composite.rebuild.help"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct TrackEditorRow: View {
    let track: PlayerTrackDescriptor
    let width: CGFloat
    let thumbnails: [NSImage]
    let onMute: () -> Void
    let onRemove: () -> Void
    let onVolume: (Double) -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: track.symbolName)
                    .frame(width: 16)
                    .foregroundStyle(track.isRemoved ? Color.secondary : Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    if let subtitle = track.subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 2)
                if track.kind.isAudio {
                    Slider(
                        value: Binding(
                            get: { track.volume },
                            set: onVolume
                        ),
                        in: 0...4
                    )
                    .frame(width: 58)
                    .disabled(track.isRemoved)
                    .help(L10n.t("player.track.volume"))
                    Text(PlayerTrackDescriptor.gainText(for: track.volume))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                    Button(action: onMute) {
                        Image(systemName: track.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .buttonStyle(.borderless)
                    .disabled(track.isRemoved)
                    .help(track.isMuted ? L10n.t("player.track.unmute") : L10n.t("player.track.mute"))
                    Button(action: onRemove) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .disabled(track.isRemoved)
                    .help(L10n.t("player.track.remove"))
                }
            }
            .padding(.trailing, 10)
            .frame(width: 230, height: 40, alignment: .leading)

            TimelineLane(track: track, thumbnails: thumbnails)
                .frame(width: width, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .opacity(track.isRemoved ? 0.45 : 1)
    }
}

private struct TimelineLane: View {
    let track: PlayerTrackDescriptor
    let thumbnails: [NSImage]

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(track.kind == .video ? Color.blue.opacity(0.16) : Color.orange.opacity(0.14))
            if track.kind == .video {
                HStack(spacing: 2) {
                    ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, image in
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 76, height: 36)
                            .clipped()
                    }
                    Spacer(minLength: 0)
                }
                .padding(2)
                .opacity(0.82)
            } else {
                WaveformLane(seed: track.trackID.id.hashValue)
                    .padding(.horizontal, 5)
            }
            Rectangle()
                .fill(track.kind == .video ? Color.blue : Color.orange)
                .frame(width: 2)
                .opacity(0.75)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(.quaternary, lineWidth: 1)
        }
    }
}

private struct WaveformLane: View {
    let seed: Int

    var body: some View {
        Canvas { context, size in
            let count = max(Int(size.width / 5), 1)
            for index in 0..<count {
                let value = Double(abs((seed &* 31 &+ index &* 17) % 97)) / 97.0
                let amplitude = max(2, size.height * (0.18 + value * 0.32))
                let x = CGFloat(index) / CGFloat(count) * size.width
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height / 2 - amplitude / 2))
                path.addLine(to: CGPoint(x: x, y: size.height / 2 + amplitude / 2))
                context.stroke(path, with: .color(.orange.opacity(0.82)), lineWidth: 2)
            }
        }
    }
}

private struct TimelineRuler: View {
    let duration: Double
    let width: CGFloat

    var body: some View {
        Canvas { context, size in
            let divisions = 10
            for index in 0...divisions {
                let x = CGFloat(index) / CGFloat(divisions) * size.width
                var path = Path()
                path.move(to: CGPoint(x: x, y: 12))
                path.addLine(to: CGPoint(x: x, y: 20))
                context.stroke(path, with: .color(.secondary.opacity(0.55)), lineWidth: 1)
                let seconds = duration * Double(index) / Double(divisions)
                context.draw(
                    Text(PlayerViewModel.formatTime(seconds)).font(.caption2),
                    at: CGPoint(x: min(max(x, 20), size.width - 20), y: 5)
                )
            }
        }
        .frame(width: width, height: 25)
    }
}

private struct PlaybackPositionMarker: View {
    let progress: Double
    let labelWidth: CGFloat
    let timelineWidth: CGFloat
    let topInset: CGFloat
    let height: CGFloat

    var body: some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(width: 2, height: height)
            .overlay(alignment: .top) {
                Image(systemName: "triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.accentColor)
                    .offset(y: -4)
            }
            .offset(x: 12 + labelWidth + timelineWidth * progress, y: topInset)
    }
}

private struct TrimRangeControl: View {
    let start: Double
    let end: Double
    let duration: Double
    let onChange: (Double, Double) -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Label(L10n.t("player.trim"), systemImage: "scissors")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(PlayerViewModel.formatTime(start))
                    .monospacedDigit()
                Text("–")
                    .foregroundStyle(.secondary)
                Text(PlayerViewModel.formatTime(end))
                    .monospacedDigit()
            }
            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let startX = duration > 0 ? width * start / duration : 0
                let endX = duration > 0 ? width * end / duration : width
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(Color.accentColor.opacity(0.55))
                        .frame(width: max(endX - startX, 2))
                        .offset(x: startX)
                    TrimHandle()
                        .offset(x: startX - 7)
                        .gesture(handleGesture(proxy: proxy, isStart: true))
                    TrimHandle()
                        .offset(x: endX - 7)
                        .gesture(handleGesture(proxy: proxy, isStart: false))
                }
            }
            .frame(height: 14)
        }
    }

    private func handleGesture(proxy: GeometryProxy, isStart: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard duration > 0 else { return }
                let time = min(max(value.location.x / max(proxy.size.width, 1) * duration, 0), duration)
                if isStart {
                    onChange(min(time, end), end)
                } else {
                    onChange(start, max(time, start))
                }
            }
    }
}

private struct TrimHandle: View {
    var body: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: 14, height: 20)
            .overlay(Capsule().stroke(.white.opacity(0.75), lineWidth: 1))
    }
}
