import XCTest

/// The Mac's UI smoke test on `.live` (docs/architecture.md §17), the named test
/// `live-smoke-type-kill-relaunch-read-mac`: the app runs on the live environment with a
/// temporary store of its own, a line is entered, the app is killed, and after a relaunch on the
/// same store the stream shows the line. The audit runs before the kill and after the relaunch.
/// Every other UI test stays on `.preview`.
///
/// Departure, by the orchestrator's ruling on WP-33 PR 1: on the Mac the line does not pass
/// through the keyboard. The runner's synthesized events go to whatever app is in front, and on
/// the build Mac that can be another, so no Mac UI test types or clicks. The debug-only launch
/// argument `-KnotEnterLine` hands the line to the capture surface's model as a typed capture,
/// as keystrokes would reach it, and ends it. The iPhone's and the iPad's smoke tests type for
/// real, in a simulator.
///
/// It launches through `KnotLauncher`, so the app carries `KNOT_AGENT=1`, and it never records.
final class KnotMacLiveSmokeTests: XCTestCase {
    /// Synthetic text only.
    let line = "A synthetic line that outlives a kill"

    override func setUp() {
        continueAfterFailure = false
    }

    // live-smoke-type-kill-relaunch-read-mac
    @MainActor
    func testLiveSmokeTypeKillRelaunchRead() throws {
        let app = KnotLauncher.application(.live(temporaryStore: KnotLauncher.newTemporaryStore()))
        let launcherArguments = app.launchArguments
        // After the launcher's own arguments, so that the window-state pair stays first.
        app.launchArguments = launcherArguments + ["-KnotEnterLine", line]
        app.launch()

        let field = app.descendants(matching: .any)["Capture field"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "The capture surface is on screen at launch.")

        // The stream lists a note while its capture is open and reads only what the store
        // committed, which is on disk: once the row holds the line, the kill cannot take it.
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", line)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "The stream shows the line before the kill.")
        // The stream read the store, so it shows no problem's code. Before the store opens it
        // may, briefly, so this is read only now.
        XCTAssertFalse(app.descendants(matching: .any)["shell.problem-code"].exists, "The store opened.")
        try app.auditAccessibility()

        // Kill: `terminate()` sends SIGKILL to an app with no debugger attached
        // (XCUIApplication.h). Nothing in the app runs after it.
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 30), "The app was killed.")

        // Relaunch on the same temporary store, without the line: the launcher's arguments name
        // the store, and nothing enters the line again.
        app.launchArguments = launcherArguments
        app.launch()
        XCTAssertTrue(field.waitForExistence(timeout: 30), "The capture surface is on screen after the relaunch.")

        // Read.
        XCTAssertTrue(row.waitForExistence(timeout: 30), "The stream shows the line after the relaunch.")
        XCTAssertFalse(app.descendants(matching: .any)["shell.problem-code"].exists, "The store opened again.")
        try app.auditAccessibility()
        app.terminate()
    }
}
