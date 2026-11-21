import AppKit
import CoreGraphics
import XCTest

/// The main window is on screen at launch whatever window state an earlier quit left, with its
/// capture field and its stream.
///
/// This is the one UI test that does not launch with the saved window state ignored: the state
/// is what it is about. It only reads (the orchestrator's ruling on WP-33 PR 1): no Mac UI test
/// types or clicks, because a synthesized event can land in another app on the build Mac.
/// Closing the window, opening the running app again and quitting are the owner's rows at the
/// M1 sitting.
///
/// A closed window stays in the accessibility tree with its contents, so whether the window is
/// on screen is read from the window server, as `scripts/lib/windows.swift` reads it: the
/// on-screen windows of the app's process, with no Screen Recording permission.
final class KnotMacWindowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTheMainWindowIsThereAtLaunchWhateverWasSaved() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(
            app.descendants(matching: .any)["Capture field"].waitForExistence(timeout: 30),
            "The window holds the capture field.")
        XCTAssertTrue(
            app.descendants(matching: .any)["Sidebar"].waitForExistence(timeout: 30),
            "The window holds the stream.")
        waitForWindowOnScreen("The window is on screen at launch.")
        app.terminate()
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

    /// Waits until the app has a window on screen.
    private func waitForWindowOnScreen(_ message: String) {
        let predicate = NSPredicate { [self] _, _ in windowsOnScreen() > 0 }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        let result = XCTWaiter().wait(for: [expectation], timeout: 30)
        XCTAssertEqual(result, .completed, message)
    }
}
