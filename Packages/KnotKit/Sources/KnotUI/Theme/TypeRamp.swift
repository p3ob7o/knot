import SwiftUI

/// What a piece of text is. Each role maps to a Dynamic Type text style, so every size scales
/// with the person's setting up to the largest accessibility sizes (docs/product-spec.md §13).
public enum TypeRole: String, Hashable, Sendable, CaseIterable {
    /// A note's title, at the head of an open note.
    case noteTitle
    /// A row's title or first line in the stream.
    case rowTitle
    /// A row's preview.
    case rowPreview
    /// A segment's text, and the capture field.
    case body
    /// A segment's state, a time, a mark.
    case caption
    /// A banner across the stream.
    case banner
}

/// The type ramp: one text style for each role. WP-40 may change the styles and their
/// weights, never the fact that each is a Dynamic Type style.
public struct TypeRamp: Sendable {
    private var styles: [TypeRole: Font]

    public init(_ styles: [TypeRole: Font]) {
        self.styles = styles
    }

    public subscript(role: TypeRole) -> Font {
        styles[role] ?? .body
    }

    public static let placeholder = TypeRamp([
        .noteTitle: .title2.weight(.semibold),
        .rowTitle: .headline,
        .rowPreview: .subheadline,
        .body: .body,
        .caption: .caption,
        .banner: .callout,
    ])
}
