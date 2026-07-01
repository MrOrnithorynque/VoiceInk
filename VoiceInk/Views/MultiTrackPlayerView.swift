// MultiTrackPlayerView — transport + per-speaker-tinted multi-lane waveform for a multi-source
// recording. Each lane is inset by the source's t0Offset so lanes line up on the shared clock;
// a single playhead + full-width drag overlay maps x → shared-timeline seconds (tap-to-seek).

import SwiftUI

struct MultiTrackPlayerView: View {
    let sources: [AudioSourceRecord]
    @StateObject private var player = MultiTrackPlayer()

    var body: some View {
        VStack(spacing: 8) {
            if !player.missingRoles.isEmpty {
                Label("Audio no longer available for: \(player.missingRoles.joined(separator: ", "))",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            // Speaker legend
            HStack(spacing: 12) {
                ForEach(player.loaded) { source in
                    HStack(spacing: 4) {
                        Circle().fill(SpeakerPalette.color(source.colorIndex)).frame(width: 7, height: 7)
                        Text(source.role).font(.caption2).foregroundColor(.secondary)
                    }
                }
                Spacer()
            }

            // Lanes + shared playhead + seek
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    VStack(spacing: 4) {
                        ForEach(player.loaded) { source in
                            LaneWaveform(
                                source: source,
                                samples: player.perSourceWaveforms[source.id] ?? [],
                                totalDuration: player.duration
                            )
                            .frame(height: 22)
                        }
                    }
                    if player.duration > 0 {
                        Rectangle()
                            .fill(Color.primary.opacity(0.65))
                            .frame(width: 2)
                            .offset(x: CGFloat(player.currentTime / player.duration) * geo.size.width)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onEnded { value in
                        guard player.duration > 0 else { return }
                        let frac = max(0, min(1, value.location.x / geo.size.width))
                        player.seek(to: Double(frac) * player.duration)
                    }
                )
            }
            .frame(height: CGFloat(max(1, player.loaded.count)) * 26)

            HStack(spacing: 10) {
                Button {
                    player.isPlaying ? player.pause() : player.play()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(player.loaded.isEmpty)

                Text(player.currentTime.formatTiming())
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                Spacer()
                Text(player.duration.formatTiming())
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
        .onAppear { player.load(sources: sources) }
        .onDisappear { player.cleanup() }
    }
}

/// One source's waveform, drawn across its [t0Offset, t0Offset+fileDuration] window on the
/// shared timeline and tinted with the speaker color.
private struct LaneWaveform: View {
    let source: MultiTrackPlayer.LoadedSource
    let samples: [Float]
    let totalDuration: TimeInterval

    var body: some View {
        Canvas { context, size in
            guard totalDuration > 0, !samples.isEmpty else { return }
            let startX = CGFloat(source.t0Offset / totalDuration) * size.width
            let laneWidth = CGFloat(source.fileDuration / totalDuration) * size.width
            let barWidth = max(0.5, laneWidth / CGFloat(samples.count))
            let color = SpeakerPalette.color(source.colorIndex)

            for (index, sample) in samples.enumerated() {
                let height = max(1, CGFloat(sample) * size.height)
                let x = startX + CGFloat(index) * barWidth
                let rect = CGRect(x: x, y: (size.height - height) / 2,
                                  width: max(0.5, barWidth - 0.5), height: height)
                context.fill(Path(rect), with: .color(color.opacity(0.7)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.04))
        )
    }
}
