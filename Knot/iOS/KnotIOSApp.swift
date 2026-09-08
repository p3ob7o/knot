import KnotKit
import SwiftUI
import UIKit

@main
struct KnotIOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = EditorModel()
    @State private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    var body: some Scene {
        WindowGroup {
            ContentScreen(model: model)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        endBackgroundTask()
                        Task { await model.resumePendingWork() }
                    case .inactive:
                        Task { await model.flushDraft() }
                    case .background:
                        beginBoundedBackgroundFlush()
                    @unknown default:
                        Task { await model.flushDraft() }
                    }
                }
        }
    }

    private func beginBoundedBackgroundFlush() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Knot durable capture") {
            endBackgroundTask()
        }
        Task {
            await model.flushDraft()
            endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
