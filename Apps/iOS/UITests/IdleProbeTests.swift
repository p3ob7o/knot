import XCTest

/// The probe of the idle wait (WP-30, 2026-11-26). A UIKit keyboard animation could report its
/// start and never its end, so XCTest believed an animation was in flight in an app that was
/// idle: every interaction of that launch then waited sixty seconds and went on with "App
/// animations complete notification not received", and a case took six to ten minutes. The
/// state began with the first interactions after a launch, so each case here launches, makes
/// them, and ends the app. Every launch passes `-KnotWithoutAnimations` (KnotLauncher), which
/// keeps the state from starting.
///
/// Each interaction's time is an activity of the result bundle, "idle-probe: <step>: <s> s",
/// which is how a run with `-test-iterations` gives a rate. A step that takes 50 s or more fails
/// the case at once with its name: the runner's wait for the app's animations is 60 s, so only
/// that state reaches it, and the rest of the launch would cost a minute a step.
final class KnotIOSIdleProbeTests: XCTestCase {
    let limit: TimeInterval = 600
    /// Under the runner's own sixty seconds of waiting for the app's animations.
    let stuck: Duration = .seconds(50)

    override func setUp() {
        continueAfterFailure = false
    }

    /// Typing into the capture field, then the list button that closes the sheet.
    @MainActor
    func testTypingAndClosingTheSheetLeaveTheAppIdle() {
        let app = launch()
        step("type into the capture field", app) { app.typeText("A synthetic probe line") }
        step("tap the list button that closes the sheet", app) { app.buttons["shell.notes"].tap() }
        XCTAssertTrue(app.buttons["shell.compose"].waitForExistence(timeout: limit))
        app.terminate()
    }

    /// Record, on the preview's injected audio, Stop, then the list button that closes the sheet.
    @MainActor
    func testRecordingAndClosingTheSheetLeaveTheAppIdle() {
        let app = launch()
        let record = app.buttons["Record"]
        XCTAssertTrue(record.waitForExistence(timeout: limit))
        step("tap Record", app) { record.tap() }
        let stop = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Stop recording")).firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: limit))
        step("tap Stop", app) { stop.tap() }
        step("tap the list button after recording", app) { app.buttons["shell.notes"].tap() }
        XCTAssertTrue(app.buttons["shell.compose"].waitForExistence(timeout: limit))
        app.terminate()
    }

    /// Launches on `.preview` and waits for the capture surface with the keyboard up.
    @MainActor
    private func launch() -> XCUIApplication {
        let app = KnotLauncher.launch(.preview)
        XCTAssertTrue(app.descendants(matching: .any)["Capture field"].waitForExistence(timeout: limit))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: limit))
        return app
    }

    /// Runs `action`, one interaction, and records its time.
    @MainActor
    private func step(_ name: String, _ app: XCUIApplication, _ action: () -> Void) {
        let start = ContinuousClock.now
        action()
        let took = start.duration(to: .now)
        let seconds = Double(took.components.seconds) + Double(took.components.attoseconds) / 1e18
        XCTContext.runActivity(named: "idle-probe: \(name): \(String(format: "%.1f", seconds)) s") { _ in }
        if took >= stuck {
            app.terminate()
            XCTFail("idle-probe: \(name) waited \(String(format: "%.0f", seconds)) s for the app's animations")
        }
    }
}
