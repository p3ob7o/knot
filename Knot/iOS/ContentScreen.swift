import SwiftUI
import KnotKit

/// Root iOS scene. Shows onboarding when no vault is configured; otherwise
/// shows the editor with a settings sheet behind a gear icon.
struct ContentScreen: View {
    @Bindable var model: EditorModel
    @State private var settingsPresented = false

    var body: some View {
        NavigationStack {
            Group {
                if model.shouldShowOnboarding {
                    OnboardingView(model: model, onDone: {})
                } else {
                    EditorView(model: model)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        settingsPresented = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .navigationTitle("Knot")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $settingsPresented) {
                NavigationStack {
                    SettingsView(model: model)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { settingsPresented = false }
                            }
                        }
                }
            }
        }
    }
}
