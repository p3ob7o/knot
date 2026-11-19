// WP-18 proof step: a throwaway app that runs InkProbe in a foreground app process, on the
// iOS Simulator and on the Mac, and tests hosted in that app. PKStrokeRecognizer refuses a
// process that is not a permitted app in an acceptable state (docs/notes/WP-18.md), so the
// package tests alone cannot show recognition.
//
// SwiftPM compiles this file into KnotInkTests with nothing in it, because only the probe
// project sets KNOT_INK_PROBE_APP. The project is not part of Knot's project.yml. To build
// it, write the spec below to project.yml in a folder outside the worktree, then run
// `KNOT_ROOT=<worktree> xcodegen generate` there.
//
//   name: InkProbe
//   options: { deploymentTarget: { iOS: "27.0", macOS: "27.0" } }
//   settings:
//     base:
//       SWIFT_VERSION: "6.0"
//       SWIFT_TREAT_WARNINGS_AS_ERRORS: YES
//       SWIFT_ACTIVE_COMPILATION_CONDITIONS: $(inherited) KNOT_INK_PROBE_APP
//       CODE_SIGN_IDENTITY: "-"
//       CODE_SIGN_STYLE: Manual
//       DEVELOPMENT_TEAM: ""
//       GENERATE_INFOPLIST_FILE: YES
//       ENABLE_HARDENED_RUNTIME: NO
//   targets:
//     InkProbe:
//       type: application
//       supportedDestinations: [iOS, macOS]
//       sources:
//         - ${KNOT_ROOT}/Packages/KnotKit/Tests/KnotInkTests/InkFixture.swift
//         - ${KNOT_ROOT}/Packages/KnotKit/Tests/KnotInkTests/InkProbe.swift
//         - ${KNOT_ROOT}/Packages/KnotKit/Tests/KnotInkTests/ProbeApp/ProbeApp.swift
//       settings:
//         base:
//           PRODUCT_BUNDLE_IDENTIFIER: com.p3ob7o.knot.dev.inkprobe
//           INFOPLIST_KEY_UIApplicationSceneManifest_Generation: YES
//           INFOPLIST_KEY_UILaunchScreen_Generation: YES
//     InkProbeTests:
//       type: bundle.unit-test
//       supportedDestinations: [iOS, macOS]
//       sources:
//         - ${KNOT_ROOT}/Packages/KnotKit/Tests/KnotInkTests/ProbeApp/ProbeHostedTests.swift
//       settings:
//         base:
//           PRODUCT_BUNDLE_IDENTIFIER: com.p3ob7o.knot.dev.inkprobe.tests
//           TEST_HOST: $(BUILT_PRODUCTS_DIR)/InkProbe.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/InkProbe
//           BUNDLE_LOADER: $(TEST_HOST)
//       dependencies:
//         - target: InkProbe
//
// The app runs every probe at launch and prints its lines. Launched with the environment
// variable KNOT_INK_PROBE_BACKGROUND=1, it waits instead until it goes to the background,
// then asks for recognition there, holding background time. With KNOT_INK_PROBE_EXPORT
// set to a path, it writes the `line` drawing's data there and exits. Launched as a
// test host (XCTestConfigurationFilePath is set), it does nothing, and the hosted tests run
// the probes.

#if KNOT_INK_PROBE_APP
    import Foundation
    import SwiftUI
    #if os(iOS)
        import UIKit
    #else
        import AppKit
    #endif

    @main
    struct ProbeApp: App {
        init() {
            let environment = ProcessInfo.processInfo.environment
            guard environment["XCTestConfigurationFilePath"] == nil else { return }
            let say: InkProbe.Report = { line in
                print(line)
                fflush(stdout)
            }
            if let path = environment["KNOT_INK_PROBE_EXPORT"] {
                // Writes the `line` fixture's drawing data, for KnotInkCrashHost to decode.
                let data = (try? InkFixture.load("line").drawing().dataRepresentation()) ?? Data()
                FileManager.default.createFile(atPath: path, contents: data)
                exit(0)
            }
            if environment["KNOT_INK_PROBE_BACKGROUND"] == "1" {
                Self.waitForBackground(say)
            } else {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    say("ink-proof [\(InkProbe.place), app] state at start: \(Self.state)")
                    do {
                        try await InkProbe.all(host: "app") { say($0) }
                    } catch {
                        say("ink-proof [\(InkProbe.place), app] probe failed: \(error)")
                    }
                    say("ink-proof [\(InkProbe.place), app] done")
                    exit(0)
                }
            }
        }

        var body: some Scene {
            WindowGroup { Text("InkProbe") }
        }

        @MainActor static var state: String {
            #if os(iOS)
                switch UIApplication.shared.applicationState {
                case .active: "active"
                case .inactive: "inactive"
                case .background: "background"
                @unknown default: "unknown"
                }
            #else
                NSApplication.shared.isActive ? "active" : "not active"
            #endif
        }

        static func waitForBackground(_ say: @escaping InkProbe.Report) {
            #if os(iOS)
                let name = UIApplication.didEnterBackgroundNotification
            #else
                let name = NSApplication.didResignActiveNotification
            #endif
            let tag = "ink-proof [\(InkProbe.place), app-background]"
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                say("\(tag) state before: \(state)")
                _ = try? await InkProbe.once { say("\(tag) \($0)") }
                say("\(tag) waiting for the background")
            }
            // The observer runs on the main queue as the notification is posted. On iOS it
            // takes background time at once, because a suspended app runs nothing.
            nonisolated(unsafe) var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    if let observer { NotificationCenter.default.removeObserver(observer) }
                    #if os(iOS)
                        let task = UIApplication.shared.beginBackgroundTask(withName: "ink-probe")
                        say(
                            "\(tag) state now: \(state), background time left \(UIApplication.shared.backgroundTimeRemaining) s"
                        )
                    #else
                        say("\(tag) state now: \(state)")
                    #endif
                    Task { @MainActor in
                        for attempt in 1...3 {
                            _ = try? await InkProbe.once { say("\(tag) attempt \(attempt): \($0)") }
                            try? await Task.sleep(for: .seconds(1))
                        }
                        #if os(iOS)
                            UIApplication.shared.endBackgroundTask(task)
                        #endif
                        say("\(tag) done")
                        exit(0)
                    }
                }
            }
        }
    }
#endif
