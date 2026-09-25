import XCTest
@testable import AgentHUDCore

final class AeroSpaceTests: XCTestCase {
    func testFolderNameFromTitle() {
        XCTAssertEqual(AeroSpace.folderName(fromTitle: "main.ts — agent-hud"), "agent-hud")
        XCTAssertEqual(AeroSpace.folderName(fromTitle: "● a — b — web app"), "web app")
        XCTAssertEqual(AeroSpace.folderName(fromTitle: "main.ts — box [SSH: dev]"), "box")
        XCTAssertEqual(AeroSpace.folderName(fromTitle: "agent-hud"), "agent-hud")
    }

    func testRankPrefersRootThenNearestAncestor() {
        let names = ["ljj", "ac-platform", "agent-hud"]
        let home = "/Users/me"
        XCTAssertEqual(AeroSpace.rank(root: "/Users/me/Dev/agent-hud", cwd: "/Users/me/Dev/agent-hud/Sources", in: names, home: home), 2)
        XCTAssertEqual(AeroSpace.rank(root: nil, cwd: "/Users/me/ac-platform/apps/web", in: names, home: home), 1)
        XCTAssertNil(AeroSpace.rank(root: "/Users/me/other", cwd: "/Users/me/other", in: names, home: home))
        XCTAssertNil(AeroSpace.rank(root: nil, cwd: nil, in: names, home: home))
    }

    func testWindowDecoding() throws {
        let json = #"[{"app-bundle-id":"com.microsoft.VSCode","window-id":443,"window-title":"x — ljj","workspace":"W"}]"#
        let w = try JSONDecoder().decode([AeroSpace.Window].self, from: Data(json.utf8))
        XCTAssertEqual(w, [AeroSpace.Window(id: 443, bundleID: "com.microsoft.VSCode", workspace: "W", title: "x — ljj")])
    }
}
