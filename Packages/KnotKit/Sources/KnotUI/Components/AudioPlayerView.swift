import KnotCore
import SwiftUI

/// The player of a voice segment: play or pause, where it stands, and its length.
public struct AudioPlayerView: View {
    @Environment(\.knotTheme) private var theme
    let state: PlaybackState
    let length: Duration?
    let onToggle: () -> Void
    let onSeek: (Duration) -> Void

    public init(
        state: PlaybackState, length: Duration?, onToggle: @escaping () -> Void, onSeek: @escaping (Duration) -> Void
    ) {
        self.state = state
        self.length = length
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
        HStack(spacing: theme.spacing.regular) {
            Button(action: onToggle) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    #if os(iOS)
                        .padding(theme.spacing.loose)
                        .contentShape(.rect)
                    #endif
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? Text("Pause", bundle: .module) : Text("Play", bundle: .module))
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
            Text("\(ClockText.of(at)) / \(ClockText.of(of))")
                .font(theme.type[.caption])
                .monospacedDigit()
                .foregroundStyle(theme.colors[.textSecondary])
                .accessibilityHidden(true)
        }
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
