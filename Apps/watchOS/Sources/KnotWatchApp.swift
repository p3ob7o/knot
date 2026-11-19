import KnotAudio
import KnotCore
import KnotLink
import KnotUI
import SwiftUI

/// The Watch app. It does not use KnotApp or the capture engine: it composes the recorder,
/// the link to the iPhone and the UI itself (docs/architecture.md §3).
@main
struct KnotWatchApp: App {
    private let environment = KnotUILive.wire(KnotLinkLive.wire(KnotAudioLive.wire(.unavailable)))

    var body: some Scene {
        WindowGroup {
            PlaceholderView()
        }
    }
}
