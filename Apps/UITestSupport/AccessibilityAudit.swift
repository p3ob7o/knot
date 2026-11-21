import XCTest

/// The system's accessibility audit, which every UI smoke test runs (docs/architecture.md §17,
/// docs/plan/WP-21.md). This file is the one place its exclusions sit: each UI test target on
/// iOS, macOS and watchOS compiles it, and no test lists an exclusion of its own.
///
/// `performAccessibilityAudit(for:_:)` is declared for macOS 14, iOS 17 and watchOS 10 in the
/// pinned SDK (XCUIAutomation, `XCUIApplication.h`), so it runs on all three platforms.
enum AccessibilityAudit {
    /// One issue the audit may skip, and why. It names its element by identifier.
    struct Exclusion {
        /// The audit type it covers.
        let type: XCUIAccessibilityAuditType
        /// The element's identifier, so that an exclusion never covers a whole screen.
        let identifier: String
        /// Why it is excluded, and who removes it. WP-41 makes the audit clean on every designed
        /// cell of the state matrix.
        let reason: String
    }

    /// Every exclusion, each with its reason. The aim is an empty list.
    static let exclusions: [Exclusion] = []

    /// An element the audit faulted, as the exclusions judge it and as a failure names it.
    struct Element: Equatable, Sendable {
        var kind: XCUIElement.ElementType
        var identifier: String
        var label: String
        var frame: CGRect
        /// The kind and the frame of its parent, when it is the direct child of a window.
        var parentKind: XCUIElement.ElementType?
        var parentFrame: CGRect?
        /// True when the element lies inside the system keyboard, which the app does not draw:
        /// a keyboard is among its ancestors.
        var inSystemKeyboard = false
        /// The kinds of its ancestors, from the application down to its parent, when the helper
        /// found the element in the app's hierarchy.
        var ancestry: [XCUIElement.ElementType] = []
        /// The frame of the system keyboard while one is up, which a failure names too.
        var systemKeyboardFrame: CGRect?
        /// The index, among the app's windows, of the window that holds the element, and of the
        /// one that holds the system keyboard.
        var windowIndex: Int?
        var keyboardWindowIndex: Int?

        /// What a failure says about the element.
        var description: String {
            "\(AccessibilityAudit.name(of: kind)), identifier \"\(identifier)\", label \"\(label)\", frame \(frame)"
                + (parentKind.map { ", parent \(AccessibilityAudit.name(of: $0))" } ?? "")
                + (inSystemKeyboard ? ", in the system keyboard" : "")
                + (ancestry.isEmpty
                    ? "" : ", path " + ancestry.map { AccessibilityAudit.name(of: $0) }.joined(separator: " > "))
                + (systemKeyboardFrame.map { ", system keyboard at \($0)" } ?? "")
                + (windowIndex.map { ", window \($0)" } ?? "")
                + (keyboardWindowIndex.map { ", keyboard's window \($0)" } ?? "")
        }
    }

    /// The one exclusion of another kind: by structure, for an element that has no name to give.
    struct StructuralExclusion: Sendable {
        /// Why it is excluded.
        let reason: String
        let applies: @Sendable (Element) -> Bool
    }

    /// On the Mac, the window's content as SwiftUI hosts it: a group with no identifier and no
    /// label, whose parent is a window and whose frame is that window's. The gate's audit of the
    /// Mac app faulted it as "Element has no description". It is not a view of ours: a label and
    /// `.accessibilityElement(children: .contain)` on the placeholder's own stack made a labelled
    /// group inside it and left this one faulted. Its children are audited, and every other issue
    /// fails as before, on the Mac too.
    static let windowContent = StructuralExclusion(
        reason: "The window's content as SwiftUI hosts it on the Mac, whose children are audited."
    ) { element in
        element.kind == .group && element.identifier.isEmpty && element.label.isEmpty
            && element.parentKind == .window && element.parentFrame.map { $0.isClose(to: element.frame) } == true
    }

    /// On iOS, an element of the system keyboard, such as a cell of its prediction bar, which
    /// WP-30's audit faulted on the iPad as "Element has no description". It is the system's
    /// interface, drawn in the keyboard's own window: never a screen of the app and never an
    /// element of ours. An element of the app with no description still fails while the
    /// keyboard is up.
    /// True when `element` is the system keyboard's own: a keyboard is among its ancestors, it
    /// lies inside the keyboard's frame, or it sits in the strip on top of the keyboard, within
    /// its width and in the keyboard's window, where the keyboard draws its prediction bar.
    /// WP-30's run found the bar's cells there, under elements of no particular kind.
    static func belongsToSystemKeyboard(_ element: Element) -> Bool {
        if element.ancestry.contains(.keyboard) { return true }
        guard let keyboard = element.systemKeyboardFrame else { return false }
        if keyboard.insetBy(dx: -0.5, dy: -0.5).contains(element.frame) { return true }
        let onTop =
            abs(element.frame.maxY - keyboard.minY) <= 0.5 && element.frame.minX >= keyboard.minX - 0.5
            && element.frame.maxX <= keyboard.maxX + 0.5 && element.frame.height <= 60
        return onTop && element.windowIndex != nil && element.windowIndex == element.keyboardWindowIndex
    }

    static let systemKeyboard = StructuralExclusion(
        reason: "The system keyboard's own interface, which the app does not draw."
    ) { element in
        element.inSystemKeyboard
    }

    #if os(macOS)
        static let structuralExclusions: [StructuralExclusion] = [windowContent]
    #elseif os(iOS)
        static let structuralExclusions: [StructuralExclusion] = [systemKeyboard]
    #else
        static let structuralExclusions: [StructuralExclusion] = []
    #endif

    /// The exclusions that name no element or give no reason. An empty identifier would match
    /// every element that has none, so such an entry never applies, and the audit fails on it.
    static func malformed(_ list: [Exclusion]) -> [Exclusion] {
        list.filter { exclusion in
            exclusion.identifier.allSatisfy(\.isWhitespace) || exclusion.reason.allSatisfy(\.isWhitespace)
        }
    }

    /// True when an issue of `type` on `element` is excluded: by one of `listed` that names its
    /// element and gives its reason, or by one of `structural`.
    static func isExcluded(
        _ type: XCUIAccessibilityAuditType, on element: Element?, listed: [Exclusion] = exclusions,
        structural: [StructuralExclusion] = structuralExclusions
    ) -> Bool {
        guard let element else { return false }
        let bad = malformed(listed)
        let byName = listed.contains { exclusion in
            !bad.contains { $0.identifier == exclusion.identifier && $0.reason == exclusion.reason }
                && type.contains(exclusion.type) && element.identifier == exclusion.identifier
        }
        return byName || structural.contains { $0.applies(element) }
    }

    static func name(of kind: XCUIElement.ElementType) -> String {
        switch kind {
        case .group: "group"
        case .window: "window"
        case .button: "button"
        case .image: "image"
        case .staticText: "text"
        case .textField: "text field"
        case .textView: "text view"
        case .other: "other"
        case .keyboard: "keyboard"
        case .application: "application"
        default: "element of type \(kind.rawValue)"
        }
    }
}

extension CGRect {
    /// The same rectangle, within half a point.
    func isClose(to other: CGRect) -> Bool {
        abs(minX - other.minX) <= 0.5 && abs(minY - other.minY) <= 0.5 && abs(width - other.width) <= 0.5
            && abs(height - other.height) <= 0.5
    }
}

extension XCUIApplication {
    /// Launches the app for a smoke test. On the Mac it ignores the window state that AppKit
    /// saved at an earlier quit: every development build has the same bundle ID and so shares it,
    /// and a window that one launch left closed would stay closed at the next. The launch
    /// argument sets the user default `ApplePersistenceIgnoreState`, which AppKit reads at launch.
    @MainActor
    func launchForSmokeTest() {
        #if os(macOS)
            launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        #endif
        launch()
    }

    /// Runs every audit type on the current screen. Each issue fails the test, unless the lists
    /// above exclude it, and the failure names the element: its kind, its identifier, its label
    /// and its frame. Every UI smoke test calls it after its launch: the named test
    /// `accessibility-audit-in-every-ui-smoke-test`.
    @MainActor
    func auditAccessibility() throws {
        for exclusion in AccessibilityAudit.malformed(AccessibilityAudit.exclusions) {
            XCTFail(
                "An accessibility audit exclusion must name its element and give its reason: "
                    + "identifier \"\(exclusion.identifier)\", reason \"\(exclusion.reason)\"")
        }
        try performAccessibilityAudit(for: .all) { issue in
            let element = issue.element.map { self.auditedElement($0) }
            if AccessibilityAudit.isExcluded(issue.auditType, on: element) { return true }
            XCTFail(
                "Accessibility audit: \(issue.compactDescription) (\(issue.detailedDescription)) on "
                    + (element?.description ?? "no element"))
            return true
        }
    }

    /// The faulted element as the exclusions judge it. Its parent is known when it is a direct
    /// child of one of the app's windows, with the same kind, identifier, label and frame.
    @MainActor
    private func auditedElement(_ element: XCUIElement) -> AccessibilityAudit.Element {
        var audited = AccessibilityAudit.Element(
            kind: element.elementType, identifier: element.identifier, label: element.label, frame: element.frame)
        for window in windows.allElementsBoundByIndex {
            guard let children = try? window.snapshot().children else { continue }
            let isChild = children.contains { child in
                child.elementType == audited.kind && child.identifier == audited.identifier
                    && child.label == audited.label && child.frame.isClose(to: audited.frame)
            }
            if isChild {
                audited.parentKind = .window
                audited.parentFrame = window.frame
                break
            }
        }
        audited.ancestry = ancestry(of: audited)
        #if os(iOS)
            let keyboard = keyboards.firstMatch
            if keyboard.exists {
                audited.systemKeyboardFrame = keyboard.frame
                audited.windowIndex = windowIndex { node in
                    node.elementType == audited.kind && node.identifier == audited.identifier
                        && node.label == audited.label && node.frame.isClose(to: audited.frame)
                }
                let keyboardFrame = keyboard.frame
                audited.keyboardWindowIndex = windowIndex { node in
                    node.elementType == .keyboard && node.frame.isClose(to: keyboardFrame)
                }
            }
            audited.inSystemKeyboard = AccessibilityAudit.belongsToSystemKeyboard(audited)
        #endif
        return audited
    }

    /// The index of the first of the app's windows that holds a node `matching`.
    @MainActor
    private func windowIndex(of matching: (any XCUIElementSnapshot) -> Bool) -> Int? {
        for (index, window) in windows.allElementsBoundByIndex.enumerated() {
            guard let root = try? window.snapshot() else { continue }
            var pending: [any XCUIElementSnapshot] = [root]
            while let next = pending.popLast() {
                if matching(next) { return index }
                pending += next.children
            }
        }
        return nil
    }

    /// The kinds of the ancestors of the element with `audited`'s kind, identifier, label and
    /// frame, from the application down, or none when it is not found.
    @MainActor
    private func ancestry(of audited: AccessibilityAudit.Element) -> [XCUIElement.ElementType] {
        guard let root = try? snapshot() else { return [] }
        var pending: [(node: any XCUIElementSnapshot, path: [XCUIElement.ElementType])] = [(root, [])]
        while let (node, path) = pending.popLast() {
            if node.elementType == audited.kind && node.identifier == audited.identifier
                && node.label == audited.label && node.frame.isClose(to: audited.frame)
            {
                return path
            }
            pending += node.children.map { ($0, path + [node.elementType]) }
        }
        return []
    }

}

/// The exclusions on elements made up for the purpose: no app is launched.
final class AccessibilityAuditExclusionTests: XCTestCase {
    let windowFrame = CGRect(x: 865, y: 471, width: 320, height: 240)

    func hostedContent() -> AccessibilityAudit.Element {
        AccessibilityAudit.Element(
            kind: .group, identifier: "", label: "", frame: windowFrame, parentKind: .window, parentFrame: windowFrame)
    }

    func testTheWindowContentIsExcludedOnTheMacOnly() {
        let excluded = AccessibilityAudit.isExcluded(.sufficientElementDescription, on: hostedContent())
        #if os(macOS)
            XCTAssertTrue(excluded)
        #else
            XCTAssertFalse(excluded)
        #endif
        // The rule itself, whatever the platform.
        XCTAssertTrue(AccessibilityAudit.windowContent.applies(hostedContent()))
    }

    func testAnUnlabelledControlInsideTheWindowContentStillFails() {
        // A button inside the hosted group: its parent is the group, not the window.
        let button = AccessibilityAudit.Element(
            kind: .button, identifier: "", label: "", frame: CGRect(x: 900, y: 500, width: 44, height: 44),
            parentKind: nil, parentFrame: nil)
        XCTAssertFalse(AccessibilityAudit.isExcluded(.sufficientElementDescription, on: button))
        XCTAssertFalse(
            AccessibilityAudit.isExcluded(
                .sufficientElementDescription, on: button, structural: [AccessibilityAudit.windowContent]))
        // A button with the window's own frame, even as the window's child, is not a group.
        var wholeButton = hostedContent()
        wholeButton.kind = .button
        XCTAssertFalse(AccessibilityAudit.windowContent.applies(wholeButton))
    }

    func testOnlyAnUnnamedGroupWithTheWindowsFrameIsTheWindowContent() {
        var labelled = hostedContent()
        labelled.label = "Knot"
        XCTAssertFalse(AccessibilityAudit.windowContent.applies(labelled))
        var identified = hostedContent()
        identified.identifier = "content"
        XCTAssertFalse(AccessibilityAudit.windowContent.applies(identified))
        var smaller = hostedContent()
        smaller.frame = CGRect(x: 977, y: 545, width: 96, height: 124)
        XCTAssertFalse(AccessibilityAudit.windowContent.applies(smaller))
        var nested = hostedContent()
        nested.parentKind = .group
        XCTAssertFalse(AccessibilityAudit.windowContent.applies(nested))
        var orphan = hostedContent()
        orphan.parentKind = nil
        orphan.parentFrame = nil
        XCTAssertFalse(AccessibilityAudit.windowContent.applies(orphan))
    }

    func testAListedExclusionNamesItsElementAndGivesItsReason() {
        let good = AccessibilityAudit.Exclusion(type: .contrast, identifier: "knot.mark", reason: "A reason.")
        let unnamed = AccessibilityAudit.Exclusion(type: .contrast, identifier: " ", reason: "A reason.")
        let unexplained = AccessibilityAudit.Exclusion(type: .contrast, identifier: "knot.mark", reason: "")
        XCTAssertEqual(AccessibilityAudit.malformed([good, unnamed, unexplained]).count, 2)
        let mark = AccessibilityAudit.Element(
            kind: .image, identifier: "knot.mark", label: "Knot", frame: .zero, parentKind: nil, parentFrame: nil)
        XCTAssertTrue(AccessibilityAudit.isExcluded(.contrast, on: mark, listed: [good], structural: []))
        XCTAssertFalse(AccessibilityAudit.isExcluded(.contrast, on: mark, listed: [unexplained], structural: []))
        XCTAssertFalse(AccessibilityAudit.isExcluded(.hitRegion, on: mark, listed: [good], structural: []))
        // An element with no identifier is never matched by an unnamed entry.
        var unnamedElement = mark
        unnamedElement.identifier = ""
        XCTAssertFalse(AccessibilityAudit.isExcluded(.contrast, on: unnamedElement, listed: [unnamed], structural: []))
    }

    func testTheSystemKeyboardIsExcludedOnIOSOnly() {
        let cell = AccessibilityAudit.Element(
            kind: .button, identifier: "", label: "", frame: CGRect(x: 283, y: 979, width: 155, height: 49),
            parentKind: nil, parentFrame: nil, inSystemKeyboard: true)
        let excluded = AccessibilityAudit.isExcluded(.sufficientElementDescription, on: cell)
        #if os(iOS)
            XCTAssertTrue(excluded)
        #else
            XCTAssertFalse(excluded)
        #endif
        XCTAssertTrue(AccessibilityAudit.systemKeyboard.applies(cell))
        XCTAssertTrue(cell.description.contains("in the system keyboard"))
    }

    func testAnElementOfTheAppWithNoDescriptionStillFailsWhileTheKeyboardIsUp() {
        // The same kind of element, with the same empty name, drawn by the app above the keyboard.
        let ours = AccessibilityAudit.Element(
            kind: .button, identifier: "", label: "", frame: CGRect(x: 283, y: 700, width: 155, height: 49),
            parentKind: nil, parentFrame: nil, inSystemKeyboard: false)
        XCTAssertFalse(AccessibilityAudit.isExcluded(.sufficientElementDescription, on: ours))
        XCTAssertFalse(AccessibilityAudit.systemKeyboard.applies(ours))
        // Nor does the keyboard's exclusion cover the window's content of a screen.
        var screen = hostedContent()
        screen.inSystemKeyboard = false
        XCTAssertFalse(AccessibilityAudit.systemKeyboard.applies(screen))
    }

    func testThePredictionBarOnTopOfTheKeyboardIsTheKeyboards() {
        let keyboard = CGRect(x: 0, y: 590, width: 402, height: 226)
        var cell = AccessibilityAudit.Element(
            kind: .button, identifier: "", label: "", frame: CGRect(x: 134, y: 546, width: 134, height: 44),
            parentKind: nil, parentFrame: nil)
        cell.systemKeyboardFrame = keyboard
        cell.windowIndex = 1
        cell.keyboardWindowIndex = 1
        XCTAssertTrue(AccessibilityAudit.belongsToSystemKeyboard(cell))
        // The same strip in another window than the keyboard's is the app's, and still fails.
        var ours = cell
        ours.windowIndex = 0
        XCTAssertFalse(AccessibilityAudit.belongsToSystemKeyboard(ours))
        // Not on top of the keyboard, or taller than a bar: the app's.
        var above = cell
        above.frame.origin.y = 400
        XCTAssertFalse(AccessibilityAudit.belongsToSystemKeyboard(above))
        var tall = cell
        tall.frame = CGRect(x: 0, y: 290, width: 402, height: 300)
        XCTAssertFalse(AccessibilityAudit.belongsToSystemKeyboard(tall))
        // Inside the keyboard's frame, and with no keyboard up.
        var key = cell
        key.frame = CGRect(x: 10, y: 700, width: 30, height: 40)
        key.windowIndex = nil
        XCTAssertTrue(AccessibilityAudit.belongsToSystemKeyboard(key))
        var noKeyboard = cell
        noKeyboard.systemKeyboardFrame = nil
        XCTAssertFalse(AccessibilityAudit.belongsToSystemKeyboard(noKeyboard))
    }

    func testAFailureNamesTheElement() {
        let description = hostedContent().description
        XCTAssertTrue(description.contains("group"))
        XCTAssertTrue(description.contains("identifier \"\""))
        XCTAssertTrue(description.contains("label \"\""))
        XCTAssertTrue(description.contains("320"))
        XCTAssertTrue(description.contains("parent window"))
    }
}
