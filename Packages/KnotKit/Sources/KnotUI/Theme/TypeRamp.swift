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
    /// A segment's text and the inline capture field.
    case body
    case emphasizedBody
    /// The capture field, including the Mac's floating panel.
    case captureField
    case markdownHeading1
    case markdownHeading2
    case stateLine
    case emphasizedStateLine
    case metaLine
    case appendCaption
    case playerTime
    case recordingTime
    case outcomeTitle
    case outcomeBody
    case outcomeDetail
    case notice
    /// The same role as `stateLine` in the designed theme. Use `playerTime` for playback.
    case caption
    /// The same role as `notice` in the designed theme.
    case banner
}

/// The type ramp assigns a Dynamic Type text style to each role.
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

    public static let designed: TypeRamp = {
        #if os(macOS)
            let captureField = Font.title2
            let heading1 = Font.title.bold()
            let heading2 = Font.title2.bold()
            let stateLine = Font.subheadline
            let recordingTime = Font.body.monospacedDigit()
        #else
            let captureField = Font.body
            let heading1 = Font.title2.bold()
            let heading2 = Font.title3.bold()
            let stateLine = Font.footnote
            #if os(watchOS)
                let recordingTime = Font.title2.monospacedDigit()
            #else
                let recordingTime = Font.body.monospacedDigit()
            #endif
        #endif

        return TypeRamp(
            Dictionary(
                uniqueKeysWithValues: TypeRole.allCases.map { role in
                    let font: Font =
                        switch role {
                        case .noteTitle: .title2.bold()
                        case .rowTitle, .outcomeTitle: .headline
                        case .rowPreview: .subheadline
                        case .body, .outcomeBody: .body
                        case .emphasizedBody: .body.bold()
                        case .captureField: captureField
                        case .markdownHeading1: heading1
                        case .markdownHeading2: heading2
                        case .stateLine, .caption, .appendCaption, .outcomeDetail: stateLine
                        case .emphasizedStateLine: stateLine.bold()
                        case .metaLine: .footnote
                        case .playerTime: .caption.monospacedDigit()
                        case .recordingTime: recordingTime
                        case .notice, .banner: .callout
                        }
                    return (role, font)
                }))
    }()
}
