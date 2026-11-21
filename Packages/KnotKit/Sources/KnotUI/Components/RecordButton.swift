import KnotCore
import SwiftUI

/// The record control: it starts a recording and stops it. Its VoiceOver label says what a
/// press does now, and the announcement of the start and the stop comes from the view model,
/// which stays silent while the recording runs.
public struct RecordButton: View {
    @Environment(\.knotTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let phase: RecordingPhase
    let action: () -> Void

    public init(phase: RecordingPhase, action: @escaping () -> Void) {
        self.phase = phase
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: phase.isRecording || phase == .stopping ? "stop.circle.fill" : "mic.circle.fill")
                .font(.largeTitle)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(phase == .idle ? theme.colors[.accent] : theme.colors[.recording])
        }
        .buttonStyle(.plain)
        .disabled(phase == .starting || phase == .stopping)
        .animation(theme.motion.animation(for: .recordingPhase, reduceMotion: reduceMotion), value: phase)
        .accessibilityLabel(label)
        // A press that starts a recording starts a media session: VoiceOver does not speak over
        // it, so that its own speech is not recorded.
        .accessibilityAddTraits(phase == .idle ? .startsMediaSession : [])
    }

    private var label: Text {
        switch phase {
        case .idle: Text("Start recording", bundle: .module)
        case .starting: Text("Starting recording", bundle: .module)
        case .recording: Text("Stop recording", bundle: .module)
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
            let barWidth = max(1, slot * 0.6)
            for (index, level) in levels.enumerated() {
                let clamped = CGFloat(min(max(level, 0), 1))
                let height = max(2, clamped * size.height)
                let rect = CGRect(
                    x: CGFloat(index) * slot + (slot - barWidth) / 2, y: (size.height - height) / 2, width: barWidth,
                    height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(theme.colors[role]))
            }
        }
        .frame(minHeight: 24)
        // The levels say nothing a person needs read out, and VoiceOver stays silent while a
        // recording runs.
        .accessibilityHidden(true)
    }
}
