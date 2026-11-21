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

        /// What a failure says about the element.
        var description: String {
            "\(AccessibilityAudit.name(of: kind)), identifier \"\(identifier)\", label \"\(label)\", frame \(frame)"
                + (parentKind.map { ", parent \(AccessibilityAudit.name(of: $0))" } ?? "")
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

    #if os(macOS)
        static let structuralExclusions: [StructuralExclusion] = [windowContent]
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
        return audited
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

    func testAFailureNamesTheElement() {
        let description = hostedContent().description
        XCTAssertTrue(description.contains("group"))
        XCTAssertTrue(description.contains("identifier \"\""))
        XCTAssertTrue(description.contains("label \"\""))
        XCTAssertTrue(description.contains("320"))
        XCTAssertTrue(description.contains("parent window"))
    }
}
