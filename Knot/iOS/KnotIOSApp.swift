import SwiftUI
import KnotKit

@main
struct KnotIOSApp: App {
    @State private var model = EditorModel()

    var body: some Scene {
        WindowGroup {
            ContentScreen(model: model)
        }
    }
}
