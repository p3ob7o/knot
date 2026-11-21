import XCTest

/// The skeleton's UI smoke test, on the iPhone and the iPad simulators: Knot launches straight
/// into capture with the field focused, a typed line is saved, and the stream shows it.
/// It runs on the environment the factory gives a debug build.
final class KnotIOSLaunchTests: XCTestCase {
    /// Synthetic text only.
    let line = "A synthetic line for the skeleton"

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchIntoCaptureTypeAndFindTheLineInTheStream() throws {
        let app = XCUIApplication()
        app.launch()

        let field = app.descendants(matching: .any)["Capture field"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "The capture surface is on screen at launch.")
        try app.auditAccessibility()

        // No tap: the field has the keyboard's focus when the surface appears
        // (docs/product-spec.md §4.1), so the keystrokes reach it as they are.
        app.typeText(line)
        XCTAssertEqual(field.value as? String, line)

        // The stream is one step away. Leaving the surface ends the capture, and the stream
        // shows the line.
        app.buttons["shell.notes"].tap()
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", line)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "The stream shows the typed line.")
        try app.auditAccessibility()
    }
}
