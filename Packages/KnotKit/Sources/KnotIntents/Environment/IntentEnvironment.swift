import AppIntents
import KnotCore

/// What the App Intents dependency manager holds for Knot: the environment the app registered
/// at launch, or none (docs/architecture.md §14).
///
/// `AppDependencyManager` has no lookup that can fail, so every intent and query declares its
/// dependency with this type's `unavailable` value as the default. In a process that registered
/// nothing, such as an extension the system ran an intent in by mistake, the intent gets the
/// unavailable value, and `environment()` throws.
public struct KnotIntentEnvironment: Sendable {
    private let registered: AppEnvironment?

    /// The environment of a process that registered one.
    public init(_ environment: AppEnvironment) {
        registered = environment
    }

    private init() {
        registered = nil
    }

    /// The default of every intent's dependency: nothing registered.
    public static let unavailable = KnotIntentEnvironment()

    /// The one accessor of the environment for the intents: the registered environment, or the
    /// typed error `port_unavailable` when nothing is registered.
    public func environment() throws(KnotError) -> AppEnvironment {
        guard let registered else { throw KnotError.portUnavailable }
        return registered
    }

    /// Registers `environment` with `manager`. A later registration replaces an earlier one.
    public static func register(_ environment: AppEnvironment, in manager: AppDependencyManager) {
        let value = KnotIntentEnvironment(environment)
        manager.add(dependency: value)
    }
}

/// An intent or a query that reads the environment, through the one accessor.
public protocol KnotEnvironmentReading {
    /// The dependency, declared `@Dependency(default: KnotIntentEnvironment.unavailable)`.
    var knot: KnotIntentEnvironment { get }
}

extension KnotEnvironmentReading {
    /// The registered environment, or the typed error when nothing is registered.
    public func environment() throws(KnotError) -> AppEnvironment {
        try knot.environment()
    }
}
