import XCTest
@testable import AgentHUDCore

final class TmuxTests: XCTestCase {
    let s = Tmux.sep

    func testLocatePrefersAClientOnTheSameSession() {
        let panes = Tmux.parsePanes("/dev/ttys010\(s)work\(s)@1\(s)%1\n/dev/ttys011\(s)dds\(s)@4\(s)%7\n")
        let clients = Tmux.parseClients("/dev/ttys002\(s)work\(s)501\(s)900\n/dev/ttys003\(s)dds\(s)502\(s)100\n")
        let hit = Tmux.locate(tty: "/dev/ttys011", panes: panes, clients: clients)
        XCTAssertEqual(hit?.pane.paneID, "%7")
        XCTAssertEqual(hit?.client?.tty, "/dev/ttys003", "the terminal already showing that session")
        XCTAssertNil(Tmux.locate(tty: "/dev/ttys999", panes: panes, clients: clients))
    }

    func testLocateFallsBackToTheMostRecentClient() {
        let panes = Tmux.parsePanes("/dev/ttys011\(s)dds\(s)@4\(s)%7\n")
        let clients = Tmux.parseClients("/dev/ttys002\(s)work\(s)501\(s)900\n/dev/ttys004\(s)other\(s)503\(s)50\n")
        XCTAssertEqual(Tmux.locate(tty: "/dev/ttys011", panes: panes, clients: clients)?.client?.tty, "/dev/ttys002")
    }

    /// Against a real tmux server, when one is installed: a detached session's pane is found by its tty.
    func testLiveTmux() throws {
        try XCTSkipIf(Tmux.binary == nil, "tmux not installed")
        let name = "agenthud-test-\(UUID().uuidString.prefix(6))"
        Tmux.run(["new-session", "-d", "-s", name, "sleep 30"])
        defer { Tmux.run(["kill-session", "-t", name]) }
        let pane = try XCTUnwrap(Tmux.panes().first { $0.session == name })
        XCTAssertTrue(pane.tty.hasPrefix("/dev/tty"))
        let selected = Tmux.select(tty: pane.tty)
        XCTAssertNotNil(selected, "the pane was found and selected")
        // What runs in the pane descends from the tmux server, and is labeled tmux.
        let pid = try XCTUnwrap(Int32(Tmux.run(["display-message", "-p", "-t", pane.paneID, "#{pane_pid}"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))
        let anc = ProcTools.ancestry(from: pid, agent: nil, env: [:])
        XCTAssertTrue(anc.inTmux)
        XCTAssertEqual(anc.hostKind, "tmux")
    }

    func testHostKindForTmux() {
        var s = Session(id: "x", agent: .claude, sessionId: "x", base: .idle, stateSince: Date(), lastEventAt: Date())
        s.hostKind = "tmux"
        XCTAssertEqual(s.hostLabel, "tmux")
    }
}

final class WezTermTests: XCTestCase {
    func testParsesPanesWithTTYs() {
        let json = #"[{"window_id":0,"tab_id":3,"pane_id":7,"workspace":"default","title":"zsh","tty_name":"/dev/ttys021","is_active":true},{"window_id":1,"tab_id":4,"pane_id":9,"tty_name":"/dev/ttys030"}]"#
        let panes = WezTerm.parse(Data(json.utf8))
        XCTAssertEqual(panes.first { $0.tty == "/dev/ttys021" }?.paneID, 7)
        XCTAssertEqual(panes.count, 2)
    }

    func testHostKind() {
        XCTAssertEqual(ProcTools.hostKind(app: "/Applications/WezTerm.app", termProgram: nil), "wezterm")
        XCTAssertEqual(ProcTools.hostKind(app: nil, termProgram: "WezTerm"), "wezterm")
    }
}
