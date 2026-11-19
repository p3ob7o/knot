import AppIntents

/// WP-01's packaging proof for App Intents: one trivial intent, declared in this package,
/// that appears in the App Intents metadata of both the iOS app and the iOS widget
/// extension. `scripts/verify.sh --only packaging` checks both. WP-19 replaces it.
public struct KnotPlaceholderIntent: AppIntent {
    public static var title: LocalizedStringResource { "Placeholder" }
    public static var isDiscoverable: Bool { false }

    public init() {}

    public func perform() async throws -> some IntentResult {
        .result()
    }
}

/// The App Intents package of KnotIntents. Each app and extension that runs or lists
/// Knot's intents names it in its own `AppIntentsPackage`.
public struct KnotIntentsPackage: AppIntentsPackage {}
