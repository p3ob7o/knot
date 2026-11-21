import XCTest

/// The launch smoke test: the app starts and shows the mark. It launches through
/// `KnotLauncher`, as every UI test does, so the app carries the agent's mark.
final class KnotIOSLaunchTests: XCTestCase {
    @MainActor
    func testLaunchShowsTheMark() throws {
        let app = KnotLauncher.launch(.preview)
        XCTAssertTrue(app.images["knot.mark"].waitForExistence(timeout: 30))
        try app.auditAccessibility()
    }
}
