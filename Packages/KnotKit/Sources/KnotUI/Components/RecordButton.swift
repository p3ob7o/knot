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
            .disabled(phase == .starting || phase == .stopping)
            .animation(theme.motion.animation(for: .recordingPhase, reduceMotion: reduceMotion), value: phase)
            .accessibilityLabel(label)
            .accessibilityAddTraits(phase == .idle ? .startsMediaSession : [])
    }

    @ViewBuilder private var styledButton: some View {
        if phase.isRecording || phase == .stopping {
            button
                .buttonStyle(.glassProminent)
                .tint(theme.colors[.recording])
        } else {
            button
                .buttonStyle(.glass)
                .foregroundStyle(
                    theme.colors[phase == .idle && outcome == .couldNotStart ? .textSecondary : .textPrimary])
        }
    }

    private var button: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(theme.type[.rowTitle])
                .frame(
                    minWidth: toolbar ? RecordControlSize.toolbar : nil,
                    minHeight: toolbar ? RecordControlSize.toolbar : nil)
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

/// The toolbar's minimum hit area until the theme supplies control sizes.
private enum RecordControlSize {
    static let toolbar: CGFloat = 44
}

/// A recording's levels, newest last, as bars. It draws from the peaks it is given, so a stored
/// recording never needs its audio decoded (docs/architecture.md §8).
public struct WaveformView: View {
    @Environment(\.knotTheme) private var theme
    let levels: [Float]
    let role: ColorRole

    /// - Parameter levels: peaks between 0 and 1.
    public init(levels: [Float], role: ColorRole = .recording) {
        self.levels = levels
        self.role = role
    }

    public var body: some View {
        Canvas { context, size in
            guard !levels.isEmpty else { return }
            let count = levels.count
            let slot = size.width / CGFloat(count)
            let barWidth = slot * 0.6
            for (index, level) in levels.enumerated() {
                let clamped = CGFloat(min(max(level, 0), 1))
                let height = max(0.08, clamped) * size.height
                let rect = CGRect(
                    x: CGFloat(index) * slot + (slot - barWidth) / 2, y: (size.height - height) / 2, width: barWidth,
                    height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(theme.colors[role]))
            }
        }
        .frame(minHeight: theme.spacing.betweenSegments)
        // The levels say nothing a person needs read out, and VoiceOver stays silent while a
        // recording runs.
        .accessibilityHidden(true)
    }
}
