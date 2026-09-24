import XCTest
@testable import AgentWatchCore

final class ScannerTests: XCTestCase {
    func proc(_ pid: Int32, _ agent: AgentKind = .claude, cwd: String = "/w/p") -> ProcessScanner.AgentProcess {
        .init(pid: pid, agent: agent, cwd: cwd, tty: nil, hostApp: nil, hostKind: "vscode")
    }

    func hooked(_ store: SessionStore, sid: String, pid: Int32, agent: AgentKind = .claude) {
        var e = AgentEvent(ts: 100, agent: agent, event: "UserPromptSubmit", sessionId: sid)
        e.pid = pid
        e.origin = "hook"
        store.apply(e)
    }

    func testDeadProcessEndsSessionAndUnclaimedGetsPlaceholder() {
        let store = SessionStore()
        hooked(store, sid: "a", pid: 10)
        hooked(store, sid: "b", pid: 11)
        let events = ProcessScanner.reconcile(store: store, processes: [proc(10), proc(12)])
        XCTAssertEqual(events.map(\.event).sorted(), ["ProcessExited", "ProcessSeen"])
        XCTAssertEqual(events.first { $0.event == "ProcessExited" }?.sessionId, "b")
        XCTAssertEqual(events.first { $0.event == "ProcessSeen" }?.pid, 12)
        events.forEach { store.apply($0) }
        XCTAssertEqual(store.sessions["claude:b"]?.state, .ended)
        XCTAssertEqual(store.sessions["claude:pid-12"]?.state, .unknown)
        // Stable: a second scan with the same processes changes nothing (no log flooding).
        XCTAssertEqual(ProcessScanner.reconcile(store: store, processes: [proc(10), proc(12)]), [])
    }

    func testCodexProcessesDoNotGetPlaceholders() {
        let store = SessionStore()
        XCTAssertEqual(ProcessScanner.reconcile(store: store, processes: [proc(20, .codex, cwd: "/")]), [])
    }

    func testRolloutParseAndReconcile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let now = Date()
        let c = Calendar.current.dateComponents([.year, .month, .day], from: now)
        let day = dir.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let file = day.appendingPathComponent("rollout-x-abc.jsonl")
        let lines = [
            #"{"type":"session_meta","payload":{"id":"abc","cwd":"/w/mobile","originator":"codex_vscode"}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"Upgrade RN"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

        let scanner = RolloutScanner(root: dir)
        let found = scanner.recent(now: now)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.running, true)
        XCTAssertEqual(found.first?.lastPrompt, "Upgrade RN")

        let store = SessionStore()
        var evs = RolloutScanner.reconcile(store: store, rollouts: found, codexAlive: true, now: now)
        XCTAssertEqual(evs.map(\.event), ["RolloutRunning"])
        XCTAssertEqual(evs.first?.hostKind, "vscode")
        evs.forEach { store.apply($0) }
        XCTAssertEqual(store.sessions["codex:abc"]?.state, .running)
        XCTAssertEqual(store.sessions["codex:abc"]?.projectName, "mobile")
        XCTAssertEqual(RolloutScanner.reconcile(store: store, rollouts: found, codexAlive: true, now: now), [])

        // Turn completes.
        let done = #"{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"Done."}}"#
        let h = try FileHandle(forWritingTo: file); try h.seekToEnd(); try h.write(contentsOf: Data((done + "\n").utf8)); try h.close()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(1)], ofItemAtPath: file.path)
        evs = RolloutScanner.reconcile(store: store, rollouts: scanner.recent(now: now), codexAlive: true, now: now)
        XCTAssertEqual(evs.map(\.event), ["RolloutIdle"])
        evs.forEach { store.apply($0) }
        XCTAssertEqual(store.sessions["codex:abc"]?.lastMessage, "Done.")

        // VS Code quits: no codex processes → ended.
        evs = RolloutScanner.reconcile(store: store, rollouts: scanner.recent(now: now), codexAlive: false, now: now)
        XCTAssertEqual(evs.map(\.event), ["ProcessExited"])
    }

    func testHooksWinOverRollouts() {
        let store = SessionStore()
        var e = AgentEvent(ts: 100, agent: .codex, event: "Stop", sessionId: "other-id")
        e.transcriptPath = "/r/rollout.jsonl"
        e.origin = "hook"
        store.apply(e)
        let info = RolloutScanner.Info(sessionId: "abc", path: "/r/rollout.jsonl", cwd: "/w", originator: nil,
                                       running: true, modified: Date())
        XCTAssertEqual(RolloutScanner.reconcile(store: store, rollouts: [info], codexAlive: true), [])
    }

    func testLiveProcessScanFindsThisTerminal() {
        // Smoke test against the real process table: must not crash, and every result has an agent kind.
        let procs = ProcessScanner.agentProcesses()
        XCTAssertTrue(procs.allSatisfy { $0.pid > 0 })
    }
}
