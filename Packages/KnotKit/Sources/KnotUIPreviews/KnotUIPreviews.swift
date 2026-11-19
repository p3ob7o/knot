#if DEBUG || KNOT_FAKES
    import KnotCore
    import KnotFakes
    import KnotUI

    /// SwiftUI previews of KnotUI, on the preview environment (docs/architecture.md §16).
    ///
    /// The state matrix of docs/design/brief.md §6 gets one named preview here for every
    /// designed cell. WP-01 only declares the module. Like KnotFakes, it is compiled only under DEBUG or KNOT_FAKES.
    public enum KnotUIPreviews {
        /// The environment every preview runs on.
        public static var environment: AppEnvironment {
            .preview
        }
    }
#endif
