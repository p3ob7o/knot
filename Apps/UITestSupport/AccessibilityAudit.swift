import XCTest

/// The system's accessibility audit, which every UI smoke test runs (docs/architecture.md §17,
/// docs/plan/WP-21.md). This file is the one place its exclusions sit: each UI test target on
/// iOS, macOS and watchOS compiles it, and no test lists an exclusion of its own.
///
/// `performAccessibilityAudit(for:_:)` is declared for macOS 14, iOS 17 and watchOS 10 in the
/// pinned SDK (XCUIAutomation, `XCUIApplication.h`), so it runs on all three platforms.
enum AccessibilityAudit {
    /// One issue the audit may skip, and why.
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

    /// The exclusions that name no element or give no reason. An empty identifier would match
    /// every element that has none, so such an entry never applies, and the audit fails on it.
    static func malformed(_ list: [Exclusion]) -> [Exclusion] {
        list.filter { exclusion in
            exclusion.identifier.allSatisfy(\.isWhitespace) || exclusion.reason.allSatisfy(\.isWhitespace)
        }
    }

    /// True when `issue` is one of `exclusions` that names its element and gives its reason.
    static func isExcluded(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        let bad = malformed(exclusions)
        return exclusions.contains { exclusion in
            !bad.contains { $0.identifier == exclusion.identifier && $0.reason == exclusion.reason }
                && issue.auditType.contains(exclusion.type) && issue.element?.identifier == exclusion.identifier
        }
    }
}

extension XCUIApplication {
    /// Runs every audit type on the current screen. Each issue fails the test, unless the list
    /// above excludes it. Every UI smoke test calls it after its launch: the named test
    /// `accessibility-audit-in-every-ui-smoke-test`.
    @MainActor
    func auditAccessibility() throws {
        for exclusion in AccessibilityAudit.malformed(AccessibilityAudit.exclusions) {
            XCTFail(
                "An accessibility audit exclusion must name its element and give its reason: "
                    + "identifier \"\(exclusion.identifier)\", reason \"\(exclusion.reason)\"")
        }
        try performAccessibilityAudit(for: .all) { issue in
            AccessibilityAudit.isExcluded(issue)
        }
    }
}
