import XCTest

/// The launch smoke test: the app starts on its one screen, the record control.
/// It runs the true live composition, the microphone's input and the Watch's own folders, and
/// never presses.
final class KnotWatchLaunchTests: XCTestCase {
    @MainActor
    func testLaunchShowsTheMark() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["knot.record"].waitForExistence(timeout: 30))
        try app.auditAccessibility()
    }
}
