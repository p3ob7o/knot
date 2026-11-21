import KnotCore

/// The live entry point of KnotCleanup. It provides `Cleaner`.
///
/// KnotApp calls `wire(_:)` when it builds `.live`, so the cleaner is wired in without an edit
/// to `Sources/KnotApp/`. Where Foundation Models is, the cleaner is `ModelCleaner` on Apple's
/// on-device model, in full cleanup. On the Watch, which has no such model and cleans nothing
/// (its iPhone does), the cleaner stays the unavailable one.
public enum KnotCleanupLive {
    public static func wire(_ environment: AppEnvironment) -> AppEnvironment {
        guard let cleaner = cleaner() else { return environment }
        var environment = environment
        environment.cleaner = cleaner
        return environment
    }

    /// The cleaner on this device's model, or `nil` on a platform without one.
    public static func cleaner(mode: CleanupMode = .full) -> ModelCleaner? {
        #if canImport(FoundationModels) && !os(watchOS)
            ModelCleaner(model: SystemCleanupModel(), mode: mode)
        #else
            nil
        #endif
    }
}
