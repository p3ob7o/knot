import KnotCore
import KnotUI
import SwiftUI

/// The Watch app. It does not use KnotApp or the capture engine: it composes the recorder,
/// the link to the iPhone and the UI itself (docs/architecture.md §3), in `WatchComposition`.
/// It has one screen, the record control (docs/product-spec.md §6).
@main
struct KnotWatchApp: App {
    @State private var model = RecordScreenModel(composition: WatchComposition.make(.current))

    var body: some Scene {
        WindowGroup {
            RecordScreen(model: model)
        }
    }
}

/// The Watch app's one screen: the record control and what came of the last press, in the
/// system's default look through KnotUI's theme. It shows no note content.
struct RecordScreen: View {
    let model: RecordScreenModel

    var body: some View {
        VStack(spacing: 8) {
            RecordButton(phase: model.controlPhase, action: model.press)
                .disabled(model.controlDisabled)
                .accessibilityIdentifier("knot.record")
            if let text = model.status.text {
                Text(text)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("knot.status")
            }
        }
        .onAppear { model.launch() }
    }
}
