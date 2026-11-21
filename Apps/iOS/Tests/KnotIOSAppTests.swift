import Foundation
import Testing
import UIKit

@testable import Knot

/// Tests hosted in the iOS app, for what runs only there, such as `RecordingActivity`
/// (docs/architecture.md §5).
@Test @MainActor func appBuildsItsBody() {
    _ = KnotIOSApp().body
}

/// Knot has one window on the iPad (assumption A36). The built app's scene manifest allows no
/// second scene, and the running app says it does not support more than one.
@Test @MainActor func theBuiltAppAllowsOneSceneOnly() throws {
    let manifest = try #require(
        Bundle.main.object(forInfoDictionaryKey: "UIApplicationSceneManifest") as? [String: Any])
    let multiple = try #require(manifest["UIApplicationSupportsMultipleScenes"] as? Bool)
    #expect(multiple == false)
    #expect(UIApplication.shared.supportsMultipleScenes == false)
}
