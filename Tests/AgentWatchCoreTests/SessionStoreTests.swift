import XCTest
@testable import AgentWatchCore

final class SessionStoreTests: XCTestCase {
    var store: SessionStore!
    var t: Double = 1000

    override func setUp() { store = SessionStore(); t = 1000 }

    @discardableResult
    func ev(_ name: String, agent: AgentKind = .claude, sid: String = "s1",
            _ configure: (inout AgentEvent) -> Void = { _ in }) -> Transition? {
        t += 1
        var e = AgentEvent(ts: t, agent: agent, event: name, sessionId: sid)
        e.cwd = "/work/proj"
        e.origin = "hook"
        configure(&e)
        return store.apply(e)
    }

    func state(_ sid: String = "s1", agent: AgentKind = .claude) -> SessionState? {
        store.sessions[SessionStore.key(agent, sid)]?.state
    }

    func testBasicTurnLifecycle() {
        ev("SessionStart")
        XCTAssertEqual(state(), .idle)
        ev("UserPromptSubmit") { $0.prompt = "do it" }
        XCTAssertEqual(state(), .running)
        ev("PreToolUse") { $0.toolName = "Bash"; $0.toolUseId = "t1" }
        ev("PostToolUse") { $0.toolName = "Bash"; $0.toolUseId = "t1" }
        XCTAssertEqual(state(), .running)
        let tr = ev("Stop") { $0.message = "done" }
        XCTAssertEqual(tr?.to, .idle)
        XCTAssertEqual(store.sessions["claude:s1"]?.lastMessage, "done")
        ev("SessionEnd")
        XCTAssertEqual(state(), .ended)
        XCTAssertEqual(store.sessions["claude:s1"]?.projectName, "proj")
    }

    func testPermissionRequestResolvesOnPostToolUse() {
        ev("UserPromptSubmit")
        let tr = ev("PermissionRequest") { $0.toolName = "Bash"; $0.toolUseId = "t1"; $0.detail = "rm -rf x" }
        XCTAssertEqual(tr?.to, .needsInput)
        XCTAssertEqual(store.sessions["claude:s1"]?.primaryPending?.reason, "Permission: Bash")
        // The duplicate Notification must not create a second pending item or a second transition.
        XCTAssertNil(ev("Notification") { $0.notificationType = "permission_prompt" })
        XCTAssertEqual(store.sessions["claude:s1"]?.pending.count, 1)
        ev("PostToolUse") { $0.toolUseId = "t1" }
        XCTAssertEqual(state(), .running)
    }

    func testDeniedPermissionClearsOnPostToolBatch() {
        ev("UserPromptSubmit")
        ev("PermissionRequest") { $0.toolName = "Bash"; $0.toolUseId = "t1" }
        ev("PostToolBatch")
        XCTAssertEqual(state(), .running)
    }

    func testNotificationOnlyAttention() {
        ev("UserPromptSubmit")
        ev("Notification") { $0.notificationType = "agent_needs_input"; $0.message = "Waiting" }
        XCTAssertEqual(state(), .needsInput)
        ev("PreToolUse") { $0.toolName = "Read"; $0.toolUseId = "t9" }
        XCTAssertEqual(state(), .running)
    }

    func testIdlePromptNotificationIsIdle() {
        ev("UserPromptSubmit")
        ev("Stop")
        ev("Notification") { $0.notificationType = "idle_prompt" }
        XCTAssertEqual(state(), .idle)
    }

    func testAskUserQuestionIsNeedsInput() {
        ev("UserPromptSubmit")
        ev("PreToolUse") { $0.toolName = "AskUserQuestion"; $0.toolUseId = "q1" }
        XCTAssertEqual(state(), .needsInput)
        XCTAssertEqual(store.sessions["claude:s1"]?.primaryPending?.reason, "Question")
        ev("PostToolUse") { $0.toolName = "AskUserQuestion"; $0.toolUseId = "q1" }
        XCTAssertEqual(state(), .running)
    }

    func testSubagentPermissionSurvivesOtherSubagentActivity() {
        ev("UserPromptSubmit")
        ev("SubagentStart") { $0.agentId = "a"; $0.agentType = "Explore" }
        ev("SubagentStart") { $0.agentId = "b"; $0.agentType = "Plan" }
        ev("PermissionRequest") { $0.agentId = "a"; $0.toolName = "Bash"; $0.toolUseId = "ta" }
        ev("PostToolUse") { $0.agentId = "b"; $0.toolName = "Read"; $0.toolUseId = "tb" }
        XCTAssertEqual(state(), .needsInput)
        XCTAssertEqual(store.sessions["claude:s1"]?.subagents.count, 2)
        ev("SubagentStop") { $0.agentId = "a" }
        XCTAssertEqual(state(), .running)
        XCTAssertEqual(store.sessions["claude:s1"]?.subagents["a"]?.running, false)
        XCTAssertEqual(store.sessions["claude:s1"]?.subagents["b"]?.running, true)
    }

    func testCodexNewToolClearsEarlierApproval() {
        ev("UserPromptSubmit", agent: .codex)
        ev("PermissionRequest", agent: .codex) { $0.toolName = "Bash"; $0.toolUseId = "c1" }
        XCTAssertEqual(state(agent: .codex), .needsInput)
        ev("PreToolUse", agent: .codex) { $0.toolName = "Bash"; $0.toolUseId = "c2" }
        XCTAssertEqual(state(agent: .codex), .running)
        ev("Interrupt", agent: .codex)
        XCTAssertEqual(state(agent: .codex), .idle)
    }

    func testStopFailureRecordsError() {
        ev("UserPromptSubmit")
        ev("StopFailure") { $0.source = "rate_limit"; $0.message = "Rate limited" }
        XCTAssertEqual(state(), .idle)
        XCTAssertEqual(store.sessions["claude:s1"]?.error, "Rate limited")
        ev("UserPromptSubmit")
        XCTAssertNil(store.sessions["claude:s1"]?.error)
    }

    func testCompactSessionStartKeepsRunning() {
        ev("UserPromptSubmit")
        ev("SessionStart") { $0.source = "compact" }
        XCTAssertEqual(state(), .running)
    }

    func testInferredEventsDoNotOverrideHooks() {
        ev("UserPromptSubmit", agent: .codex)
        ev("RolloutIdle", agent: .codex) { $0.origin = "rollout" }
        XCTAssertEqual(state(agent: .codex), .running)

        var e = AgentEvent(ts: 5000, agent: .codex, event: "RolloutRunning", sessionId: "r1")
        e.origin = "rollout"
        store.apply(e)
        XCTAssertEqual(state("r1", agent: .codex), .running)
    }

    func testHookEventReplacesPidPlaceholder() {
        var seen = AgentEvent(ts: 10, agent: .claude, event: "ProcessSeen", sessionId: "pid-77")
        seen.pid = 77
        seen.origin = "scanner"
        store.apply(seen)
        XCTAssertEqual(store.sessions["claude:pid-77"]?.state, .unknown)
        ev("UserPromptSubmit") { $0.pid = 77 }
        XCTAssertNil(store.sessions["claude:pid-77"])
        XCTAssertEqual(state(), .running)
    }

    func testStaleAndSorting() {
        ev("UserPromptSubmit", sid: "run")
        ev("UserPromptSubmit", sid: "idle"); ev("Stop", sid: "idle")
        ev("UserPromptSubmit", sid: "wait"); ev("PermissionRequest", sid: "wait") { $0.toolUseId = "x" }
        let now = Date(timeIntervalSince1970: t + 10)
        XCTAssertEqual(store.sorted(now: now, staleAfter: 600).map(\.sessionId), ["wait", "run", "idle"])
        let later = Date(timeIntervalSince1970: t + 5000)
        XCTAssertEqual(store.sessions["claude:run"]?.displayState(now: later, staleAfter: 600), .stale)
        XCTAssertEqual(store.sessions["claude:run"]?.displayState(now: later, staleAfter: 600, lastOutputAt: later), .running)
    }

    func testPrune() {
        ev("SessionEnd", sid: "gone")
        ev("SubagentStart") { $0.agentId = "a" }
        ev("SubagentStop") { $0.agentId = "a" }
        store.prune(now: Date(timeIntervalSince1970: t + 400), endedRetention: 180)
        XCTAssertNil(store.sessions["claude:gone"])
        XCTAssertEqual(store.sessions["claude:s1"]?.subagents.count, 0)
    }

    func testTailerReplaysAndFollows() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = dir.appendingPathComponent("events.jsonl")
        EventLog.append(AgentEvent(agent: .claude, event: "SessionStart", sessionId: "a"), to: file)
        var batches: [([String], Bool)] = []
        let tailer = EventTailer(url: file) { evs, replay in batches.append((evs.map(\.sessionId), replay)) }
        tailer.start(interval: 3600)
        EventLog.append(AgentEvent(agent: .claude, event: "Stop", sessionId: "b"), to: file)
        // Simulate a partial write: half a line, then the rest.
        let line = AgentEvent(agent: .claude, event: "Stop", sessionId: "c").jsonLine()!
        let fh = try FileHandle(forWritingTo: file)
        try fh.seekToEnd(); try fh.write(contentsOf: line.prefix(10))
        tailer.poll()
        try fh.write(contentsOf: line.dropFirst(10)); try fh.close()
        tailer.poll()
        tailer.stop()
        XCTAssertEqual(batches.map(\.0), [["a"], ["b"], ["c"]])
        XCTAssertEqual(batches.map(\.1), [true, false, false])
    }

    func testTranscriptInterruptDetection() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        let lines = [
            #"{"type":"assistant","message":{"content":[{"type":"tool_use"}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#,
            #"{"type":"file-history-snapshot"}"#,
        ]
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(TranscriptProbe.claudeWasInterrupted(transcript: file.path))
        try lines.prefix(1).joined().write(to: file, atomically: true, encoding: .utf8)
        XCTAssertFalse(TranscriptProbe.claudeWasInterrupted(transcript: file.path))
    }
}
