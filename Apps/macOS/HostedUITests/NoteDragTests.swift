import XCTest

final class MacNoteDragTests: XCTestCase {
    // ui-drag-note-onto-text-field
    @MainActor
    func testDraggingANoteIntoATextField() throws {
        // This separate suite needs the hosted desktop and never runs in the build Mac gate.
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["KNOT_HOSTED_MAC_UI_EVENTS"] == "1", "Requires the hosted Mac desktop.")
        let app = KnotLauncher.application(.preview)
        app.launchArguments.append("drag")
        app.launch()
        defer { app.terminate() }

        let handle = app.descendants(matching: .any)["note.drag"]
        let field = app.textFields["test.drop-text"]
        XCTAssertTrue(handle.waitForExistence(timeout: 30))
        XCTAssertTrue(field.exists)
        let center = CGVector(dx: 0.5, dy: 0.5)
        handle.coordinate(withNormalizedOffset: center).click(
            forDuration: 0.1, thenDragTo: field.coordinate(withNormalizedOffset: center))
        XCTAssertEqual(field.value as? String, "A synthetic note to drag")
        try app.auditAccessibility()
    }
}
