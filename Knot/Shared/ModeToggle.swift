import SwiftUI
import KnotKit

/// Two-segment control letting the user override auto-routing for the
/// current note. Re-selecting nothing returns to "auto" — but to keep the
/// UX simple we always show the resolved mode and let tapping flip it.
struct ModeToggle: View {
    @Binding var manualMode: NoteMode?
    let resolvedMode: NoteMode

    var body: some View {
        Picker("", selection: pickerBinding) {
            Text("Today").tag(NoteMode.daily)
            Text("Inbox").tag(NoteMode.inbox)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 180)
    }

    private var pickerBinding: Binding<NoteMode> {
        Binding(
            get: { resolvedMode },
            set: { newValue in
                manualMode = newValue
            }
        )
    }
}
