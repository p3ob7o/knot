import AppKit
import CoreGraphics
import XCTest

/// The main window is there at every launch, whatever was closed before, and it comes back
/// when the running app is opened again with no window.
///
/// This test is about the saved window state, so it is the one UI test that does not launch
/// with that state ignored: it sets the state up itself, by closing the window. It ends with
/// the window open, so it leaves no state that a later test depends on.
///
/// A closed window stays in the accessibility tree with its contents, so whether the window is
/// on screen is read from the window server, as `scripts/lib/windows.swift` reads it: the
/// on-screen windows of the app's process, with no Screen Recording permission.
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
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        waitForWindowOnScreen(true, "The window is there at launch.")

        // Closing the window leaves the app running with no window. The system may bring
        // another app forward then, so the app runs in the background or in front.
        closeTheWindow(of: app)
        XCTAssertNotEqual(app.state, .notRunning, "The app stays when its window closes.")

        // Opening the running app again, as the Dock or the Finder does, shows the window.
        try await openAgain()
        waitForWindowOnScreen(true, "Opening the app again shows the window.")

        // Close the window and quit, through the app menu's Quit item, which works whichever
        // app is in front: the next launch shows the window again.
        closeTheWindow(of: app)
        bringToFront(app)
        app.menuItems["terminate:"].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 30), "The app quit.")
        app.launch()
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        waitForWindowOnScreen(true, "The window is there at the next launch.")
        // No accessibility audit here: this is not a smoke test, and the launch test audits
        // the same window.
    }

    /// The app under test: the one this test bundle was built beside, never another worktree's
    /// build with the same bundle ID.
    private var appURL: URL {
        // …/Debug/Knot-macOS-UITests-Runner.app/Contents/PlugIns/Knot-macOS-UITests.xctest
        var products = Bundle(for: Self.self).bundleURL
        for _ in 0..<4 { products.deleteLastPathComponent() }
        return products.appendingPathComponent("Knot.app").standardizedFileURL
    }

    /// How many windows the app under test has on screen, in the normal window layer.
    private func windowsOnScreen() -> Int {
        let url = appURL.resolvingSymlinksInPath()
        let pids = NSWorkspace.shared.runningApplications
            .filter { $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == url }
            .map { Int($0.processIdentifier) }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.filter { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? Int, pids.contains(pid) else { return false }
            return (window[kCGWindowLayer as String] as? Int) == 0
        }.count
    }

    /// Waits until the app has a window on screen, or has none.
    private func waitForWindowOnScreen(_ shown: Bool, _ message: String) {
        let predicate = NSPredicate { [self] _, _ in (windowsOnScreen() > 0) == shown }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        let result = XCTWaiter().wait(for: [expectation], timeout: 30)
        XCTAssertEqual(result, .completed, message)
    }

    /// Brings the app to the front and waits until it is there. Another thread's launch step
    /// can start a build with the same bundle ID, and a newly started app comes to the front:
    /// a click on the menu bar would then reach that app's menu.
    @MainActor
    private func bringToFront(_ app: XCUIApplication) {
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "The app is in front.")
    }

    /// Closes the main window with the Window menu's Close item, which brings the app forward
    /// and closes its key window, and waits until the window is off screen. A click on the
    /// title bar's close button did not always close it while another app was in front.
    @MainActor
    private func closeTheWindow(of app: XCUIApplication) {
        bringToFront(app)
        app.menuItems["performClose:"].click()
        waitForWindowOnScreen(false, "The window closed.")
    }

    /// Opens the app under test again through Launch Services, which sends a running app the
    /// reopen event that a click on its Dock icon sends.
    @MainActor
    private func openAgain() async throws {
        let url = appURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "The app under test was found.")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}
