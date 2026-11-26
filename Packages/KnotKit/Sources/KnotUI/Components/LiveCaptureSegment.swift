import KnotCore
import SwiftUI

/// The live segment takes the capture field's place until the recording has stopped.
public struct LiveCaptureSegment: View {
    @Environment(\.knotTheme) private var theme
    let transcript: LiveTranscript
    let levels: [Float]
    let isLive: Bool

    public init(transcript: LiveTranscript, levels: [Float], isLive: Bool = true) {
        self.transcript = transcript
        self.levels = levels
        self.isLive = isLive
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.regular) {
            if !levels.isEmpty {
                WaveformView(levels: levels)
                    .frame(height: theme.spacing.betweenSegments)
            }
            if !transcript.final.isEmpty || !transcript.volatile.isEmpty {
                let final = Text(transcript.final).foregroundStyle(theme.colors[.textPrimary])
                let provisional = Text(transcript.volatile).foregroundStyle(theme.colors[.textSecondary])
                Text("\(final)\(provisional)", bundle: .module)
                    .font(theme.type[.body])
            }
            if isLive {
                Text("Recording. Typing waits until you stop.", bundle: .module)
                    .font(theme.type[.caption])
                    .foregroundStyle(theme.colors[.textSecondary])
            }
        }
    }
}
