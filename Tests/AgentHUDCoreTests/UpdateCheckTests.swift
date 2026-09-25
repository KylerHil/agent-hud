import XCTest
@testable import AgentHUDCore

final class UpdateCheckTests: XCTestCase {
    func testVersionOrdering() {
        XCTAssertTrue(UpdateCheck.isNewer("1.10.0", than: "1.9.2"))
        XCTAssertTrue(UpdateCheck.isNewer("1.0.1", than: "1.0"))
        XCTAssertFalse(UpdateCheck.isNewer("1.0.0", than: "1.0.0"))
        XCTAssertFalse(UpdateCheck.isNewer("0.9.9", than: "1.0.0"))
    }

    func testParsesTheLatestRelease() {
        let json = #"{"tag_name":"v1.2.0","html_url":"https://github.com/KylerHil/agent-hud/releases/tag/v1.2.0","draft":false,"prerelease":false,"body":"Fixes"}"#
        let r = UpdateCheck.parse(Data(json.utf8))
        XCTAssertEqual(r?.version, "1.2.0")
        XCTAssertEqual(r?.page.absoluteString, "https://github.com/KylerHil/agent-hud/releases/tag/v1.2.0")
        XCTAssertNil(UpdateCheck.parse(Data(#"{"tag_name":"v2.0.0","prerelease":true}"#.utf8)))
    }

    func testReadsTheVersionFromTheReleasePageRedirect() {
        let r = UpdateCheck.release(fromPage: URL(string: "https://github.com/KylerHil/agent-hud/releases/tag/v1.2.0")!)
        XCTAssertEqual(r?.version, "1.2.0")
        XCTAssertNil(UpdateCheck.release(fromPage: URL(string: "https://github.com/KylerHil/agent-hud/releases")!))
    }
}
