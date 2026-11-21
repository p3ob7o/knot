import XCTest

/// The skeleton's launch smoke test, on `.preview`: the main window opens on the capture surface,
/// a line entered through the capture surface's model is saved, and the stream beside it shows
/// the line. It launches through `KnotLauncher`, as every UI test does, so the app carries the
/// agent's mark and ignores the saved window state.
///
/// No Mac UI test types or clicks (the orchestrator's ruling on WP-33 PR 1): the runner
/// synthesizes real events, which go to whatever app is in front, and on the build Mac that can
/// be another. The line comes from the debug-only launch argument `-KnotEnterLine`, which hands
/// it to the capture surface's model as a typed capture, as keystrokes would, and ends it. The
/// test only reads the screen, runs the audit, and ends the app with `terminate()`.
final class KnotMacLaunchTests: XCTestCase {
    /// Synthetic text only.
    let line = "A synthetic line for the Mac skeleton"

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchIntoCaptureAndFindTheEnteredLineInTheStream() throws {
        let app = KnotLauncher.application(.preview)
        // After the launcher's own arguments, so that the window-state pair stays first.
        app.launchArguments += ["-KnotEnterLine", line]
        app.launch()

        let field = app.descendants(matching: .any)["Capture field"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "The capture surface is on screen at launch.")

        // The stream lists the note once the store has committed the line. The row is the one
        // element whose label holds the line.
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", line)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "The stream shows the entered line.")
        try app.auditAccessibility()
        app.terminate()
    }
}
