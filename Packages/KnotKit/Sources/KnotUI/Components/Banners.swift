import KnotCore
import SwiftUI

/// A line across the top of a surface: what is wrong, or what can be undone.
public struct Banner<Actions: View>: View {
    @Environment(\.knotTheme) private var theme
    let message: String
    let symbol: String
    let role: ColorRole
    let actions: Actions

    public init(
        _ message: String, symbol: String, role: ColorRole = .textSecondary, @ViewBuilder actions: () -> Actions
    ) {
        self.message = message
        self.symbol = symbol
        self.role = role
        self.actions = actions()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.spacing.regular) {
            Image(systemName: symbol)
                .foregroundStyle(theme.colors[role])
                .accessibilityHidden(true)
            Text(message)
                .font(theme.type[.banner])
                .foregroundStyle(theme.colors[.textPrimary])
                .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .padding(theme.spacing.regular)
        .background(theme.colors[.surface], in: RoundedRectangle(cornerRadius: theme.radii.regular))
        .accessibilityElement(children: .contain)
    }
}

extension Banner where Actions == EmptyView {
    public init(_ message: String, symbol: String, role: ColorRole = .textSecondary) {
        self.init(message, symbol: symbol, role: role) { EmptyView() }
    }
}

/// What the stream shows while it is empty on first run: the line about sync, if any, and up to
/// three dismissible rows on setting up a way to capture.
public struct FirstRunView: View {
    @Environment(\.knotTheme) private var theme
    let content: FirstRunContent
    let onDismiss: (SetupRow) -> Void

    public init(_ content: FirstRunContent, onDismiss: @escaping (SetupRow) -> Void) {
        self.content = content
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.loose) {
            Text("No notes yet", bundle: .module)
                .font(theme.type[.rowTitle])
            if let line = content.syncLine {
                Text(line)
                    .font(theme.type[.banner])
                    .foregroundStyle(theme.colors[.textSecondary])
            }
            ForEach(content.setupRows) { row in
                Banner(row.title, symbol: "sparkles") {
                    Button {
                        onDismiss(row)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Dismiss", bundle: .module))
                }
            }
        }
    }
}
