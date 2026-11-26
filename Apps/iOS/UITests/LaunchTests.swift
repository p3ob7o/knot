import XCTest

/// The skeleton's UI smoke tests, on the iPhone and the iPad simulators. Every launch goes
/// through `KnotLauncher`, so the app carries the agent's mark. Synthetic text only.
final class KnotIOSLaunchTests: XCTestCase {
    /// The longest any wait of these tests lasts before it fails.
    let limit: TimeInterval = 60

    override func setUp() {
        continueAfterFailure = false
    }

    /// On `.preview`: Knot launches straight into capture with the field focused, a typed line
    /// is saved, and the stream shows it.
    @MainActor
    func testLaunchIntoCaptureTypeAndFindTheLineInTheStream() throws {
        let line = "A synthetic line for the stream"
        let app = KnotLauncher.launch(.preview)

        let field = captureField(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: limit), "The capture surface is on screen at launch.")
        try app.auditAccessibility()

        // No tap: the field has the keyboard's focus when the surface appears
        // (docs/product-spec.md §4.1), so the keystrokes reach it as they are.
        app.typeText(line)
        XCTAssertEqual(field.value as? String, line)

        // The stream is one step away. Leaving the surface ends the capture, and the stream
        // shows the line.
        try assertStreamShows(line, in: app)
        XCTAssertTrue(app.navigationBars["Notes"].exists)

        // Capture follows the window. The earlier line is on the page and typing
        // goes straight into the new field.
        app.buttons["shell.compose"].tap()
        XCTAssertTrue(app.staticTexts[line].waitForExistence(timeout: limit))
        app.typeText("One more thought")
        XCTAssertEqual(field.value as? String, "One more thought")
    }

    /// `live-smoke-type-kill-relaunch-read-iphone`: on `.live` with a temporary store, type,
    /// kill, relaunch, read (docs/architecture.md §17), with the accessibility audit.
    ///
    /// The first launch types into a store it has just created, so the first keystrokes can
    /// meet a store that is not open yet and go by `Inbox/`, which the relaunch's launch
    /// sequence ingests. Before the kill, the app goes to the background, which flushes the
    /// text through the model and ends the capture (§4.1); the field empties only once the
    /// engine has answered that end. So the kill comes after the line is durable, by an order
    /// the test observes and not by a time.
    @MainActor
    func testLiveTypeKillRelaunchRead() throws {
        let line = "A synthetic line that outlives a kill"
        let app = KnotLauncher.application(.live(temporaryStore: KnotLauncher.newTemporaryStore()))
        app.launch()

        let field = captureField(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: limit), "The capture surface is on screen at launch.")
        try app.auditAccessibility()
        app.typeText(line)
        XCTAssertEqual(field.value as? String, line)

        XCUIDevice.shared.press(.home)
        app.activate()
        let ended = expectation(for: NSPredicate(format: "value != %@", line), evaluatedWith: field)
        wait(for: [ended], timeout: limit)

        // Kill, then relaunch on the same temporary store: the application keeps its arguments.
        app.terminate()
        app.launch()
        XCTAssertTrue(captureField(in: app).waitForExistence(timeout: limit), "The relaunch shows the capture surface.")
        try assertStreamShows(line, in: app)
    }

    // MARK: Helpers

    @MainActor
    private func captureField(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["Capture field"]
    }

    /// Opens the stream and finds the row of `line`, then audits the stream.
    @MainActor
    private func assertStreamShows(_ line: String, in app: XCUIApplication) throws {
        app.buttons["shell.notes"].tap()
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", line)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: limit), "The stream shows the typed line.")
        try app.auditAccessibility()
    }
}
