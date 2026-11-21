import AppKit
import XCTest

/// The main window is there at every launch, whatever was closed before, and it comes back
/// when the running app is opened again with no window.
///
/// This test is about the saved window state, so it is the one UI test that does not launch
/// with that state ignored: it sets the state up itself, by closing the window. It ends with
/// the window open, so it leaves no state that a later test depends on.
final class KnotMacWindowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTheMainWindowComesBackAfterItWasClosed() async throws {
        let app = XCUIApplication()
        let field = app.descendants(matching: .any)["Capture field"]

        // Whatever an earlier build left, the launch shows the window.
        app.launch()
        XCTAssertTrue(field.waitForExistence(timeout: 30), "The window is there at launch.")

        // Closing the window leaves the app running with no window. The system may bring
        // another app forward then, so the app runs in the background or in front.
        try closeTheWindow(of: app, field: field)
        XCTAssertNotEqual(app.state, .notRunning, "The app stays when its window closes.")

        // Opening the running app again, as the Dock or the Finder does, shows the window.
        try await openAgain(app)
        XCTAssertTrue(field.waitForExistence(timeout: 30), "Opening the app again shows the window.")

        // Close the window and quit, through the app menu's Quit item, which works whichever
        // app is in front: the next launch shows the window again.
        try closeTheWindow(of: app, field: field)
        app.menuItems["terminate:"].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 30), "The app quit.")
        app.launch()
        XCTAssertTrue(field.waitForExistence(timeout: 30), "The window is there at the next launch.")
        // No accessibility audit here: this is not a smoke test, and the launch test audits
        // the same window.
    }

    /// Clicks the main window's close button and waits until its capture field is gone. The
    /// accessibility tree may keep listing a closed window, so the field is what is waited on.
    @MainActor
    private func closeTheWindow(of app: XCUIApplication, field: XCUIElement) throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 30))
        window.buttons[XCUIIdentifierCloseWindow].click()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: field)
        wait(for: [gone], timeout: 30)
    }

    /// Opens the app under test again through Launch Services, which sends a running app the
    /// reopen event that a click on its Dock icon sends. The app is the one this test bundle
    /// was built beside, never another worktree's build with the same bundle ID.
    @MainActor
    private func openAgain(_ app: XCUIApplication) async throws {
        // …/Debug/Knot-macOS-UITests-Runner.app/Contents/PlugIns/Knot-macOS-UITests.xctest
        var products = Bundle(for: Self.self).bundleURL
        for _ in 0..<4 { products.deleteLastPathComponent() }
        let url = products.appendingPathComponent("Knot.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "The app is at \(url.path).")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}
