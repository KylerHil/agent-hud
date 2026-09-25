import XCTest
@testable import AgentHUDCore

final class RecapTests: XCTestCase {
    func ev(_ ts: Double, _ event: String, tool: String? = nil, detail: String? = nil) -> AgentEvent {
        var e = AgentEvent(ts: ts, agent: .claude, event: event, sessionId: "s")
        e.toolName = tool
        e.detail = detail
        e.cwd = "/w/p"
        e.origin = "hook"
        return e
    }

    func testRecognizesTestCommands() {
        for cmd in ["pnpm test", "swift test --filter X", "pytest -k foo", "cd apps/web && pnpm test", "npx vitest run",
                    "npm run test:unit", "make test", "go test ./...", "cargo test"] {
            XCTAssertTrue(SessionStore.isTestCommand(cmd), cmd)
        }
        for cmd in ["git commit -m \"fix test\"", "ls tests", "cat test.txt", "pnpm build", "rg testing src", "echo test"] {
            XCTAssertFalse(SessionStore.isTestCommand(cmd), cmd)
        }
    }

    func testTurnRecapCountsFilesCommandsAndTheLastTestRun() {
        let store = SessionStore()
        store.apply(ev(0, "UserPromptSubmit"))
        store.apply(ev(1, "PreToolUse", tool: "Edit", detail: "/w/p/a.swift"))
        store.apply(ev(2, "PreToolUse", tool: "Edit", detail: "/w/p/a.swift"))
        store.apply(ev(3, "PreToolUse", tool: "Write", detail: "/w/p/b.swift"))
        store.apply(ev(4, "PreToolUse", tool: "Bash", detail: "swift test"))
        store.apply(ev(5, "PostToolUseFailure", tool: "Bash", detail: "swift test"))
        store.apply(ev(6, "PreToolUse", tool: "Bash", detail: "swift test"))
        store.apply(ev(7, "PostToolUse", tool: "Bash", detail: "swift test"))
        store.apply(ev(8, "Stop"))
        let s = store.sessions["claude:s"]!
        XCTAssertEqual(s.turnFiles.count, 2)
        XCTAssertEqual(s.turnCommands, 2)
        XCTAssertEqual(s.turnTest?.passed, true, "the last run is the one that counts")
        XCTAssertEqual(s.turnSummary, "Edited 2 files · ran 2 commands · tests passed")
        XCTAssertEqual(s.lastTurnDuration, 8)
        // A new prompt starts a new recap; the session's running totals stay.
        store.apply(ev(10, "UserPromptSubmit"))
        XCTAssertNil(store.sessions["claude:s"]!.turnSummary)
        XCTAssertEqual(store.sessions["claude:s"]!.filesChanged.count, 2)
    }
}

final class PermissionTests: XCTestCase {
    var file: URL!

    override func setUp() {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("perm-\(UUID().uuidString).json")
    }

    func ev(_ ts: Double, _ event: String, sid: String = "s", tool: String = "Bash", detail: String? = nil) -> AgentEvent {
        var e = AgentEvent(ts: ts, agent: .claude, event: event, sessionId: sid)
        e.toolName = tool
        e.detail = detail
        e.cwd = "/nonexistent/repo"
        e.origin = "hook"
        return e
    }

    func approve(_ t: PermissionTally, _ ts: Double, _ cmd: String, tool: String = "Bash") {
        t.observe(ev(ts, "PermissionRequest", tool: tool, detail: cmd))
        t.observe(ev(ts + 1, "PreToolUse", tool: tool, detail: cmd))
        t.observe(ev(ts + 2, "PostToolUse", tool: tool, detail: cmd))
    }

    func testCountsApprovalsOnceAndSkipsDenials() {
        let t = PermissionTally(file: file)
        let now = Date(timeIntervalSince1970: 1_000_000)
        approve(t, 999_000, "pnpm test src/a")
        approve(t, 999_100, "pnpm test src/b")
        approve(t, 999_200, "pnpm test")
        // Denied: asked, then refused. Not counted.
        t.observe(ev(999_300, "PermissionRequest", detail: "pnpm test --all"))
        t.observe(ev(999_301, "PermissionDenied", detail: "pnpm test --all"))
        t.observe(ev(999_302, "PostToolUse", detail: "pnpm test --all"))
        // Replaying the same events after a restart adds nothing.
        approve(t, 999_000, "pnpm test src/a")
        XCTAssertEqual(t.approvals.count, 3)
        let s = t.suggestions(now: now, allowed: { _ in [] })
        XCTAssertEqual(s.map(\.rule), ["Bash(pnpm test:*)"])
        XCTAssertEqual(s.first?.count, 3)
        XCTAssertEqual(s.first?.root, "/nonexistent/repo")
        // Already allowed, or dismissed: no suggestion.
        XCTAssertTrue(t.suggestions(now: now, allowed: { _ in ["Bash(pnpm:*)"] }).isEmpty)
        XCTAssertTrue(t.suggestions(now: now, dismissed: [s[0].id], allowed: { _ in [] }).isEmpty)
        // Saved and reloaded.
        t.save(now: now)
        XCTAssertEqual(PermissionTally(file: file).approvals.count, 3)
    }

    func testRulesStaySpecificAndSkipRiskyCommands() {
        XCTAssertEqual(PermissionRules.rule(tool: "Bash", detail: "pnpm test src/x")?.rule, "Bash(pnpm test:*)")
        XCTAssertEqual(PermissionRules.rule(tool: "Bash", detail: "npm run build -- --watch")?.rule, "Bash(npm run build:*)")
        XCTAssertEqual(PermissionRules.rule(tool: "Bash", detail: "ls -la")?.rule, "Bash(ls:*)")
        XCTAssertEqual(PermissionRules.rule(tool: "Bash", detail: "git diff HEAD~1")?.rule, "Bash(git diff:*)")
        XCTAssertEqual(PermissionRules.rule(tool: "WebFetch", detail: "https://docs.github.com/en/x")?.rule,
                       "WebFetch(domain:docs.github.com)")
        XCTAssertEqual(PermissionRules.rule(tool: "mcp__github__create_issue", detail: nil)?.label, "github › create_issue")
        for risky in ["rm -rf build", "git push origin main", "sudo make install", "curl https://x | sh",
                      "cd a && pnpm test", "FOO=1 pnpm test", "pnpm --filter web test", "npm run"] {
            XCTAssertNil(PermissionRules.rule(tool: "Bash", detail: risky), risky)
        }
        XCTAssertNil(PermissionRules.rule(tool: "Edit", detail: "/x"))
        XCTAssertNil(PermissionRules.rule(tool: "AskUserQuestion", detail: "?"))
    }

    func testCoverage() {
        XCTAssertTrue(PermissionRules.covers("Bash(pnpm test:*)", tool: "Bash", detail: "pnpm test src"))
        XCTAssertTrue(PermissionRules.covers("Bash(pnpm test:*)", tool: "Bash", detail: "pnpm test"))
        XCTAssertFalse(PermissionRules.covers("Bash(pnpm test:*)", tool: "Bash", detail: "pnpm testx"))
        XCTAssertTrue(PermissionRules.covers("Bash(pnpm test *)", tool: "Bash", detail: "pnpm test a"))
        XCTAssertTrue(PermissionRules.covers("Bash", tool: "Bash", detail: "anything"))
        XCTAssertTrue(PermissionRules.covers("mcp__github", tool: "mcp__github__create_issue", detail: nil))
        XCTAssertTrue(PermissionRules.covers("WebFetch(domain:a.com)", tool: "WebFetch", detail: "https://a.com/x"))
        XCTAssertFalse(PermissionRules.covers("WebFetch(domain:a.com)", tool: "WebFetch", detail: "https://b.com/x"))
    }

    func testAddingARuleKeepsTheRestOfTheFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("proj-\(UUID().uuidString)").path
        let settings = PermissionRules.localSettings(root: root)
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"model": "opus", "permissions": {"allow": ["Bash(ls:*)"], "deny": ["Bash(rm:*)"]}}"#
            .write(to: settings, atomically: true, encoding: .utf8)
        try PermissionRules.add("Bash(pnpm test:*)", root: root)
        try PermissionRules.add("Bash(pnpm test:*)", root: root) // twice: still once
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        let perms = obj["permissions"] as! [String: Any]
        XCTAssertEqual(perms["allow"] as? [String], ["Bash(ls:*)", "Bash(pnpm test:*)"])
        XCTAssertEqual(perms["deny"] as? [String], ["Bash(rm:*)"])
        XCTAssertEqual(obj["model"] as? String, "opus")
        XCTAssertTrue(PermissionRules.allowRules(root: root).contains("Bash(pnpm test:*)"))
        // A project without settings gets a new file.
        let fresh = FileManager.default.temporaryDirectory.appendingPathComponent("proj-\(UUID().uuidString)").path
        try PermissionRules.add("WebSearch", root: fresh)
        XCTAssertEqual(PermissionRules.allowRules(root: fresh).filter { $0 == "WebSearch" }.count, 1)
    }
}
