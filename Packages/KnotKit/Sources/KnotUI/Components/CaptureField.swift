import KnotCore
import SwiftUI

/// The capture field: the last element of every open note, through which new text enters
/// (docs/product-spec.md §7). It has focus when the surface appears (§4.1), and it does not
/// accept typing while a recording runs (rule 15). ⌘↩ or Done ends the capture.
///
/// The surface owns the focus: it passes its binding in, so that text arriving elsewhere never
/// moves focus, and focus returns where it was when a surface closes.
public struct CaptureField: View {
    @Environment(\.knotTheme) private var theme
    let text: String
    let acceptsTyping: Bool
    let isFocused: FocusState<Bool>.Binding
    let onChange: @MainActor (String) -> Void
    let onSubmit: () -> Void

    public init(
        text: String, acceptsTyping: Bool, isFocused: FocusState<Bool>.Binding,
        onChange: @escaping @MainActor (String) -> Void,
        onSubmit: @escaping () -> Void
    ) {
        self.text = text
        self.acceptsTyping = acceptsTyping
        self.isFocused = isFocused
        self.onChange = onChange
        self.onSubmit = onSubmit
    }

    public var body: some View {
        TextField(
            text: Binding(get: { text }, set: onChange), axis: .vertical
        ) {
            Text("Type a thought", bundle: .module)
        }
        .font(theme.type[.body])
        .textFieldStyle(.plain)
        .focused(isFocused)
        .disabled(!acceptsTyping)
        .onSubmit(onSubmit)
        #if !os(watchOS)
            .submitLabel(.done)
        #endif
        .accessibilityLabel(Text("Capture field", bundle: .module))
        .accessibilityHint(
            acceptsTyping
                ? Text("Type to add to this note.", bundle: .module)
                : Text("Typing waits while a recording runs.", bundle: .module))
    }
}

/// The search field. It filters the stream as the person types.
public struct SearchField: View {
    @Environment(\.knotTheme) private var theme
    let text: String
    let onChange: @MainActor (String) -> Void

    public init(text: String, onChange: @escaping @MainActor (String) -> Void) {
        self.text = text
        self.onChange = onChange
    }

    public var body: some View {
        HStack(spacing: theme.spacing.regular) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(theme.colors[.textSecondary])
                .accessibilityHidden(true)
            TextField(text: Binding(get: { text }, set: onChange)) {
                Text("Search", bundle: .module)
            }
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            if !text.isEmpty {
                Button {
                    onChange("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.colors[.textSecondary])
                .accessibilityLabel(Text("Clear search", bundle: .module))
            }
        }
        .font(theme.type[.body])
        .padding(theme.spacing.regular)
        .background(theme.colors[.surface], in: RoundedRectangle(cornerRadius: theme.radii.regular))
    }
}
