import XCTest
@testable import AgentHUDCore

final class HookPayloadTests: XCTestCase {
    func testClaudePermissionRequest() {
        let payload: [String: Any] = [
            "hook_event_name": "PermissionRequest", "session_id": "abc", "cwd": "/p/web",
            "transcript_path": "/t.jsonl", "tool_name": "Bash", "tool_use_id": "tu1",
            "tool_input": ["command": "rm -rf build\nmake"],
        ]
        let e = HookPayload.makeEvent(payload: payload, agent: .claude, eventOverride: nil)
        XCTAssertEqual(e.event, "PermissionRequest")
        XCTAssertEqual(e.sessionId, "abc")
        XCTAssertEqual(e.cwd, "/p/web")
        XCTAssertEqual(e.toolUseId, "tu1")
        XCTAssertEqual(e.detail, "rm -rf build make")
        XCTAssertEqual(e.origin, "hook")
    }

    func testSubagentAndNotificationFields() {
        let e = HookPayload.makeEvent(payload: [
            "hook_event_name": "Notification", "session_id": "s", "notification_type": "permission_prompt",
            "notification_text": "Claude needs your permission", "agent_id": "a1", "agent_type": "Explore",
        ], agent: .claude, eventOverride: nil)
        XCTAssertEqual(e.notificationType, "permission_prompt")
        XCTAssertEqual(e.message, "Claude needs your permission")
        XCTAssertEqual(e.agentId, "a1")
        XCTAssertEqual(e.agentType, "Explore")
    }

    func testPromptPreviewAndTruncation() {
        let long = String(repeating: "x", count: 500)
        let e = HookPayload.makeEvent(payload: ["hook_event_name": "UserPromptSubmit", "session_id": "s",
                                                "user_input": long], agent: .codex, eventOverride: nil)
        XCTAssertEqual(e.prompt?.count, 120)
        XCTAssertTrue(e.prompt!.hasSuffix("…"))
    }

    func testMissingFieldsAndOverride() {
        let e = HookPayload.makeEvent(payload: [:], agent: .codex, eventOverride: "Stop")
        XCTAssertEqual(e.event, "Stop")
        XCTAssertEqual(e.sessionId, "unknown")
    }

    func testEventRoundTripsThroughJSONLine() throws {
        var e = AgentEvent(ts: 100, agent: .codex, event: "Stop", sessionId: "s1")
        e.transcriptPath = "/x/y.jsonl"
        e.pid = 42
        let line = try XCTUnwrap(e.jsonLine())
        XCTAssertEqual(line.last, 0x0A)
        XCTAssertTrue(String(decoding: line, as: UTF8.self).contains("\"transcript_path\":\"/x/y.jsonl\""))
        XCTAssertEqual(AgentEvent.parse(line: line.dropLast()), e)
    }

    func testOuterAppBundle() {
        XCTAssertEqual(ProcTools.outerAppBundle(of:
            "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"),
            "/Applications/Visual Studio Code.app")
        XCTAssertNil(ProcTools.outerAppBundle(of: "/bin/zsh"))
        XCTAssertEqual(ProcTools.hostKind(app: nil, termProgram: "iTerm.app"), "iterm")
        XCTAssertEqual(ProcTools.hostKind(app: "/Applications/Cursor.app", termProgram: "vscode"), "cursor")
    }

    func testEventLogAppendsLines() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = dir.appendingPathComponent("events.jsonl")
        XCTAssertTrue(EventLog.append(AgentEvent(agent: .claude, event: "Stop", sessionId: "a"), to: file))
        XCTAssertTrue(EventLog.append(AgentEvent(agent: .claude, event: "Stop", sessionId: "b"), to: file))
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
    }

    func testPromptPreviewDropsEditorContext() {
        let e = HookPayload.makeEvent(payload: [
            "hook_event_name": "UserPromptSubmit", "session_id": "s",
            "prompt": "<ide_opened_file>The user opened a.swift</ide_opened_file>\n<ide_selection>x</ide_selection>fix the build",
        ], agent: .claude, eventOverride: nil)
        XCTAssertEqual(e.prompt, "fix the build")
    }

    func testPastedContentKeepsItsTextWithoutTheTags() {
        XCTAssertEqual(HookPayload.stripContextTags("<pasted_content id=\"c1\">\nfix this\n</pasted_content id=\"c1\"> please"),
                       "fix this\n please")
    }
}
