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
    func launchPreview(gap: Double, _ more: [String] = []) -> XCUIApplication {
        XCUIApplication.launchedWatch([WatchLaunch.previewArgument, WatchLaunch.pressGapArgument, "\(gap)"] + more)
    }

    @MainActor
    private func status(_ app: XCUIApplication, is text: String) -> Bool {
        waitForLabel(app.staticTexts["knot.status"], text)
    }

    @MainActor
    func waitForLabel(_ element: XCUIElement, _ label: String) -> Bool {
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

extension RecordScreenTests {
    @MainActor
    func testARecordingThatStopsByItselfSaysWhyAndIsSaved() throws {
        let app = launchPreview(gap: 2, [WatchLaunch.endsAtLimitArgument])
        let record = app.buttons["knot.record"]
        XCTAssertTrue(record.waitForExistence(timeout: 30))
        record.tap()
        XCTAssertTrue(
            waitForLabel(
                app.staticTexts["knot.status"], "Recording stopped. It reached the 30-minute limit. Saved"))
        XCTAssertTrue(waitForLabel(record, "Start recording"))
        try app.auditAccessibility()
    }
}

/// The smoke test on the real composition: the live recorder, the coordinator and the outbox,
/// on injected audio and a temporary store, since a simulator refuses the microphone
/// (docs/architecture.md §8). Press, wait over a second, press, and "Saved" is on the screen.
final class RealCompositionSmokeTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testARecordingOnTheRealCompositionIsSaved() throws {
        let app = XCUIApplication.launchedWatch([WatchLaunch.injectedAudioArgument])
        let record = app.buttons["knot.record"]
        let status = app.staticTexts["knot.status"]
        XCTAssertTrue(record.waitForExistence(timeout: 30))
        record.tap()
        XCTAssertTrue(waitForLabel(record, "Stop recording"))
        XCTAssertTrue(waitForLabel(status, "Recording"))
        try app.auditAccessibility()
        // The second press comes more than a second after the first. A wait of at least that
        // long is all this needs: a loaded Mac only makes it longer.
        let atLeastASecond = XCTestExpectation(description: "over a second passes")
        atLeastASecond.isInverted = true
        _ = XCTWaiter().wait(for: [atLeastASecond], timeout: 1.5)
        record.tap()
        XCTAssertTrue(waitForLabel(status, "Saved"))
        XCTAssertTrue(waitForLabel(record, "Start recording"))
        try app.auditAccessibility()
    }

    @MainActor
    private func waitForLabel(_ element: XCUIElement, _ label: String) -> Bool {
        let predicate = NSPredicate(format: "label == %@", label)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 60)
            == .completed
    }
}

extension XCUIApplication {
    /// The settings of the test run that the app takes too: the strict cooperative pool, which
    /// makes a blocked thread of Swift's pool show up as a hang in the app as in a package test.
    static let forwardedEnvironment = ["LIBDISPATCH_COOPERATIVE_POOL_STRICT"]

    /// The Watch app, launched with `arguments` and the forwarded settings of this run.
    @MainActor
    static func launchedWatch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        let environment = ProcessInfo.processInfo.environment
        for name in forwardedEnvironment {
            if let value = environment[name] { app.launchEnvironment[name] = value }
        }
        app.launch()
        return app
    }
}

/// The launch arguments: only a debug build honours them.
final class WatchLaunchTests: XCTestCase {
    func testAReleaseBuildIgnoresEveryArgument() {
        let every = [
            WatchLaunch.previewArgument, WatchLaunch.injectedAudioArgument, WatchLaunch.startFailsArgument,
            WatchLaunch.endsAtLimitArgument,
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
        XCTAssertEqual(
            WatchLaunch.mode(
                arguments: [WatchLaunch.previewArgument, WatchLaunch.endsAtLimitArgument], honoursDebugArguments: true),
            .preview(WatchPreview(endsAtLimit: true)))
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
