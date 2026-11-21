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
        /// The one audit type it covers, or `nil` for every type.
        var type: XCUIAccessibilityAuditType? = nil
        let applies: @Sendable (Element) -> Bool
    }

    /// On the Mac, the window's content as SwiftUI hosts it: a group with no identifier and no
    /// label, whose parent is a window and whose frame is that window's. The gate's audit of the
    /// Mac app faulted it as "Element has no description". It is not a view of ours: a label and
    /// `.accessibilityElement(children: .contain)` on the placeholder's own stack made a labelled
    /// group inside it and left this one faulted. Its children are audited, and every other issue
    /// fails as before, on the Mac too.
    static let windowContent = StructuralExclusion(
        reason: "The window's content as SwiftUI hosts it on the Mac, whose children are audited.",
        type: .sufficientElementDescription
    ) { element in
        element.kind == .group && element.identifier.isEmpty && element.label.isEmpty
            && element.parentKind == .window && element.parentFrame.map { $0.isClose(to: element.frame) } == true
    }

    /// On the Mac, a column that `NavigationSplitView` hosts: a group with no identifier and no
    /// label whose parent is a split group. WP-33's audit of the Mac skeleton faulted the
    /// sidebar's column as "Element has no description", on the path application > window >
    /// group > split group. The app does not name it, and its children are audited. The one
    /// rule covers the sidebar's column and the detail's. WP-41 makes the whole app's audit
    /// clean and revisits it.
    static let splitViewColumn = StructuralExclusion(
        reason: "A column that NavigationSplitView hosts on the Mac, which the app does not name and whose "
            + "children are audited.",
        type: .sufficientElementDescription
    ) { element in
        element.kind == .group && element.identifier.isEmpty && element.label.isEmpty
            && element.ancestry.last == .splitGroup
    }

    /// On the Mac, the window's title, which the system draws in the toolbar: a static text with
    /// no identifier whose parent is the window and which lies in the window's title bar, at its
    /// top edge. The system dims it while the window is not the key window, as it is in a test
    /// that does not bring the app to the front, and the app sets none of its colours. WP-33's
    /// audit of the Mac skeleton faulted it as "Contrast failed". Only the contrast audit is
    /// excluded: every other issue on the title still fails. WP-41 revisits it.
    static let windowTitle = StructuralExclusion(
        reason: "The window's title, which the system draws in the toolbar and dims while the window is not "
            + "key; the app sets none of its colours.",
        type: .contrast
    ) { element in
        guard element.kind == .staticText, element.identifier.isEmpty, element.parentKind == .window,
            let window = element.parentFrame
        else { return false }
        return abs(element.frame.minY - window.minY) <= 0.5 && element.frame.height <= 60
            && element.frame.minX >= window.minX - 0.5 && element.frame.maxX <= window.maxX + 0.5
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
        static let structuralExclusions: [StructuralExclusion] = [windowContent, splitViewColumn, windowTitle]
    #elseif os(iOS)
        static let structuralExclusions: [StructuralExclusion] = [systemKeyboard]
    #else
        static let structuralExclusions: [StructuralExclusion] = []
    #endif

    /// An issue that names no element: the audit raised it for an element it could not resolve,
    /// so no exclusion by name or by structure can judge it. Only an issue of the type named
    /// here is skipped; every other issue that names no element still fails.
    struct ElementlessExclusion: Sendable {
        /// The audit type it covers.
        let type: XCUIAccessibilityAuditType
        /// Why it is excluded.
        let reason: String
    }

    #if os(macOS)
        /// On the Mac, a "Parent/Child mismatch" that names no element. WP-33's audit of the Mac
        /// skeleton's split-view window raised it, with `issue.element` nil, and the app's tree
        /// was the same before and after the audit: the system raises it for an element it does
        /// not resolve. WP-41 makes the audit of the whole app clean. The audit type exists on
        /// macOS only (`XCUIAccessibilityAuditTypes.h`).
        static let unresolvedParentChild = ElementlessExclusion(
            type: .parentChild,
            reason: "A Parent/Child mismatch the system raises on the Mac for an element it does not resolve. "
                + "The tree is the same before and after the audit. WP-41 makes the whole app's audit clean.")

        static let elementlessExclusions: [ElementlessExclusion] = [unresolvedParentChild]
    #else
        static let elementlessExclusions: [ElementlessExclusion] = []
    #endif

    /// The exclusions that name no element or give no reason. An empty identifier would match
    /// every element that has none, so such an entry never applies, and the audit fails on it.
    static func malformed(_ list: [Exclusion]) -> [Exclusion] {
        list.filter { exclusion in
            exclusion.identifier.allSatisfy(\.isWhitespace) || exclusion.reason.allSatisfy(\.isWhitespace)
        }
    }

    /// True when an issue of `type` on `element` is excluded: by one of `listed` that names its
    /// element and gives its reason, or by one of `structural`. An issue that names no element
    /// is excluded only by one of `elementless` of exactly its type.
    static func isExcluded(
        _ type: XCUIAccessibilityAuditType, on element: Element?, listed: [Exclusion] = exclusions,
        structural: [StructuralExclusion] = structuralExclusions,
        elementless: [ElementlessExclusion] = elementlessExclusions
    ) -> Bool {
        guard let element else {
            return elementless.contains { $0.type == type && !$0.reason.allSatisfy(\.isWhitespace) }
        }
        let bad = malformed(listed)
        let byName = listed.contains { exclusion in
            !bad.contains { $0.identifier == exclusion.identifier && $0.reason == exclusion.reason }
                && type.contains(exclusion.type) && element.identifier == exclusion.identifier
        }
        return byName || structural.contains { ($0.type == nil || $0.type == type) && $0.applies(element) }
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

    #if os(macOS)
        func testAParentChildMismatchWithNoElementIsExcludedOnTheMac() {
            XCTAssertTrue(AccessibilityAudit.isExcluded(.parentChild, on: nil))
            XCTAssertTrue(
                AccessibilityAudit.isExcluded(
                    .parentChild, on: nil, elementless: [AccessibilityAudit.unresolvedParentChild]))
            // With no elementless exclusion, it fails.
            XCTAssertFalse(AccessibilityAudit.isExcluded(.parentChild, on: nil, elementless: []))
            // One without a reason never applies.
            let unexplained = AccessibilityAudit.ElementlessExclusion(type: .parentChild, reason: " ")
            XCTAssertFalse(AccessibilityAudit.isExcluded(.parentChild, on: nil, elementless: [unexplained]))
        }

        func testAParentChildMismatchOnANamedElementStillFails() {
            let button = AccessibilityAudit.Element(
                kind: .button, identifier: "some.button", label: "Some",
                frame: CGRect(x: 900, y: 500, width: 44, height: 44), parentKind: nil, parentFrame: nil)
            XCTAssertFalse(AccessibilityAudit.isExcluded(.parentChild, on: button))
        }
    #endif

    func testEveryOtherIssueWithNoElementStillFails() {
        var types: [XCUIAccessibilityAuditType] = [
            .contrast, .elementDetection, .hitRegion, .sufficientElementDescription,
        ]
        #if os(macOS)
            types.append(.action)
        #else
            types += [.dynamicType, .textClipped, .trait]
        #endif
        for type in types {
            XCTAssertFalse(AccessibilityAudit.isExcluded(type, on: nil), "\(type.rawValue)")
        }
    }

    /// A column of a split view, as the helper sees it: a group under the window's hosted
    /// content and a split group.
    func splitViewColumn(frame: CGRect) -> AccessibilityAudit.Element {
        var column = AccessibilityAudit.Element(
            kind: .group, identifier: "", label: "", frame: frame, parentKind: nil, parentFrame: nil)
        column.ancestry = [.application, .window, .group, .splitGroup]
        return column
    }

    func testBothColumnsOfASplitViewAreExcludedOnTheMacOnly() {
        let sidebar = splitViewColumn(frame: CGRect(x: 545, y: 272, width: 280, height: 640))
        let detail = splitViewColumn(frame: CGRect(x: 545, y: 272, width: 960, height: 640))
        for column in [sidebar, detail] {
            let excluded = AccessibilityAudit.isExcluded(.sufficientElementDescription, on: column)
            #if os(macOS)
                XCTAssertTrue(excluded)
            #else
                XCTAssertFalse(excluded)
            #endif
            // The rule itself, whatever the platform.
            XCTAssertTrue(AccessibilityAudit.splitViewColumn.applies(column))
        }
    }

    /// The issue types that exist on every platform, besides a missing description.
    let otherTypes: [XCUIAccessibilityAuditType] = [.contrast, .hitRegion, .elementDetection]

    func testAColumnWithAnotherIssueStillFails() {
        let column = splitViewColumn(frame: CGRect(x: 545, y: 272, width: 280, height: 640))
        for type in otherTypes {
            XCTAssertFalse(AccessibilityAudit.isExcluded(type, on: column), "\(type.rawValue)")
        }
        #if os(macOS)
            XCTAssertFalse(AccessibilityAudit.isExcluded(.parentChild, on: column))
            XCTAssertFalse(AccessibilityAudit.isExcluded(.action, on: column))
        #endif
    }

    func testTheWindowContentWithAnotherIssueStillFails() {
        for type in otherTypes {
            XCTAssertFalse(AccessibilityAudit.isExcluded(type, on: hostedContent()), "\(type.rawValue)")
        }
        #if os(macOS)
            XCTAssertFalse(AccessibilityAudit.isExcluded(.parentChild, on: hostedContent()))
            XCTAssertFalse(AccessibilityAudit.isExcluded(.action, on: hostedContent()))
        #endif
    }

    func testAGroupWithNoDescriptionOutsideASplitGroupStillFails() {
        var group = splitViewColumn(frame: CGRect(x: 600, y: 300, width: 100, height: 40))
        group.ancestry = [.application, .window, .group, .splitGroup, .group, .scrollView]
        XCTAssertFalse(AccessibilityAudit.splitViewColumn.applies(group))
        XCTAssertFalse(AccessibilityAudit.isExcluded(.sufficientElementDescription, on: group))
        // With no ancestry known, the rule does not apply either.
        group.ancestry = []
        XCTAssertFalse(AccessibilityAudit.splitViewColumn.applies(group))
    }

    func testANamedOrLabelledGroupUnderASplitGroupIsNotExcluded() {
        var named = splitViewColumn(frame: CGRect(x: 545, y: 272, width: 280, height: 640))
        named.identifier = "stream.column"
        XCTAssertFalse(AccessibilityAudit.splitViewColumn.applies(named))
        var labelled = splitViewColumn(frame: CGRect(x: 545, y: 272, width: 280, height: 640))
        labelled.label = "Notes"
        XCTAssertFalse(AccessibilityAudit.splitViewColumn.applies(labelled))
        // Another kind under a split group is not a column.
        var button = splitViewColumn(frame: CGRect(x: 545, y: 272, width: 40, height: 40))
        button.kind = .button
        XCTAssertFalse(AccessibilityAudit.splitViewColumn.applies(button))
    }

    /// The window's title as the helper sees it: a static text, the window's child, in its title
    /// bar at its top edge.
    func windowTitle() -> AccessibilityAudit.Element {
        let window = CGRect(x: 545, y: 272, width: 960, height: 640)
        return AccessibilityAudit.Element(
            kind: .staticText, identifier: "", label: "", frame: CGRect(x: 829, y: 272, width: 672, height: 52),
            parentKind: .window, parentFrame: window)
    }

    func testTheWindowTitleIsExcludedForContrastOnTheMacOnly() {
        let excluded = AccessibilityAudit.isExcluded(.contrast, on: windowTitle())
        #if os(macOS)
            XCTAssertTrue(excluded)
        #else
            XCTAssertFalse(excluded)
        #endif
        // The rule itself, whatever the platform.
        XCTAssertTrue(AccessibilityAudit.windowTitle.applies(windowTitle()))
    }

    func testATextOfTheAppWithFailedContrastStillFails() {
        // A text inside the window's content: its parent is not the window.
        let text = AccessibilityAudit.Element(
            kind: .staticText, identifier: "", label: "", frame: CGRect(x: 561, y: 372, width: 81, height: 16),
            parentKind: nil, parentFrame: nil)
        XCTAssertFalse(AccessibilityAudit.isExcluded(.contrast, on: text))
        // A text that is the window's child but lies below the title bar's top edge.
        var lower = windowTitle()
        lower.frame = CGRect(x: 829, y: 400, width: 672, height: 20)
        XCTAssertFalse(AccessibilityAudit.windowTitle.applies(lower))
        XCTAssertFalse(AccessibilityAudit.isExcluded(.contrast, on: lower))
        // A text with an identifier is the app's.
        var named = windowTitle()
        named.identifier = "note.title"
        XCTAssertFalse(AccessibilityAudit.isExcluded(.contrast, on: named))
    }

    func testTheWindowTitleWithAnotherIssueStillFails() {
        for type: XCUIAccessibilityAuditType in [.hitRegion, .sufficientElementDescription, .elementDetection] {
            XCTAssertFalse(AccessibilityAudit.isExcluded(type, on: windowTitle()), "\(type.rawValue)")
        }
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
