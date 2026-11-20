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

    /// True when `issue` is one of `exclusions`.
    static func isExcluded(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        exclusions.contains { exclusion in
            issue.auditType.contains(exclusion.type) && issue.element?.identifier == exclusion.identifier
        }
    }
}

extension XCUIApplication {
    /// Runs every audit type on the current screen. Each issue fails the test, unless the list
    /// above excludes it. Every UI smoke test calls it after its launch: the named test
    /// `accessibility-audit-in-every-ui-smoke-test`.
    @MainActor
    func auditAccessibility() throws {
        try performAccessibilityAudit(for: .all) { issue in
            AccessibilityAudit.isExcluded(issue)
        }
    }
}
