import XCTest
@testable import AgentHUDCore

final class ScannerTests: XCTestCase {
    func proc(_ pid: Int32, _ agent: AgentKind = .claude, cwd: String? = "/w/p") -> ProcessScanner.AgentProcess {
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

    func testHooklessProcessesInOneProjectShareOneRow() {
        let store = SessionStore()
        var procs = (40...44).map { proc(Int32($0), cwd: "/w/p") }
        for i in procs.indices { procs[i].started = Date(timeIntervalSince1970: TimeInterval(i)) }
        let first = ProcessScanner.reconcile(store: store, processes: procs, now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.pid, 44, "the newest process stands for the group")
        XCTAssertEqual(first.first?.title, "5 Claude processes without hooks")
        first.forEach { store.apply($0) }
        // Stable while nothing changes; the same row updates its count when one exits.
        XCTAssertEqual(ProcessScanner.reconcile(store: store, processes: procs, now: Date(timeIntervalSince1970: 1003)), [])
        let fewer = ProcessScanner.reconcile(store: store, processes: Array(procs.dropFirst()), now: Date(timeIntervalSince1970: 1006))
        XCTAssertEqual(fewer.map(\.title), ["4 Claude processes without hooks"])
        XCTAssertEqual(fewer.first?.pid, 44)
    }

    func testSessionThatNeverDidAnythingIsNeverActive() {
        let store = SessionStore()
        var e = AgentEvent(ts: 1, agent: .claude, event: "SessionStart", sessionId: "empty")
        e.origin = "hook"
        store.apply(e)
        XCTAssertTrue(store.sessions["claude:empty"]!.neverActive)
        var p = AgentEvent(ts: 2, agent: .claude, event: "UserPromptSubmit", sessionId: "empty")
        p.origin = "hook"
        p.prompt = "hi"
        store.apply(p)
        XCTAssertFalse(store.sessions["claude:empty"]!.neverActive)
    }

    func testARunningShellAfterAPermissionPromptMeansItWasApproved() {
        let store = SessionStore()
        var ask = AgentEvent(ts: 100, agent: .claude, event: "PermissionRequest", sessionId: "s")
        ask.pid = 50
        ask.toolName = "Bash"
        ask.detail = "python3 sync.py"
        ask.origin = "hook"
        store.apply(ask)
        XCTAssertEqual(store.sessions["claude:s"]?.state, .needsInput)
        let at = { (t: Double) in Date(timeIntervalSince1970: t) }
        let mcp = ProcTools.Entry(pid: 60, ppid: 50, comm: "node", tty: nil, started: at(10))
        let oldShell = ProcTools.Entry(pid: 61, ppid: 50, comm: "zsh", tty: nil, started: at(90))
        let hook = ProcTools.Entry(pid: 62, ppid: 50, comm: "sh", tty: nil, started: at(104.5))
        let batched = ProcTools.Entry(pid: 64, ppid: 50, comm: "zsh", tty: nil, started: at(100.2))
        // Still waiting: the session's MCP server, an earlier shell, a hook just now, and a command that
        // started alongside the prompt.
        XCTAssertEqual(ProcessScanner.approvals(store: store, table: [mcp, oldShell, hook, batched], now: at(105)), [])
        // The approved command's shell has been running for a few seconds.
        let command = ProcTools.Entry(pid: 63, ppid: 50, comm: "zsh", tty: nil, started: at(102))
        let events = ProcessScanner.approvals(store: store, table: [mcp, command], now: at(105))
        XCTAssertEqual(events.map(\.event), ["PermissionGranted"])
        events.forEach { store.apply($0) }
        XCTAssertEqual(store.sessions["claude:s"]?.state, .running)
    }

    func testProcessesWithoutAFolderDoNotGetPlaceholders() {
        let store = SessionStore()
        XCTAssertEqual(ProcessScanner.reconcile(store: store, processes: [proc(30, cwd: nil), proc(31, cwd: "/")]), [])
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
