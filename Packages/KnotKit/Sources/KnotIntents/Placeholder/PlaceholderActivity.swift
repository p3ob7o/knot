#if os(iOS)
    import ActivityKit

    /// WP-01's packaging proof for the Live Activity: a trivial attributes type, declared
    /// in this package and used by the iOS widget extension's `ActivityConfiguration`.
    /// WP-19 replaces it with the recording's attributes. iPhone and iPad only: ActivityKit
    /// reaches macOS only in 27.3, above the deployment target.
    public struct KnotPlaceholderActivityAttributes: ActivityAttributes {
        public struct ContentState: Codable, Hashable, Sendable {
            public init() {}
        }

        public init() {}
    }
#endif
