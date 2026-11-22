import AppIntents
import KnotCore

/// The live entry point of KnotIntents. KnotApp calls it when it builds `.live`, and it
/// registers that environment with the App Intents dependency manager, so that the intents the
/// system runs in the app's process reach it (docs/architecture.md §14). It returns the
/// environment unchanged: KnotIntents fills no port.
public enum KnotIntentsLive {
    public static func wire(_ environment: AppEnvironment) -> AppEnvironment {
        KnotIntentEnvironment.register(environment, in: .shared)
        return environment
    }
}
