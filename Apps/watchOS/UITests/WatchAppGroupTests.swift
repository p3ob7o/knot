import XCTest

/// The app group's decision, one test for each row: a team-signed build that names no usable
/// group is refused, never run without one. No app is launched.
final class WatchAppGroupTests: XCTestCase {
    func testATeamSignedBuildThatNamesAGroupHasIt() {
        let info: [String: Any] = ["KnotSigning": "team", "KnotAppGroup": "group.example.knot.dev"]
        XCTAssertEqual(WatchAppGroup(info: info), .present(identifier: "group.example.knot.dev"))
    }

    func testATeamSignedBuildWithNoGroupIsRefused() {
        XCTAssertEqual(WatchAppGroup(info: ["KnotSigning": "team"]), .refused)
    }

    func testATeamSignedBuildWithAnEmptyGroupIsRefused() {
        XCTAssertEqual(WatchAppGroup(info: ["KnotSigning": "team", "KnotAppGroup": ""]), .refused)
        XCTAssertEqual(WatchAppGroup(info: ["KnotSigning": "team", "KnotAppGroup": "  "]), .refused)
    }

    func testATeamSignedBuildWithAnUnfilledGroupIsRefused() {
        XCTAssertEqual(WatchAppGroup(info: ["KnotSigning": "team", "KnotAppGroup": "$(KNOT_APP_GROUP)"]), .refused)
    }

    func testALocallySignedBuildHasNoGroup() {
        XCTAssertEqual(
            WatchAppGroup(info: ["KnotSigning": "local", "KnotAppGroup": "group.example.knot.dev"]), .absent)
    }

    func testAnyOtherSigningIsRefused() {
        for info: [String: Any] in [
            [:], ["KnotSigning": ""], ["KnotSigning": "Team"], ["KnotSigning": "$(KNOT_SIGNING)"],
            ["KnotSigning": 1], ["KnotAppGroup": "group.example.knot.dev"],
        ] {
            XCTAssertEqual(WatchAppGroup(info: info), .refused, "\(info)")
        }
    }
}
