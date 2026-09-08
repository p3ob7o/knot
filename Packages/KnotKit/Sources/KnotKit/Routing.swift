import Foundation

public enum NoteMode: String, Codable, Sendable, CaseIterable {
    case daily
    case inbox
}

/// Pure automatic routing. Trimming is used only for the decision; callers
/// retain the exact nonblank Markdown source.
public struct RoutingPolicy: Sendable, Equatable {
    public var maxCharsForDaily: Int
    public var requireSingleLineForDaily: Bool

    public init(maxCharsForDaily: Int = 280, requireSingleLineForDaily: Bool = true) {
        self.maxCharsForDaily = max(1, min(100_000, maxCharsForDaily))
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
        if requireSingleLineForDaily && Self.containsLineBreak(trimmed) { return .inbox }
        return .daily
    }

    private static func containsLineBreak(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            $0.value == 10 || $0.value == 13 || $0.value == 0x2028 || $0.value == 0x2029
        }
    }
}
