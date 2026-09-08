import SwiftUI
import KnotKit

struct ModeToggle: View {
    @Binding var manualMode: NoteMode?
    let resolvedMode: NoteMode

    var body: some View {
        HStack(spacing: 2) {
            segment(nil, label: "Auto", icon: "arrow.triangle.branch")
            segment(.daily, label: "Today", icon: "calendar")
            segment(.inbox, label: "Inbox", icon: "tray")
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        )
        .animation(.easeOut(duration: 0.22), value: manualMode)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Destination")
    }

    @ViewBuilder
    private func segment(_ mode: NoteMode?, label: String, icon: String) -> some View {
        let isActive = manualMode == mode
        Button {
            manualMode = mode
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                Text(label)
                    .font(.system(size: 11, weight: isActive ? .semibold : .medium))
            }
            .frame(minWidth: 54, minHeight: 22)
            .padding(.horizontal, 3)
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
        .accessibilityHint(mode == nil ? "Automatically routes this draft to \(resolvedLabel)" : "Overrides automatic routing")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var resolvedLabel: String {
        resolvedMode == .daily ? "Today" : "Inbox"
    }
}
