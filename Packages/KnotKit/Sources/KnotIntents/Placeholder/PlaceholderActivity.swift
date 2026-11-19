#if os(iOS)
    import ActivityKit

    /// WP-01's packaging proof for the Live Activity: a trivial attributes type, declared
    /// in this package and used by the iOS widget extension's `ActivityConfiguration`.
    /// WP-19 replaces it with the recording's attributes. iPhone and iPad only: in the
    /// pinned 27.2 SDK, ActivityKit and `LiveActivityIntent` are unavailable on macOS, and
    /// the 27.3 beta SDK makes them available only from macOS 27.3.
    public struct KnotPlaceholderActivityAttributes: ActivityAttributes {
        public struct ContentState: Codable, Hashable, Sendable {
            public init() {}
        }

        public init() {}
    }
#endif
