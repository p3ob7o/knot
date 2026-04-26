import SwiftUI
import KnotKit

/// Two-segment control letting the user override auto-routing for the
/// current note. Re-selecting nothing returns to "auto" — but to keep the
/// UX simple we always show the resolved mode and let tapping flip it.
///
/// Locked-in design: each segment carries a glyph (calendar / tray) plus
/// its label. Auto-routing flips the segment with a 220ms ease-out via
/// the `.animation` modifier on the picker.
struct ModeToggle: View {
    @Binding var manualMode: NoteMode?
    let resolvedMode: NoteMode

    var body: some View {
        Picker("", selection: pickerBinding) {
            Label("Today", systemImage: "calendar").tag(NoteMode.daily)
            Label("Inbox", systemImage: "tray").tag(NoteMode.inbox)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 200)
        .animation(.easeOut(duration: 0.22), value: resolvedMode)
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
