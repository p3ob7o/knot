import Testing

@testable import Knot

/// Tests hosted in the iOS app, for what runs only there, such as `RecordingActivity`
/// (docs/architecture.md §5).
@Test @MainActor func appBuildsItsBody() {
    _ = KnotIOSApp().body
}
