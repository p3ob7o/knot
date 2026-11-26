import Foundation
import SwiftUI

/// The simulator host uses the same preview bodies that Xcode displays.
@main
struct PreviewRenderer: App {
    private let arguments = ProcessInfo.processInfo.arguments
    private var index: Int { arguments.dropFirst().first.flatMap(Int.init) ?? 0 }
    private var size: DynamicTypeSize { arguments.dropFirst(2).first == "ax5" ? .accessibility5 : .large }

    var body: some Scene {
        WindowGroup {
            phonePreview(index)
                .environment(\.dynamicTypeSize, size)
                .environment(\.matrixReadyFile, readyFile)
        }
    }

    private var readyFile: URL? {
        guard let variant = arguments.dropFirst(3).first else { return nil }
        return FileManager.default.temporaryDirectory.appending(path: "\(index)-\(variant).ready")
    }
}
