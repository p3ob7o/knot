import XCTest

/// The one way a UI test launches Knot, on iOS, macOS and watchOS. Every UI test's launch
/// goes through it, and no test makes an `XCUIApplication` of its own.
///
/// Every launch carries the agent's mark, `KNOT_AGENT=1`, in the app's environment. The app that
/// `XCUIApplication` starts on the Mac holds no test bundle, no test runner's variables and no
/// simulator, and with `.live` it holds a live recorder. The mark is what makes the recorder's
/// `HardwareInputPolicy` refuse the hardware microphone in it, and KnotSpeech's
/// `SpeechInstallPolicy` refuse a model install. No UI test records, and no test opens a
/// hardware microphone on the build Mac.
///
/// The environments:
/// - `.preview`, the fakes behind the real engine, for every UI test but the `.live` smoke tests.
///   It passes `-KnotPreview`, which only a debug build honours.
/// - `.live(temporaryStore:)`, the live environment on a temporary store of that name, for the
///   smoke tests: type, kill, relaunch, read. It passes `-KnotTemporaryStore <name>`, which only a
///   debug build honours. To relaunch on the same store after a kill, call `terminate()` on the
///   application this returns and `launch()` on it again: it keeps its arguments, and so its
///   store. A new name is a new, empty store.
enum KnotLauncher {
    enum Environment: Equatable {
        case preview
        /// A name of letters, digits, `.`, `_` and `-`, at most 64 characters, such as a UUID.
        case live(temporaryStore: String)
    }

    /// The mark of an agent's process, which every launch sets.
    static let agentMark = ["KNOT_AGENT": "1"]

    /// What every launch passes besides its environment's arguments. On the Mac, the app ignores
    /// its saved window state: every worktree's development build has one bundle ID, so they
    /// share one saved state, and a build that quit with its window closed would leave the next
    /// launch of any build with no window. `ApplePersistenceIgnoreState` is a user default that
    /// AppKit reads from the argument domain; the SDK declares no symbol for it
    /// (`NSWindowRestoration.h` describes the restoration it turns off). Only the window state is
    /// ignored: a relaunch on the same temporary store still reads the store.
    static var everyLaunch: [String] {
        #if os(macOS)
            ["-ApplePersistenceIgnoreState", "YES"]
        #else
            []
        #endif
    }

    /// The launch arguments of `environment`.
    static func arguments(for environment: Environment) -> [String] {
        switch environment {
        case .preview: ["-KnotPreview"]
        case .live(let name): ["-KnotTemporaryStore", name]
        }
    }

    /// The application, set up for `environment`, not launched yet.
    @MainActor
    static func application(_ environment: Environment = .preview) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments(for: environment) + everyLaunch
        for (name, value) in agentMark { app.launchEnvironment[name] = value }
        return app
    }

    /// Launches the application for `environment` and returns it.
    @MainActor
    @discardableResult
    static func launch(_ environment: Environment = .preview) -> XCUIApplication {
        let app = application(environment)
        app.launch()
        return app
    }

    /// A fresh name for a temporary store.
    static func newTemporaryStore() -> String { "uitest-\(UUID().uuidString.lowercased())" }
}

/// The launcher's own checks. No app is launched.
final class KnotLauncherTests: XCTestCase {
    /// The app the launcher starts carries the agent's mark in every environment, which
    /// `HardwareInputPolicy` reads as a refusal of the hardware input before it touches the
    /// hardware (KnotEndToEndTests proves the policy refuses a process launched so).
    @MainActor
    func testEveryLaunchCarriesTheAgentMark() {
        for environment: KnotLauncher.Environment in [
            .preview, .live(temporaryStore: KnotLauncher.newTemporaryStore()),
        ] {
            let app = KnotLauncher.application(environment)
            XCTAssertEqual(app.launchEnvironment["KNOT_AGENT"], "1", "\(environment)")
        }
    }

    @MainActor
    func testTheEnvironmentsSelectTheirArguments() {
        XCTAssertEqual(KnotLauncher.application(.preview).launchArguments, ["-KnotPreview"] + KnotLauncher.everyLaunch)
        XCTAssertEqual(
            KnotLauncher.application(.live(temporaryStore: "smoke-1")).launchArguments,
            ["-KnotTemporaryStore", "smoke-1"] + KnotLauncher.everyLaunch)
        #if os(macOS)
            XCTAssertEqual(KnotLauncher.everyLaunch, ["-ApplePersistenceIgnoreState", "YES"])
        #endif
        XCTAssertNotEqual(KnotLauncher.newTemporaryStore(), KnotLauncher.newTemporaryStore())
    }
}
