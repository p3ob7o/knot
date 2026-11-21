import XCTest

/// The skeleton's launch smoke test, on the environment the factory gives a debug build: the
/// main window opens on the capture surface with the field focused, a typed line is saved, and
/// the stream beside it shows the line.
final class KnotMacLaunchTests: XCTestCase {
    /// Synthetic text only.
    let line = "A synthetic line for the Mac skeleton"

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchIntoCaptureTypeAndFindTheLineInTheStream() throws {
        let app = XCUIApplication()
        // Ignores the saved window state, which every development build shares
        // (`launchForSmokeTest()`).
        app.launchForSmokeTest()

        let field = app.descendants(matching: .any)["Capture field"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "The capture surface is on screen at launch.")
        try audit(app)

        // No click: the field has the keyboard's focus when the surface appears
        // (docs/product-spec.md §4.1), so the keystrokes reach it as they are.
        app.typeText(line)
        XCTAssertEqual(field.value as? String, line)

        // The stream lists a note while its typed capture is open, so the row shows the line
        // once the store has committed the save. The row is the one element whose label holds
        // the line: the field holds it as its value, under the label "Capture field".
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", line)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "The stream shows the typed line.")
        try audit(app)
    }

    /// Runs the accessibility audit on the app in front. Another thread's launch step can start
    /// a build with the same bundle ID, and a newly started app comes to the front.
    @MainActor
    private func audit(_ app: XCUIApplication) throws {
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "The app is in front.")
        try app.auditAccessibility()
    }
}
