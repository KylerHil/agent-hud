import XCTest
@testable import AgentHUDCore

final class BrokerTests: XCTestCase {
    func testReadOnlyCommandsForReviewTurns() {
        for ok in ["git diff HEAD~1", "git log --oneline -5", "rg subtract", "grep -n add math.ts", "ls -la",
                   "cat math.ts", "sed -n '1,40p' a.ts", "git diff | head -50", "find . -name '*.ts'", "wc -l a.ts"] {
            XCTAssertTrue(BrokerService.isReadOnly(ok), ok)
        }
        for bad in ["rm a.txt", "git commit -am x", "echo hi > a.txt", "cat a > b", "ls; rm x", "ls && touch y",
                    "find . -delete", "find . -exec rm {} \\;", "sed -i '' s/a/b/ x", "git checkout -- .", "npm test",
                    "cat $(which x)", "ls `pwd`"] {
            XCTAssertFalse(BrokerService.isReadOnly(bad), bad)
        }
    }

    func testBranchSlugFromGoal() {
        XCTAssertEqual(BrokerService.slug("Export an estimate as a PDF, with tax"), "export-an-estimate-as")
        XCTAssertEqual(BrokerService.slug("!!!"), "work")
    }

    func testClaudeArguments() {
        let fresh = ClaudeDriver.arguments(StartOptions(agent: .claude, cwd: "/r", permissionMode: "acceptEdits", model: "haiku"))
        XCTAssertTrue(fresh.contains("--permission-prompt-tool"), "prompts only reach the host with the stdio tool (§10.1)")
        XCTAssertEqual(fresh.suffix(4), ["--permission-mode", "acceptEdits", "--model", "haiku"])
        XCTAssertFalse(fresh.contains("--resume"))
        let fork = ClaudeDriver.arguments(StartOptions(agent: .claude, cwd: "/r", resume: "abc", fork: true, permissionMode: "default"))
        XCTAssertTrue(fork.contains("--fork-session"))
        XCTAssertFalse(fork.contains("--permission-mode"), "default needs no flag")
    }

    func testClaudeTranscriptPathMatchesClaudesFolderNames() {
        let p = ClaudeDriver.transcriptPath(cwd: "/private/tmp/claude-501/-Users-k/x.y", sessionId: "s1")
        XCTAssertTrue(p.hasSuffix("/.claude/projects/-private-tmp-claude-501--Users-k-x-y/s1.jsonl"), p)
    }

    func testWireRoundTrip() throws {
        var s = ManagedSession(id: "k", agent: .codex, cwd: "/r", status: .waiting,
                               capabilities: ManagedSession.capabilities(for: .codex), startedAt: Date(timeIntervalSince1970: 100))
        s.sessionId = "t1"
        s.pending = [PendingRequest(id: "p", kind: .question, tool: "Question", summary: "Which?",
                                    questions: [PendingQuestion(id: "q", header: nil, question: "Which?", options: ["A", "B"], multiSelect: false)],
                                    since: Date(timeIntervalSince1970: 200))]
        var m = BrokerMessage(kind: "session")
        m.session = s
        let back = try BrokerCoding.decoder.decode(BrokerMessage.self, from: BrokerCoding.encoder.encode(m))
        XCTAssertEqual(back.session, s)
        XCTAssertEqual(back.session?.storeID, "codex:t1")
        XCTAssertTrue(s.capabilities.steerActiveTurn)
        XCTAssertFalse(ManagedSession.capabilities(for: .claude).steerActiveTurn, "Claude queues instead of steering")

        var r = BrokerRequest(op: "pairStart")
        r.pair = PairConfig(goal: "g", root: "/r", testCommand: "swift test")
        let rb = try BrokerCoding.decoder.decode(BrokerRequest.self, from: BrokerCoding.encoder.encode(r))
        XCTAssertEqual(rb.pair, r.pair)
    }

    func testSocketPathFitsSockaddr() {
        XCTAssertLessThan(BrokerInfo.socketPath.utf8.count, 104)
        XCTAssertEqual(BrokerInfo.socketPath, BrokerInfo.socketPath, "stable across calls (no per-process hashing)")
    }
}
