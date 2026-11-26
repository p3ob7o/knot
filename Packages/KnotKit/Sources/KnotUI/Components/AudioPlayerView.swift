import KnotCore
import SwiftUI

/// The player of a voice segment: play or pause, where it stands, and its length.
public struct AudioPlayerView: View {
    @Environment(\.knotTheme) private var theme
    let state: PlaybackState
    let length: Duration?
    let peaks: [UInt8]
    let onToggle: () -> Void
    let onSeek: (Duration) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(
        state: PlaybackState, length: Duration?, peaks: [UInt8] = [],
        onToggle: @escaping () -> Void, onSeek: @escaping (Duration) -> Void
    ) {
        self.state = state
        self.length = length
        self.peaks = peaks
        self.onToggle = onToggle
        self.onSeek = onSeek
    }

    private var isPlaying: Bool {
        if case .playing = state { return true }
        return false
    }

    private var position: (at: Duration, of: Duration) {
        switch state {
        case .empty: (.zero, length ?? .zero)
        case .paused(let at, let of), .playing(let at, let of): (at, of)
        case .ended(let of): (of, of)
        }
    }

    public var body: some View {
        let (at, of) = position
        #if os(iOS)
            let layout =
                typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: theme.spacing.space1))
                : AnyLayout(HStackLayout(spacing: theme.spacing.regular))
            layout {
                HStack(spacing: theme.spacing.regular) {
                    playButton
                    playbackTrack(at: at, length: of)
                }
                time(at: at, of: of)
            }
        #else
            HStack(spacing: theme.spacing.regular) {
                playButton
                #if !os(watchOS) && !os(tvOS)
                    Slider(
                        value: Binding(
                            get: { seconds(at) },
                            set: { onSeek(.milliseconds(Int64($0 * 1000))) }),
                        in: 0...max(seconds(of), 0.001)
                    )
                    .accessibilityLabel(Text("Position", bundle: .module))
                    .accessibilityValue(Text(ClockText.of(at)))
                #endif
                time(at: at, of: of)
            }
        #endif
    }

    private var playButton: some View {
        Button(action: onToggle) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                #if os(iOS)
                    .frame(minWidth: theme.sizes.hitTarget, minHeight: theme.sizes.hitTarget)
                    .contentShape(.rect)
                #endif
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? Text("Pause", bundle: .module) : Text("Play", bundle: .module))
    }

    private func time(at: Duration, of: Duration) -> some View {
        Text(state == .empty ? ClockText.of(of) : "\(ClockText.of(at)) / \(ClockText.of(of))")
            .font(theme.type[.playerTime])
            .monospacedDigit()
            .foregroundStyle(theme.colors[.textSecondary])
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityHidden(true)
    }

    #if os(iOS)
        private func playbackTrack(at position: Duration, length: Duration) -> some View {
            let total = seconds(length)
            let elapsed = seconds(position)
            let progress = total > 0 ? min(max(elapsed / total, 0), 1) : 0
            return GeometryReader { geometry in
                Group {
                    if peaks.isEmpty {
                        ProgressView(value: progress)
                            .tint(theme.colors[.textPrimary])
                    } else {
                        WaveformView(
                            levels: peaks.map { Float($0) / Float(UInt8.max) }, role: .textPrimary,
                            playedFraction: progress
                        )
                        .frame(height: theme.spacing.space6)
                    }
                }
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(
                    SpatialTapGesture().onEnded { tap in
                        seek(at: tap.location.x, width: geometry.size.width, total: total)
                    }
                )
                .simultaneousGesture(
                    DragGesture().onEnded { drag in
                        guard abs(drag.translation.width) > abs(drag.translation.height) else { return }
                        seek(at: drag.location.x, width: geometry.size.width, total: total)
                    })
            }
            .frame(height: theme.sizes.hitTarget)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("recording.position")
            .accessibilityLabel(Text("Position", bundle: .module))
            .accessibilityValue(
                Text(state == .empty ? ClockText.of(length) : "\(ClockText.of(position)) / \(ClockText.of(length))")
            )
            .accessibilityAdjustableAction { direction in
                let target: Double
                switch direction {
                case .increment: target = elapsed + 5
                case .decrement: target = elapsed - 5
                @unknown default: return
                }
                guard total > 0 else { return }
                onSeek(.seconds(min(max(target, 0), total)))
            }
        }
        private func seek(at x: CGFloat, width: CGFloat, total: Double) {
            guard total > 0, width > 0 else { return }
            let fraction = min(max(x / width, 0), 1)
            onSeek(.seconds(total * fraction))
        }
    #endif

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
