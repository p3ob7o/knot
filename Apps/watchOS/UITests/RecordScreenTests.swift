import XCTest

/// The record screen on the preview environment: the scripted recorder and the fake link, with
/// the real coordinator over them (docs/architecture.md §16). Each press's date comes from a
/// fixed step, so the one-second rule rests on no time of the test's own. Every test ends with
/// the system's accessibility audit.
final class RecordScreenTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The app on the preview environment, with each press dated `gap` seconds after the one
    /// before.
    @MainActor
    private func launchPreview(gap: Double, _ more: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [WatchLaunch.previewArgument, WatchLaunch.pressGapArgument, "\(gap)"] + more
        app.launch()
        return app
    }

    @MainActor
    private func status(_ app: XCUIApplication, is text: String) -> Bool {
        app.staticTexts["knot.status"].waitForExistence(timeout: 30) && app.staticTexts["knot.status"].label == text
    }

    @MainActor
    private func waitForLabel(_ element: XCUIElement, _ label: String) -> Bool {
        let predicate = NSPredicate(format: "label == %@", label)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 30)
            == .completed
    }

    @MainActor
    func testTwoPressesMoreThanASecondApartSave() throws {
        let app = launchPreview(gap: 2)
        let record = app.buttons["knot.record"]
        XCTAssertTrue(record.waitForExistence(timeout: 30))
        XCTAssertEqual(record.label, "Start recording")
        XCTAssertFalse(app.staticTexts["knot.status"].exists, "Nothing is said before the first press.")
        record.tap()
        XCTAssertTrue(waitForLabel(record, "Stop recording"))
        XCTAssertTrue(status(app, is: "Recording"))
        try app.auditAccessibility()
        record.tap()
        XCTAssertTrue(waitForLabel(app.staticTexts["knot.status"], "Saved"))
        XCTAssertTrue(waitForLabel(record, "Start recording"))
        try app.auditAccessibility()
    }

    @MainActor
    func testASecondPressWithinASecondKeepsNothing() throws {
        let app = launchPreview(gap: 0.2)
        let record = app.buttons["knot.record"]
        XCTAssertTrue(record.waitForExistence(timeout: 30))
        record.tap()
        XCTAssertTrue(waitForLabel(record, "Stop recording"))
        record.tap()
        XCTAssertTrue(waitForLabel(app.staticTexts["knot.status"], "Too short. Nothing was kept."))
        XCTAssertTrue(waitForLabel(record, "Start recording"))
        try app.auditAccessibility()
    }

    @MainActor
    func testARecordingThatCannotStartSaysWhy() throws {
        let app = launchPreview(gap: 2, [WatchLaunch.startFailsArgument])
        let record = app.buttons["knot.record"]
        XCTAssertTrue(record.waitForExistence(timeout: 30))
        record.tap()
        XCTAssertTrue(
            waitForLabel(
                app.staticTexts["knot.status"],
                "Couldn't start recording. Allow the microphone for Knot in Settings."))
        XCTAssertEqual(record.label, "Start recording", "Nothing implies that Knot records.")
        try app.auditAccessibility()
        // The next press starts, as the failure was for one start only.
        record.tap()
        XCTAssertTrue(waitForLabel(record, "Stop recording"))
        XCTAssertTrue(status(app, is: "Recording"))
    }
}

/// The launch arguments: only a debug build honours them.
final class WatchLaunchTests: XCTestCase {
    func testAReleaseBuildIgnoresEveryArgument() {
        let every = [
            WatchLaunch.previewArgument, WatchLaunch.injectedAudioArgument, WatchLaunch.startFailsArgument,
            WatchLaunch.pressGapArgument, "2",
        ]
        XCTAssertEqual(WatchLaunch.mode(arguments: every, honoursDebugArguments: false), .live)
        XCTAssertEqual(WatchLaunch.mode(arguments: [WatchLaunch.previewArgument], honoursDebugArguments: false), .live)
        XCTAssertEqual(
            WatchLaunch.mode(arguments: [WatchLaunch.injectedAudioArgument], honoursDebugArguments: false), .live)
    }

    func testADebugBuildHonoursThem() {
        XCTAssertEqual(WatchLaunch.mode(arguments: [], honoursDebugArguments: true), .live)
        XCTAssertEqual(
            WatchLaunch.mode(arguments: [WatchLaunch.injectedAudioArgument], honoursDebugArguments: true),
            .injectedAudio)
        XCTAssertEqual(
            WatchLaunch.mode(arguments: [WatchLaunch.previewArgument], honoursDebugArguments: true),
            .preview(WatchPreview()))
        XCTAssertEqual(
            WatchLaunch.mode(
                arguments: [
                    WatchLaunch.previewArgument, WatchLaunch.startFailsArgument, WatchLaunch.pressGapArgument, "0.2",
                ],
                honoursDebugArguments: true),
            .preview(WatchPreview(startFails: true, pressGap: 0.2)))
        // A gap that is not a number of seconds is left out.
        XCTAssertEqual(
            WatchLaunch.mode(
                arguments: [WatchLaunch.previewArgument, WatchLaunch.pressGapArgument, "-1"],
                honoursDebugArguments: true),
            .preview(WatchPreview()))
    }

    func testThisTestBundleIsBuiltAsTheAppIs() {
        // The tests above pass the build's kind in; the app reads it from its own build.
        #if DEBUG
            XCTAssertTrue(WatchLaunch.isDebugBuild)
        #else
            XCTAssertFalse(WatchLaunch.isDebugBuild)
        #endif
    }
}
