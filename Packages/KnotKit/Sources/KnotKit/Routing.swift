import Foundation

/// Decides whether a piece of free-form text becomes a daily-note bullet or
/// an inbox file, based on length and shape. The user may always override.
public struct RoutingPolicy: Sendable, Equatable {
    public var maxCharsForDaily: Int
    public var requireSingleLineForDaily: Bool

    public init(maxCharsForDaily: Int = 280, requireSingleLineForDaily: Bool = true) {
        self.maxCharsForDaily = maxCharsForDaily
        self.requireSingleLineForDaily = requireSingleLineForDaily
    }

    public init(settings: AppSettings) {
        self.init(
            maxCharsForDaily: settings.routingMaxChars,
            requireSingleLineForDaily: settings.routingRequiresSingleLine
        )
    }

    public func decide(for content: String) -> NoteMode {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > maxCharsForDaily { return .inbox }
        if requireSingleLineForDaily && trimmed.contains("\n") { return .inbox }
        return .daily
    }
}
