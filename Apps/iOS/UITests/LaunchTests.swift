import UIKit
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
        assertCaptureIsReady(in: app)
        let firstScreen = XCTAttachment(screenshot: app.screenshot())
        firstScreen.name = "Launch capture"
        firstScreen.lifetime = .keepAlways
        add(firstScreen)

        // No tap: the field has the keyboard's focus when the surface appears
        // (docs/product-spec.md §4.1), so the keystrokes reach it as they are.
        app.typeText(line)
        XCTAssertEqual(field.value as? String, line)
        try app.auditAccessibility()

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
        assertCaptureIsReady(in: app)
        app.typeText(line)
        XCTAssertEqual(field.value as? String, line)
        try app.auditAccessibility()

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
        XCTAssertTrue(captureField(in: app).waitForNonExistence(timeout: limit))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: limit))
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
    func testNotesShowsLiveRecordingAfterClosingCapture() throws {
        let app = KnotLauncher.launch(.preview)
        let record = app.buttons["Record"]
        XCTAssertTrue(record.waitForExistence(timeout: limit))
        let notice = app.buttons["shell.recordingNotice"]
        XCTAssertFalse(notice.exists)
        record.tap()

        let stop = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Stop recording")).firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: limit))
        app.buttons["shell.notes"].tap()

        XCTAssertTrue(notice.waitForExistence(timeout: limit))
        XCTAssertTrue(stop.waitForNonExistence(timeout: limit))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: limit))
        XCTAssertTrue(notice.label.hasPrefix("Recording, "))
        XCTAssertTrue(notice.label.hasSuffix(", Show"))
        XCTAssertGreaterThanOrEqual(notice.frame.height, 44)
        try app.auditAccessibility()

        notice.tap()
        XCTAssertTrue(stop.waitForExistence(timeout: limit))
        XCTAssertTrue(app.staticTexts["Recording. Typing waits until you stop."].waitForExistence(timeout: limit))
        stop.tap()
        XCTAssertTrue(segment("a scripted transcript of a recording", in: app).waitForExistence(timeout: limit))
        app.buttons["shell.notes"].tap()
        XCTAssertTrue(app.buttons["shell.compose"].waitForExistence(timeout: limit))
        XCTAssertTrue(notice.waitForNonExistence(timeout: limit))
    }

    @MainActor
    func testSearchDeleteAndUndoANote() throws {
        let line = "Quartz instruments"
        let app = KnotLauncher.launch(.preview)
        XCTAssertTrue(captureField(in: app).waitForExistence(timeout: limit))
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
        XCTAssertTrue(match.waitForNonExistence(timeout: limit))
        try app.auditAccessibility()
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
        if UIDevice.current.userInterfaceIdiom == .pad {
            let menus = app.buttons.matching(identifier: "Segment actions")
            XCTAssertTrue(menus.element(boundBy: 1).waitForExistence(timeout: limit))
            menus.element(boundBy: 1).tap()
        } else {
            let secondSegment = segment(second, in: app)
            XCTAssertTrue(secondSegment.waitForExistence(timeout: limit))
            secondSegment.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).press(forDuration: 1)
        }
        app.buttons["Move to its own note"].tap()
        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: limit))
        XCTAssertTrue(segment(second, in: app).waitForNonExistence(timeout: limit))
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
        app.typeKey("a", modifierFlags: .command)
        app.typeText("Changed segment")
        segment(first, in: app).tap()
        XCTAssertTrue(segment("Changed segment", in: app).waitForExistence(timeout: limit))
        XCTAssertTrue(segment(first, in: app).exists)
        try app.auditAccessibility()
    }

    /// `ui-late-capture-through-preview-iphone`
    @MainActor
    func testPreviewShowsALateArrivalUntilItsNoteOpens() throws {
        let app = KnotLauncher.application(.preview)
        app.launchEnvironment["KNOT_PREVIEW_LATE_CAPTURE"] = "1"
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

    @MainActor
    func testSearchLinkShowsFocusedSearchOverNotes() throws {
        let app = KnotLauncher.application(.preview)
        app.launchEnvironment["KNOT_PREVIEW_LATE_CAPTURE"] = "1"
        let url = try XCTUnwrap(URL(string: "knot-dev://search"))
        app.open(url)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: limit))
        XCTAssertTrue(captureField(in: app).waitForNonExistence(timeout: limit))
        app.typeText("synthetic late")
        XCTAssertEqual(search.value as? String, "synthetic late")
        let previewNote = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "A synthetic late arrival"))
            .firstMatch
        XCTAssertTrue(previewNote.waitForExistence(timeout: limit))
        try app.auditAccessibility()
    }

    @MainActor
    func testAuditsTheFirstRunAndSettingsScreens() throws {
        let app = KnotLauncher.launch(.preview)
        app.buttons["shell.notes"].tap()
        XCTAssertTrue(app.staticTexts["No notes yet"].waitForExistence(timeout: limit))
        XCTAssertTrue(app.buttons["Dismiss Add a Lock Screen control"].exists)
        try XCTContext.runActivity(named: "Audit first-run Notes") { _ in try app.auditAccessibility() }

        app.buttons["More"].tap()
        app.buttons["Settings"].tap()
        let settings = app.navigationBars["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: limit))
        let about = app.buttons["About"]
        XCTAssertTrue(about.waitForExistence(timeout: limit))
        XCTAssertTrue(about.isEnabled)
        try XCTContext.runActivity(named: "Audit Settings") { _ in try app.auditAccessibility() }

        let variant = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "English variant")).firstMatch
        XCTAssertTrue(variant.waitForExistence(timeout: limit))
        XCTAssertEqual(variant.value as? String, "Follow the region")
        variant.tap()
        let choices = app.navigationBars["English variant"]
        XCTAssertTrue(choices.waitForExistence(timeout: limit))
        try app.auditAccessibility()
        choices.buttons["Settings"].tap()

        about.tap()
        let aboutPage = app.navigationBars["About Knot"]
        XCTAssertTrue(aboutPage.waitForExistence(timeout: limit))
        try app.auditAccessibility()
        aboutPage.buttons["Settings"].tap()
        app.buttons["Export all notes…"].tap()
        XCTAssertTrue(app.buttons["Choose a folder…"].waitForExistence(timeout: limit))
        try app.auditAccessibility()
    }

    @MainActor
    func testFirstRunSetupRowOpensItsSheet() throws {
        let app = KnotLauncher.launch(.preview)
        app.buttons["shell.notes"].tap()
        XCTAssertTrue(app.staticTexts["No notes yet"].waitForExistence(timeout: limit))
        app.buttons["Add a Lock Screen control"].tap()
        XCTAssertTrue(app.navigationBars["Add a Lock Screen control"].waitForExistence(timeout: limit))
        try app.auditAccessibility()
    }

    @MainActor
    func testSettingsActionButtonRowOpensItsSheet() throws {
        let app = KnotLauncher.launch(.preview)
        app.buttons["shell.notes"].tap()
        app.buttons["More"].tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: limit))
        let about = app.buttons["About"]
        XCTAssertTrue(about.waitForExistence(timeout: limit))
        XCTAssertTrue(about.isEnabled)
        let actionButtonSetup = app.buttons["Action Button setup"]
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertFalse(actionButtonSetup.exists)
            return
        }
        actionButtonSetup.tap()
        XCTAssertTrue(app.navigationBars["Record with the Action Button"].waitForExistence(timeout: limit))
        try app.auditAccessibility()
    }

    // MARK: Helpers

    @MainActor
    private func captureField(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["Capture field"]
    }

    @MainActor
    private func assertCaptureIsReady(in app: XCUIApplication) {
        XCTAssertTrue(captureField(in: app).waitForExistence(timeout: limit))
        XCTAssertTrue(app.buttons["shell.notes"].exists)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: limit))
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
        app.navigationBars.buttons["Done"].tap()
        XCTAssertTrue(segment(first, in: app).waitForExistence(timeout: limit))
        field.tap()
        app.typeText(second)
        try assertStreamShows(second, in: app)
        app.buttons.containing(NSPredicate(format: "label CONTAINS %@", second)).firstMatch.tap()
    }

    /// Opens the stream and finds the row of `line`, then audits the stream.
    @MainActor
    private func assertStreamShows(_ line: String, in app: XCUIApplication) throws {
        // The tap itself waits for the app to become idle after it sends the event.
        let start = ContinuousClock.now
        app.buttons["shell.notes"].tap()
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", line)).firstMatch
        let rowAppeared = row.waitForExistence(timeout: limit)
        if start.duration(to: .now) > .seconds(10) {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Slow transition to Notes"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Slow transition to Notes accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertTrue(rowAppeared, "The stream shows the typed line.")
        try app.auditAccessibility()
    }
}
