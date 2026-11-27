import KnotCore
import SwiftUI

/// The record control: it starts a recording and stops it. Its VoiceOver label says what a
/// press does now, and the announcement of the start and the stop comes from the view model,
/// which stays silent while the recording runs.
public struct RecordButton: View {
    @Environment(\.knotTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let phase: RecordingPhase
    let elapsed: Duration?
    let outcome: RecordingOutcome?
    let toolbar: Bool
    private var legacyLabel = false
    let action: () -> Void

    // The Watch shell uses this initializer until it adopts the shared outcomes in WP-32.
    public init(phase: RecordingPhase, action: @escaping () -> Void) {
        self.init(phase: phase, elapsed: nil, outcome: nil, toolbar: false, action: action)
        legacyLabel = true
    }

    public init(
        phase: RecordingPhase, elapsed: Duration?, outcome: RecordingOutcome?, toolbar: Bool = false,
        action: @escaping () -> Void
    ) {
        self.phase = phase
        self.elapsed = elapsed
        self.outcome = outcome
        self.toolbar = toolbar
        self.action = action
    }

    public var body: some View {
        styledButton
            #if os(iOS)
                .buttonBorderShape(.circle)
                .buttonSizing(.flexible)
                .frame(width: theme.sizes.hitTarget, height: theme.sizes.hitTarget)
                .accessibilityShowsLargeContentViewer {
                    Label {
                        label
                    } icon: {
                        Image(systemName: symbol)
                    }
                }
            #endif
            .disabled(phase == .starting || phase == .stopping)
            .animation(theme.motion.animation(for: .recordingPhase, reduceMotion: reduceMotion), value: phase)
            .accessibilityLabel(label)
            .accessibilityAddTraits(phase == .idle ? .startsMediaSession : [])
    }

    @ViewBuilder private var styledButton: some View {
        if usesRecordingTint {
            button
                .buttonStyle(.glassProminent)
                .tint(theme.colors[.recording])
        } else {
            #if os(iOS)
                if toolbar {
                    // The bottom toolbar already supplies the glass behind the control.
                    button.foregroundStyle(idleInk)
                } else {
                    button.buttonStyle(.glass).foregroundStyle(idleInk)
                }
            #else
                button.buttonStyle(.glass).foregroundStyle(idleInk)
            #endif
        }
    }

    private var idleInk: Color {
        theme.colors[phase == .idle && outcome == .couldNotStart ? .textSecondary : .textPrimary]
    }

    private var usesRecordingTint: Bool {
        #if os(iOS)
            phase.isRecording
        #else
            phase.isRecording || phase == .stopping
        #endif
    }

    private var button: some View {
        #if os(iOS)
            let labelSize = toolbar ? theme.sizes.hitTarget : theme.sizes.insetGlassLabel
        #endif
        return Button(action: action) {
            Image(systemName: symbol)
                .font(theme.type[.rowTitle])
                #if os(iOS)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .frame(width: labelSize, height: labelSize)
                    .contentShape(.rect)
                #else
                    .frame(
                        minWidth: toolbar ? theme.sizes.hitTarget : nil,
                        minHeight: toolbar ? theme.sizes.hitTarget : nil)
                #endif
        }
    }

    private var symbol: String {
        switch phase {
        case .starting: "mic.fill"
        case .recording, .stopping: "stop.fill"
        case .idle:
            switch outcome {
            case .saved: "checkmark"
            case .couldNotStart: "mic.slash"
            default: "mic"
            }
        }
    }

    private var label: Text {
        switch phase {
        case .idle:
            if outcome == .saved {
                Text("Saved", bundle: .module)
            } else if legacyLabel {
                Text("Start recording", bundle: .module)
            } else {
                Text("Record", bundle: .module)
            }
        case .starting: Text("Starting recording", bundle: .module)
        case .recording:
            if let elapsed {
                Text("Stop recording, \(ClockText.of(elapsed))", bundle: .module)
            } else {
                Text("Stop recording", bundle: .module)
            }
        case .stopping: Text("Saving recording", bundle: .module)
        }
    }

}

/// A recording's levels, newest last, as bars. It draws from the peaks it is given, so a stored
/// recording never needs its audio decoded (docs/architecture.md §8).
public struct WaveformView: View {
    @Environment(\.knotTheme) private var theme
    let levels: [Float]
    let role: ColorRole
    let playedFraction: Double?

    /// - Parameter levels: peaks between 0 and 1.
    public init(levels: [Float], role: ColorRole = .recording, playedFraction: Double? = nil) {
        self.levels = levels
        self.role = role
        self.playedFraction = playedFraction
    }

    public var body: some View {
        Canvas { context, size in
            guard !levels.isEmpty else { return }
            let barWidth = theme.sizes.waveformBar
            let slot = barWidth * 2
            let capacity = max(1, Int((size.width + barWidth) / slot))
            let count = min(capacity, levels.count)
            let step = playedFraction == nil ? slot : size.width / CGFloat(count)
            for index in 0..<count {
                let start = index * levels.count / count
                let end = (index + 1) * levels.count / count
                let peak = levels[start..<end].max() ?? 0
                let clamped = CGFloat(min(max(peak, 0), 1))
                let height = max(barWidth, clamped * size.height)
                let rect = CGRect(
                    x: CGFloat(index) * step, y: (size.height - height) / 2, width: barWidth,
                    height: height)
                let position = Double(index) / Double(count)
                let color = theme.colors[playedFraction.map { position < $0 } == false ? .labelQuaternary : role]
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color))
            }
        }
        .frame(minHeight: theme.spacing.betweenSegments)
        // The levels say nothing a person needs read out, and VoiceOver stays silent while a
        // recording runs.
        .accessibilityHidden(true)
    }
}
