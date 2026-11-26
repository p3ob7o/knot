import XCTest

/// The skeleton's UI smoke tests, on the iPhone and the iPad simulators. Every launch goes
/// through `KnotLauncher`, so the app carries the agent's mark. Synthetic text only.
final class KnotIOSLaunchTests: XCTestCase {
    /// The longest any wait of these tests lasts before it fails.
    let limit: TimeInterval = 600

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
        XCTAssertTrue(segment(line, in: app).waitForExistence(timeout: limit))
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

    @MainActor
    func testRecordsInjectedAudioAndShowsItsVoiceSegment() throws {
        let app = KnotLauncher.launch(.preview)
        let record = app.buttons["Record"]
        XCTAssertTrue(record.waitForExistence(timeout: limit))
        record.tap()

        let stop = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Stop recording")).firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: limit))
        XCTAssertFalse(captureField(in: app).exists)
        try app.auditAccessibility()

        // The visible elapsed time is the witness that this was a deliberate stop.
        let elapsed = expectation(
            for: NSPredicate(format: "label BEGINSWITH %@ AND NOT label ENDSWITH %@", "Stop recording,", "0:00"),
            evaluatedWith: stop)
        wait(for: [elapsed], timeout: limit)
        stop.tap()
        XCTAssertTrue(segment("a scripted transcript of a recording", in: app).waitForExistence(timeout: limit))
        try app.auditAccessibility()
    }

    @MainActor
    func testSearchDeleteAndUndoANote() throws {
        let line = "Quartz instruments"
        let app = KnotLauncher.launch(.preview)
        app.typeText(line)
        try assertStreamShows(line, in: app)
        let search = app.searchFields.firstMatch
        if !search.exists { app.buttons["Search"].tap() }
        XCTAssertTrue(search.waitForExistence(timeout: limit))
        search.tap()
        app.typeText("Quartz")
        let match = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", line)).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: limit))
        match.tap()
        app.buttons["Note actions"].tap()
        app.buttons["Delete note"].tap()
        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: limit))
        undo.tap()
        XCTAssertTrue(match.waitForExistence(timeout: limit))
        try app.auditAccessibility()
    }

    /// `ui-smoke-move-segment-and-undo-iphone`
    @MainActor
    func testMovesASegmentAndUndoesTheMove() throws {
        let app = KnotLauncher.launch(.preview)
        let first = "First synthetic segment"
        let second = "Second synthetic segment"
        try openTwoSegmentNote(first, second, in: app)
        let menus = app.buttons.matching(identifier: "Segment actions")
        XCTAssertTrue(menus.element(boundBy: 1).waitForExistence(timeout: limit))
        menus.element(boundBy: 1).tap()
        app.buttons["Move to its own note"].tap()
        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: limit))
        XCTAssertFalse(segment(second, in: app).exists)
        XCTAssertTrue(segment(first, in: app).exists)
        undo.tap()
        XCTAssertTrue(segment(second, in: app).waitForExistence(timeout: limit))
        try app.auditAccessibility()
    }

    @MainActor
    func testSegmentsHaveIndependentEditors() throws {
        let app = KnotLauncher.launch(.preview)
        let first = "First editable segment"
        let second = "Second editable segment"
        try openTwoSegmentNote(first, second, in: app)
        let editor = segment(second, in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: limit))
        editor.tap()
        editor.press(forDuration: 1)
        let selectAll = app.menuItems["Select All"].firstMatch
        if selectAll.exists {
            selectAll.tap()
        } else if app.buttons["Select All"].exists {
            app.buttons["Select All"].tap()
        } else {
            // Replace the exact contents of this editor through its own keyboard input.
            editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: second.count))
        }
        editor.typeText("Changed segment")
        segment(first, in: app).tap()
        XCTAssertTrue(segment("Changed segment", in: app).waitForExistence(timeout: limit))
        XCTAssertTrue(segment(first, in: app).exists)
        try app.auditAccessibility()
    }

    /// `ui-late-capture-through-preview-iphone`
    @MainActor
    func testPreviewShowsALateArrivalUntilItsNoteOpens() throws {
        let app = KnotLauncher.application(.preview)
        app.launchArguments += ["-KnotPreviewLateCapture"]
        app.launch()
        try assertStreamShows("A synthetic late arrival", in: app)
        let notice = app.staticTexts["A capture arrived."]
        XCTAssertTrue(notice.waitForExistence(timeout: limit))
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "A synthetic late arrival"))
            .firstMatch
        XCTAssertTrue(row.label.contains("Arrived"))
        row.tap()
        XCTAssertTrue(segment("A synthetic late arrival", in: app).waitForExistence(timeout: limit))
        app.navigationBars.buttons["Notes"].tap()
        XCTAssertTrue(notice.waitForNonExistence(timeout: limit))
        XCTAssertFalse(row.label.contains("Arrived"))
        try app.auditAccessibility()
    }

    // MARK: Helpers

    @MainActor
    private func captureField(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["Capture field"]
    }

    @MainActor
    private func segment(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "value == %@", text)).firstMatch
    }

    @MainActor
    private func openTwoSegmentNote(_ first: String, _ second: String, in app: XCUIApplication) throws {
        let field = captureField(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: limit))
        app.typeText(first)
        app.buttons["Done"].tap()
        XCTAssertTrue(segment(first, in: app).waitForExistence(timeout: limit))
        field.tap()
        app.typeText(second)
        try assertStreamShows(second, in: app)
        app.buttons.containing(NSPredicate(format: "label CONTAINS %@", second)).firstMatch.tap()
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
