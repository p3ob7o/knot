import SwiftUI
import KnotKit

/// Two-segment control letting the user override auto-routing for the
/// current note. Re-selecting nothing returns to "auto" — but to keep the
/// UX simple we always show the resolved mode and let tapping flip it.
///
/// Hand-rolled rather than `Picker(.segmented)` because the macOS
/// segmented picker silently drops `Label` icons, and the locked-in
/// design needs both glyph + label per segment. The container, thumb,
/// and active styling mirror `kn-iconseg` from the design handoff.
struct ModeToggle: View {
    @Binding var manualMode: NoteMode?
    let resolvedMode: NoteMode

    var body: some View {
        HStack(spacing: 2) {
            segment(.daily, label: "Today", icon: "calendar")
            segment(.inbox, label: "Inbox", icon: "tray")
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        )
        .animation(.easeOut(duration: 0.22), value: resolvedMode)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Destination")
    }

    @ViewBuilder
    private func segment(_ mode: NoteMode, label: String, icon: String) -> some View {
        let isActive = resolvedMode == mode
        Button {
            manualMode = mode
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(label)
                    .font(.system(size: 12, weight: isActive ? .semibold : .medium))
            }
            .padding(.horizontal, 12)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isActive ? Color.primary.opacity(0.16) : Color.clear)
                    .shadow(
                        color: isActive ? Color.black.opacity(0.25) : .clear,
                        radius: 1, x: 0, y: 1
                    )
            )
            .foregroundStyle(isActive ? Color.primary : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
