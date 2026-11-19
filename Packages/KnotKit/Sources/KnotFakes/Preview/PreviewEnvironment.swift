#if DEBUG
    import KnotCore

    extension AppEnvironment {
        /// The environment of previews, UI tests and debug builds.
        ///
        /// WP-05 fills it in: on iOS and macOS, the real capture engine and queue running
        /// over the fakes. Until then it is `.unavailable`.
        public static var preview: AppEnvironment {
            .unavailable
        }
    }
#endif
