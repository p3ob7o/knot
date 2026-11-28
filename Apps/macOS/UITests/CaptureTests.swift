import XCTest

final class MacCaptureTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // ui-late-capture-through-preview-mac
    @MainActor
    func testLateCaptureAppearsWithArrivalNotice() throws {
        let app = KnotLauncher.application(.preview)
        app.launchArguments.append("late-capture")
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.staticTexts["A capture arrived."].waitForExistence(timeout: 30))
        XCTAssertTrue(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@", "A synthetic late arrival")
            ).firstMatch.exists)
        try app.auditAccessibility()
    }

    // ui-smoke-move-segment-and-undo-mac
    @MainActor
    func testMoveAndUndoThroughTheWindowModel() throws {
        let app = KnotLauncher.application(.preview)
        let args = app.launchArguments
        app.launchArguments = args + ["move"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Moved to its own note"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Undo"].exists)
        try app.auditAccessibility()
        app.terminate()

        app.launchArguments = args + ["undo-move"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(status("Move undone", in: app).waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["Undo"].exists)
        let restoredText = "The moved synthetic segment"
        let restoredSegment = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR value == %@", restoredText, restoredText))
            .firstMatch
        XCTAssertTrue(restoredSegment.waitForExistence(timeout: 30))
        try app.auditAccessibility()
    }

    @MainActor
    func testDoneCommandEndsTheTypedCapture() throws {
        let app = KnotLauncher.application(.preview)
        app.launchArguments.append("done")
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(status("Capture finished", in: app).waitForExistence(timeout: 30))
        XCTAssertTrue(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@", "A synthetic line completed by Done")
            ).firstMatch.exists)
        try app.auditAccessibility()
    }

    @MainActor
    func testMainWindowCaptureHasKeyboardFocus() throws {
        let app = KnotLauncher.application(.preview)
        app.launchArguments.append("capture-focus")
        app.launch()
        defer { app.terminate() }
        let focus = app.staticTexts.matching(identifier: "test.capture-focus")
            .matching(
                NSPredicate(format: "label == %@ OR value == %@", "Capture field focused", "Capture field focused")
            )
            .firstMatch
        XCTAssertTrue(focus.waitForExistence(timeout: 30))
        try app.auditAccessibility()
    }
    @MainActor
    private func status(_ message: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(identifier: "test.action")
            .matching(NSPredicate(format: "label == %@ OR value == %@", message, message))
            .firstMatch
    }
}
