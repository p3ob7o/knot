// SP-4's spike app. Launched with -SP4SelfTest it prints the self-test's report and exits with
// the result. Launched with -SP4Live it runs one step of stage 2 against CloudKit (LiveRunner);
// only a team-signed iOS build can, and only in a simulator. Otherwise it shows the report.

import SwiftUI

#if os(iOS)
import UIKit

/// Registers for remote notifications only when asked, so statement 5 can compare the
/// engine's scheduled fetches with and without a registration.
final class PushDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if CommandLine.arguments.contains("-SP4RegisterPush") {
            application.registerForRemoteNotifications()
            print("sp4live: push registration requested")
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        print("sp4live: push registered tokenBytes=\(deviceToken.count)")
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        print("sp4live: push registration failed \((error as NSError).code)")
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any])
        async -> UIBackgroundFetchResult {
        print("sp4live: push received at \(Date().timeIntervalSince1970)")
        return .newData
    }
}
#endif

@main
struct SP4App: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate
    #endif
    init() {
        if CommandLine.arguments.contains("-SP4SelfTest") {
            var harness = Harness()
            harness.run()
            print(harness.report())
            fflush(stdout)
            exit(harness.failed == 0 ? 0 : 1)
        }
        if CommandLine.arguments.contains("-SP4Live") {
            let arguments = CommandLine.arguments
            Task.detached {
                let code = await LiveRunner.run(arguments)
                exit(code)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ReportView()
        }
    }
}

struct ReportView: View {
    @State private var report = ""

    var body: some View {
        ScrollView {
            Text(report)
                .font(.body.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .task {
            var harness = Harness()
            harness.run()
            report = harness.report()
        }
    }
}
