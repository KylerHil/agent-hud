import XCTest
@testable import AgentHUDCore

final class EditorBridgeTests: XCTestCase {
    func testMatchesMostSpecificConnectedWorkspaceAndRejectsLookalikes() {
        let broad = EditorWorkspace(id: "b", name: "broad", folders: ["/tmp/work"], focused: true)
        let nested = EditorWorkspace(id: "n", name: "nested", folders: ["/tmp/work/api", "/tmp/other"])
        let disconnected = EditorWorkspace(id: "d", name: "closed", folders: ["/tmp/work/api/src"], connected: false)
        XCTAssertEqual(EditorWorkspace.best(in: [broad, nested, disconnected], for: "/tmp/work/api/src/main.swift")?.id, "n")
        XCTAssertNil(EditorWorkspace.best(in: [broad], for: "/tmp/work-other/file"))
        XCTAssertTrue(nested.contains("/tmp/other/src"))
        let remote = EditorWorkspace(id: "r", name: "SSH", folders: ["/tmp/work"], remote: "ssh-remote")
        XCTAssertFalse(remote.contains("/tmp/work"))
    }

    func testWorkspaceSymlinkAndDotSegmentsResolveToSameProject() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("actual"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("alias"), withDestinationURL: base.appendingPathComponent("actual"))
        let w = EditorWorkspace(id: "w", name: "test", folders: [base.appendingPathComponent("alias").path])
        XCTAssertTrue(w.contains(base.appendingPathComponent("actual/./src").path))
    }

    func testTaskStatusRequiresCompletionEvidenceAndLiveConnection() {
        var s = ManagedSession(id: "k", agent: .codex, cwd: "/tmp", status: .idle,
                               capabilities: ManagedSession.capabilities(for: .codex), startedAt: Date())
        XCTAssertEqual(s.coordinationStatus(), .idle)
        s.turns = 1; s.lastTurnStatus = "completed"
        XCTAssertEqual(s.coordinationStatus(), .completed)
        s.error = "Turn failed"
        XCTAssertEqual(s.coordinationStatus(), .failed)
        s.status = .busy
        XCTAssertEqual(s.coordinationStatus(), .running)
        s.pending = [PendingRequest(id: "p", kind: .permission, tool: "command", summary: "needs permission", since: Date())]
        XCTAssertEqual(s.coordinationStatus(), .waiting)
        XCTAssertEqual(s.coordinationStatus(connected: false), .disconnected)
        s.status = .exited
        XCTAssertEqual(s.coordinationStatus(), .stopped)
    }

    func testOldPersistedSessionsDecodeWithNewOptionalEvidence() throws {
        var s = ManagedSession(id: "k", agent: .claude, cwd: "/tmp", status: .idle,
                               capabilities: ManagedSession.capabilities(for: .claude), startedAt: Date())
        s.lastReply = "old result"
        let data = try BrokerCoding.encoder.encode(s)
        let back = try BrokerCoding.decoder.decode(ManagedSession.self, from: data)
        XCTAssertEqual(back.lastReply, "old result")
        XCTAssertNil(back.lastTurnStatus)
    }

    func testResolvedCodexApprovalReturnsToRunningAndFailureIsVisible() {
        let host = DriverHost()
        let d = CodexDriver(key: "k", options: StartOptions(agent: .codex, cwd: "/tmp"), server: CodexServer(queue: DispatchQueue(label: "test.codex")), host: host)
        d.notification("turn/started", ["turn": ["id": "turn-1"]])
        d.serverRequest(id: 4, method: "item/commandExecution/requestApproval", params: ["command": "test command"])
        XCTAssertEqual(d.session.coordinationStatus(), .waiting)
        d.notification("serverRequest/resolved", ["requestId": 4])
        XCTAssertEqual(d.session.coordinationStatus(), .running)
        d.notification("turn/completed", ["turn": ["status": "failed", "error": ["message": "Authentication expired"]]])
        XCTAssertEqual(d.session.coordinationStatus(), .failed)
        XCTAssertEqual(d.session.error, "Authentication expired")
        XCTAssertEqual(host.finished, 1)
    }
}

private final class DriverHost: AgentDriverHost {
    var finished = 0
    func driverChanged(_ session: ManagedSession) {}
    func driverTurnFinished(_ key: String, reply: String?, plan: String?, failed: Bool, interrupted: Bool) { finished += 1 }
    func driverExited(_ key: String, error: String?) {}
    func driverPolicy(_ key: String, tool: String, input: [String: Any]) -> ToolPolicy { .ask }
}
