import Foundation
import KnotCore
import Synchronization

#if DEBUG
    import KnotFakes
#endif

/// The one place where the app shells get their environment (docs/architecture.md §3).
///
/// A shell calls `EnvironmentFactory.app(shell:)` once, with the ports it implements, gives
/// `app.environment` to its views, and starts the launch sequence with
/// `await app.runLaunchSequence()` once its capture surface is on screen, for instance in the
/// `.task` of its root view:
///
/// ```swift
/// private let app = EnvironmentFactory.app(shell: ShellPorts(cues: MyCues()))
/// // …
/// RootView(environment: app.environment)
///     .task { _ = await app.runLaunchSequence() }
/// ```
///
/// The shell's ports are in the environment before any module is wired. The first call builds
/// the app of the process, and every later call, `app` included, returns that one.
///
/// Every build runs on `.live`. A debug build launched with `-KnotPreview` runs on `.preview`
/// instead, as the UI tests other than the `.live` smoke tests do, and one launched with
/// `-KnotTemporaryStore <name>` runs `.live` on a temporary store of that name
/// (`LiveConfiguration`). A release build honours neither argument.
public enum EnvironmentFactory {
    private static let built = Mutex<AppComposition?>(nil)

    /// This process's app, built on the first call with `shell`'s ports.
    public static func app(shell: ShellPorts) -> AppComposition {
        built.withLock { built in
            if let built { return built }
            let app = makeApp(shell: shell)
            built = app
            return app
        }
    }

    /// This process's app, as `app(shell:)` built it, or built now with no port of a shell.
    public static var app: AppComposition { app(shell: ShellPorts()) }

    /// The environment an app shell runs on: `app.environment`.
    public static func make() -> AppEnvironment {
        app.environment
    }

    /// The live environment of this process, whatever the launch arguments select.
    public static var live: AppEnvironment {
        if let live = app.live { return live.environment }
        return LiveComposition(configuration: .current()).environment
    }

    private static func makeApp(shell: ShellPorts) -> AppComposition {
        #if DEBUG
            if LiveConfiguration.selectsPreview(ProcessInfo.processInfo.arguments) {
                return AppComposition(environment: shell.apply(to: .preview), live: nil)
            }
        #endif
        let live = LiveComposition(configuration: .current(), shell: shell)
        return AppComposition(environment: live.environment, live: live)
    }
}

/// What a shell holds: the environment it runs on and, on `.live`, the composition whose launch
/// sequence it starts.
public struct AppComposition: Sendable {
    public let environment: AppEnvironment
    /// The live composition, `nil` on `.preview`.
    public let live: LiveComposition?

    /// Runs the launch sequence once the capture surface is on screen, and returns its report:
    /// `nil` on `.preview`, which has no launch. A second call waits for the first.
    public func runLaunchSequence() async -> LaunchReport? {
        await live?.runLaunchSequence()
    }

    /// The diagnostics file, for the entry in About of a test build. `nil` on `.preview`.
    public func diagnosticsData() async -> Data? {
        await live?.diagnostics.exportData()
    }
}
