import XCTest
@testable import KnotKit

final class HeadingSplicerTests: XCTestCase {

    private let splicer = HeadingSplicer(heading: "## Quick notes")
    private let bullet = "- 14:32 a thought"

    func test_emptyFile_writesHeadingAndBullet() {
        let result = splicer.append(bullet: bullet, to: "")
        XCTAssertEqual(result, "## Quick notes\n\n- 14:32 a thought\n")
    }

    func test_headingExists_emptySection_appendsBulletAfterBlankLine() {
        let input = """
        ## Quick notes

        """
        let result = splicer.append(bullet: bullet, to: input)
        XCTAssertEqual(result, "## Quick notes\n\n- 14:32 a thought\n")
    }

    func test_headingExists_withExistingBullets_appendsAtEndOfSection() {
        let input = """
        ## Quick notes

        - 09:00 first
        - 10:15 second

        """
        let result = splicer.append(bullet: bullet, to: input)
        XCTAssertEqual(result, """
        ## Quick notes

        - 09:00 first
        - 10:15 second
        - 14:32 a thought

        """)
    }

    func test_headingExists_withFollowingSection_insertsBeforeNextHeading() {
        let input = """
        ## Quick notes

        - 09:00 first

        ## Tasks

        - [ ] something
        """
        let result = splicer.append(bullet: bullet, to: input)
        XCTAssertEqual(result, """
        ## Quick notes

        - 09:00 first
        - 14:32 a thought

        ## Tasks

        - [ ] something
        """)
    }

    func test_noHeading_appendsHeadingAndBulletAtEnd() {
        let input = """
        # Today

        Some prose here.
        """
        let result = splicer.append(bullet: bullet, to: input)
        XCTAssertEqual(result, """
        # Today

        Some prose here.

        ## Quick notes

        - 14:32 a thought

        """)
    }

    func test_noHeading_emptyContent() {
        let result = splicer.append(bullet: bullet, to: "")
        XCTAssertEqual(result, "## Quick notes\n\n- 14:32 a thought\n")
    }

    func test_higherLevelHeadingDoesNotEndSection() {
        // A `### Subheading` is lower-level than `## Quick notes` so the
        // section continues through it.
        let input = """
        ## Quick notes

        - 09:00 first

        ### Sub

        Detail
        """
        let result = splicer.append(bullet: bullet, to: input)
        XCTAssertEqual(result, """
        ## Quick notes

        - 09:00 first

        ### Sub

        Detail
        - 14:32 a thought
        """)
    }

    func test_sameLevelHeadingEndsSection() {
        let input = """
        ## Quick notes

        ## Other
        body
        """
        let result = splicer.append(bullet: bullet, to: input)
        XCTAssertEqual(result, """
        ## Quick notes

        - 14:32 a thought

        ## Other
        body
        """)
    }

    func test_higherLevelTopHeadingEndsSection() {
        // A `# Top` is higher-level than `## Quick notes` so it ends the section.
        let input = """
        ## Quick notes

        - 09:00 first

        # Top

        body
        """
        let result = splicer.append(bullet: bullet, to: input)
        XCTAssertEqual(result, """
        ## Quick notes

        - 09:00 first
        - 14:32 a thought

        # Top

        body
        """)
    }
}
