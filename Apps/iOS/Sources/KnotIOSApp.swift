import KnotCore
import SwiftUI
import UIKit

/// The iPhone and iPad app: a thin shell over KnotApp and KnotUI (docs/architecture.md §2).
/// It takes its environment and its context from the composition's one call, and starts the
/// launch sequence once the capture surface is on screen.
/// It launches straight into capture with the keyboard up, and the stream is one step away.
/// The iPad has the iPhone's layout from M1 on (docs/plan/WP-30.md).
///
/// Knot has one window on the iPad (assumption A36): the Info.plist's scene manifest allows
/// no second scene, and a hosted test reads that from the built app.
@main
struct KnotIOSApp: App {
    @UIApplicationDelegateAdaptor(IOSAppDelegate.self) private var appDelegate
    @State private var shell = Shell()

    var body: some Scene {
        WindowGroup {
            ShellView(shell: shell)
        }
    }
}

/// Receives the URL before SwiftUI chooses the first presentation.
@MainActor
final class IOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication, configurationForConnecting session: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        if session.role == .windowApplication { configuration.delegateClass = IOSSceneDelegate.self }
        return configuration
    }
}

@MainActor
final class IOSSceneDelegate: NSObject, UIWindowSceneDelegate, ObservableObject {
    struct Connection: Equatable {
        let destination: SurfaceDestination?
    }

    @Published private(set) var connection: Connection?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        let destination = options.urlContexts.lazy.compactMap { Shell.destination(for: $0.url) }.first
        connection = Connection(destination: destination)
    }

    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        guard let destination = contexts.lazy.compactMap({ Shell.destination(for: $0.url) }).first else { return }
        Task { await Shell.open(destination) }
    }
}
