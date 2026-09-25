import XCTest
@testable import AgentHUDCore

final class QuickQuestionsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("quick-questions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func json(_ value: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    private func claude(_ role: String, _ text: String, id: String = UUID().uuidString) -> String {
        json(["type": role, "message": ["id": id, "content": [["type": "text", "text": text]]]])
    }

    private func codex(_ role: String, _ text: String) -> String {
        json(["type": "response_item", "payload": ["type": "message", "role": role,
              "content": [["type": role == "user" ? "input_text" : "output_text", "text": text]]]])
    }

    private func write(_ text: String, _ path: String) throws -> URL {
        let file = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func session(_ agent: AgentKind = .claude, transcript: URL? = nil) -> Session {
        var s = Session(id: "\(agent.rawValue):s", agent: agent, sessionId: "s", base: .idle,
                        stateSince: Date(), lastEventAt: Date())
        s.root = directory.path; s.cwd = directory.path; s.launchDir = directory.path
        s.transcriptPath = transcript?.path
        return s
    }

    func testMarkdownSectionsPreserveNumberLineAndChoices() {
        let text = """
        # Plan
        Why does this exist?
        ## Open questions
        4. **Which database should we use?**
           - SQLite — local and simple
           - Postgres — shared storage
        7. Who should receive alerts?
        ## Implementation
        Is this helper still needed?
        """
        let found = QuickQuestionScanner.markdown(text: text)
        XCTAssertEqual(found.map(\.number), ["4", "7"])
        XCTAssertEqual(found.map(\.line), [4, 7])
        XCTAssertEqual(found.map(\.text), ["Which database should we use?", "Who should receive alerts?"])
        XCTAssertEqual(found[0].options, ["SQLite — local and simple", "Postgres — shared storage"])
        XCTAssertTrue(found[1].options.isEmpty)
    }

    func testMarkdownIgnoresCodeQuotesCompletedAndAnsweredItems() {
        let text = """
        ## Open questions
        ```md
        1. Is this example a question?
        ```
        > 2. Is this quoted question relevant?
        - [x] Did we already pick a color?
        3. Which account?
           Answer: Work account
        4. What retention period?
        ### Answered questions
        5. What default was selected?
        ## More work
        6. Should this be ignored?
        """
        let found = QuickQuestionScanner.markdown(text: text)
        XCTAssertEqual(found.map(\.text), ["What retention period?"])
        XCTAssertEqual(found.first?.number, "4")
    }

    func testDecisionsNeededAndUncheckedItemsWithoutQuestionMark() {
        let found = QuickQuestionScanner.markdown(text: "## Decisions needed\n- [ ] Choose the initial rollout region\n- [ ] Set retention period")
        XCTAssertEqual(found.map(\.text), ["Choose the initial rollout region", "Set retention period"])
        XCTAssertTrue(QuickQuestionScanner.markdown(text: "# Plan\n1. Which region?").isEmpty)
    }

    func testBoldQuestionLabelAndInlineCodeQuestion() {
        let found = QuickQuestionScanner.markdown(text: "**Open questions:**\n1. `cacheTTL`: which duration should we use?\n## Implementation\n2. Should this be ignored?")
        XCTAssertEqual(found.map(\.text), ["`cacheTTL`: which duration should we use?"])
        XCTAssertEqual(found.first?.line, 2)
    }

    func testAssistantPlainProseAndLetterChoices() {
        let found = QuickQuestionScanner.assistant(text: "Should alerts include completed sessions?\nA) Only failures\nB) All sessions\n\n2. Which project should run first?")
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found[0].line, 1)
        XCTAssertEqual(found[0].options, ["Only failures", "All sessions"])
        XCTAssertEqual(found[1].number, "2")
    }

    func testOptionsLabelDoesNotConsumeNextNumberedQuestion() {
        let found = QuickQuestionScanner.assistant(text: "1. Which region?\nOptions:\n- US\n- EU\n2. Which account?")
        XCTAssertEqual(found.map(\.number), ["1", "2"])
        XCTAssertEqual(found[0].options, ["US", "EU"])
    }

    func testIdenticalQuestionInNewTurnGetsNewSourceIdentity() {
        let first = [claude("user", "Plan it", id: "user-1"), claude("assistant", "Which region?", id: "reply-1")]
        let second = first + [claude("user", "Ask again", id: "user-2"), claude("assistant", "Which region?", id: "reply-2")]
        let a = QuickQuestionScanner.transcript(lines: first, agent: .claude, sessionID: "s", path: "/t").first
        let b = QuickQuestionScanner.transcript(lines: second, agent: .claude, sessionID: "s", path: "/t").first
        XCTAssertNotEqual(a?.id, b?.id)
        XCTAssertEqual(a?.sourceVersion, b?.sourceVersion)
        let tool = json(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "x", "content": "done"]]]])
        XCTAssertEqual(b?.id, QuickQuestionScanner.transcript(lines: second + [tool], agent: .claude, sessionID: "s", path: "/t").first?.id)
        let codexFirst = [json(["type": "event_msg", "payload": ["type": "task_started", "turn_id": "turn-1"]]), codex("assistant", "Which region?")]
        let codexSecond = [json(["type": "event_msg", "payload": ["type": "task_started", "turn_id": "turn-2"]]), codex("assistant", "Which region?")]
        XCTAssertNotEqual(QuickQuestionScanner.transcript(lines: codexFirst, agent: .codex, sessionID: "s", path: "/t").first?.id,
                          QuickQuestionScanner.transcript(lines: codexSecond, agent: .codex, sessionID: "s", path: "/t").first?.id)
    }

    func testClaudeUsesLatestAssistantAndClearsOnRealUserPrompt() {
        var lines = [claude("user", "Plan it"), claude("assistant", "1. Which storage?"),
                     claude("user", "SQLite"), claude("assistant", "2. Which retention period?")]
        var found = QuickQuestionScanner.transcript(lines: lines, agent: .claude, sessionID: "claude:s", path: "/t")
        XCTAssertEqual(found.flatMap(\.questions).map(\.text), ["Which retention period?"])
        lines.append(claude("user", "30 days"))
        found = QuickQuestionScanner.transcript(lines: lines, agent: .claude, sessionID: "claude:s", path: "/t")
        XCTAssertTrue(found.isEmpty)
    }

    func testOffhandChatQuestionsAreLooseAndStructuredOnesAreNot() {
        let offhand = QuickQuestionScanner.transcript(lines: [claude("user", "Ship it"),
            claude("assistant", "Released 1.3.5. What would you like to work on next?")],
            agent: .claude, sessionID: "s", path: "/t")
        XCTAssertEqual(offhand.map(\.loose), [true])
        for reply in ["1. Which storage?", "Which storage?\na) SQLite\nb) Postgres", "## Open questions\n- Retention period"] {
            let found = QuickQuestionScanner.transcript(lines: [claude("user", "Plan it"), claude("assistant", reply)],
                                                        agent: .claude, sessionID: "s", path: "/t")
            XCTAssertEqual(found.map(\.loose), [false], reply)
        }
    }

    func testTaskNotificationsAndCommandOutputDoNotEndTheTurn() {
        let lines = [claude("user", "Plan it"), claude("assistant", "1. Which storage?"),
                     claude("user", "<task-notification>\n<task-id>abc</task-id>\n</task-notification>"),
                     claude("user", "<local-command-stdout>Compacted</local-command-stdout>")]
        let found = QuickQuestionScanner.transcript(lines: lines, agent: .claude, sessionID: "s", path: "/t")
        XCTAssertEqual(found.flatMap(\.questions).map(\.text), ["Which storage?"])
    }

    func testClaudeToolResultQuestionsAndMetaMessagesAreNotUserPrompts() {
        let lines = [claude("user", "Plan it"), claude("assistant", "Which account?"),
                     json(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "x", "content": "Which secret should I expose?"]]]]),
                     json(["type": "user", "isMeta": true, "message": ["content": "System status message"]])]
        let found = QuickQuestionScanner.transcript(lines: lines, agent: .claude, sessionID: "s", path: "/t")
        XCTAssertEqual(found.flatMap(\.questions).map(\.text), ["Which account?"])
    }

    func testClaudeCombinesTextBlocksInOneAssistantMessage() {
        let lines = [claude("assistant", "1. Which region?", id: "same"),
                     claude("assistant", "2. Which account?", id: "same")]
        XCTAssertEqual(QuickQuestionScanner.transcript(lines: lines, agent: .claude, sessionID: "s", path: "/t")
            .flatMap(\.questions).map(\.number), ["1", "2"])
    }

    func testClaudeStructuredRequestOptionsAndAnsweredRemoval() {
        let request = json(["type": "assistant", "message": ["content": [["type": "tool_use", "name": "AskUserQuestion", "id": "ask-1",
             "input": ["questions": [["question": "Which storage?", "options": [["label": "SQLite", "description": "Local"], ["label": "Postgres"]]]]]]]]])
        let result = json(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "ask-1", "content": "SQLite"]]]])
        let found = QuickQuestionScanner.transcript(lines: [request], agent: .claude, sessionID: "s", path: "/t")
        XCTAssertEqual(found.first?.kind, .interactive)
        XCTAssertEqual(found.first?.questions.first?.options, ["SQLite — Local", "Postgres"])
        XCTAssertTrue(QuickQuestionScanner.transcript(lines: [request, result], agent: .claude, sessionID: "s", path: "/t").isEmpty)
    }

    func testCodexResponseItemsLatestTurnAndToolOutputIsolation() {
        let lines = [codex("user", "Plan it"), codex("assistant", "Which region?"), codex("user", "US"),
                     json(["type": "response_item", "payload": ["type": "function_call_output", "call_id": "x", "output": "Should this be ignored?"]]),
                     codex("assistant", "1. Which account?")]
        let found = QuickQuestionScanner.transcript(lines: lines, agent: .codex, sessionID: "s", path: "/t")
        XCTAssertEqual(found.flatMap(\.questions).map(\.text), ["Which account?"])
    }

    func testCodexEventMessagesAndTaskBoundary() {
        var lines = [json(["type": "event_msg", "payload": ["type": "user_message", "message": "Plan it"]]),
                     json(["type": "event_msg", "payload": ["type": "task_complete", "last_agent_message": "Which region?"]])]
        XCTAssertEqual(QuickQuestionScanner.transcript(lines: lines, agent: .codex, sessionID: "s", path: "/t").first?.questions.first?.text, "Which region?")
        lines.append(json(["type": "event_msg", "payload": ["type": "task_started"]]))
        XCTAssertTrue(QuickQuestionScanner.transcript(lines: lines, agent: .codex, sessionID: "s", path: "/t").isEmpty)
    }

    func testCodexStructuredRequestAndMatchingResult() {
        let input = json(["questions": [["id": "region", "question": "Which region?", "options": [["label": "US"], ["label": "EU"]]]]])
        let call = json(["type": "response_item", "payload": ["type": "function_call", "name": "functions.request_user_input", "call_id": "ask", "arguments": input]])
        let unrelated = json(["type": "response_item", "payload": ["type": "function_call_output", "call_id": "other", "output": "done"]])
        let result = json(["type": "response_item", "payload": ["type": "function_call_output", "call_id": "ask", "output": "US"]])
        let found = QuickQuestionScanner.transcript(lines: [call, unrelated], agent: .codex, sessionID: "s", path: "/t")
        XCTAssertEqual(found.first?.kind, .interactive)
        XCTAssertEqual(found.first?.questions.first?.options, ["US", "EU"])
        XCTAssertTrue(QuickQuestionScanner.transcript(lines: [call, result], agent: .codex, sessionID: "s", path: "/t").isEmpty)
    }

    func testMalformedAndPartialTranscriptLinesDoNotInventQuestions() {
        let lines = ["{", "not json", "{\"type\":\"assistant\"", claude("assistant", "Which region?")]
        XCTAssertEqual(QuickQuestionScanner.transcript(lines: lines, agent: .claude, sessionID: "s", path: "/t").count, 1)
        XCTAssertTrue(QuickQuestionScanner.transcript(lines: lines, agent: .chatgpt, sessionID: "s", path: "/t").isEmpty)
    }

    func testReferencedMarkdownAndStableVersionMatchExplicitRead() throws {
        let plan = try write("# Plan\n## Open questions\n5. Which account?", "docs/plan.md")
        let log = try write(claude("assistant", "I left questions in [the plan](docs/plan.md:3).") + "\n", "session.jsonl")
        let s = session(transcript: log)
        let found = try XCTUnwrap(QuickQuestionScanner.scan(session: s).first { $0.kind == .markdown })
        let explicit = try XCTUnwrap(QuickQuestionScanner.file(path: plan.path, sessionID: s.id))
        XCTAssertEqual(found, explicit)
        XCTAssertEqual(found.questions.first?.line, 3)
        XCTAssertEqual(found, QuickQuestionScanner.scan(session: s).first { $0.kind == .markdown })
        try "## Open questions\n5. Which region?".write(to: plan, atomically: true, encoding: .utf8)
        let changed = try XCTUnwrap(QuickQuestionScanner.file(path: plan.path, sessionID: s.id))
        XCTAssertNotEqual(changed.id, found.id)
        XCTAssertNotEqual(changed.sourceVersion, found.sourceVersion)
        XCTAssertNotEqual(found.id, QuickQuestionScanner.file(path: plan.path, sessionID: "another")?.id)
    }

    func testAutomaticDiscoveryRejectsOutsidePathsAndEscapingSymlinks() throws {
        let root = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = try write("## Open questions\n1. Which outside account?", "outside.md")
        let link = root.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let log = try write(claude("assistant", "See `../outside.md`, `link.md`, and [a remote plan](https://example.com/plan.md).") + "\n", "project/session.jsonl")
        var s = session(transcript: log); s.root = root.path; s.cwd = root.path; s.launchDir = root.path
        XCTAssertTrue(QuickQuestionScanner.scan(session: s).isEmpty)
        XCTAssertNotNil(QuickQuestionScanner.file(path: outside.path, sessionID: s.id), "Explicit selection is permitted outside the project")
    }

    func testMarkdownReferenceCanContainSpacesAndAnchor() throws {
        _ = try write("## Open questions\n1. Which account?", "docs/my plan.md")
        let log = try write(claude("assistant", "Read [the plan](docs/my%20plan.md#open-questions).") + "\n", "session.jsonl")
        XCTAssertEqual(QuickQuestionScanner.scan(session: session(transcript: log)).map(\.kind), [.markdown])
    }

    func testNoBroadScanAndOldTurnFilesAreNotRediscovered() throws {
        let plan = try write("## Open questions\n1. Which account?", "forgotten.md")
        var s = session()
        XCTAssertTrue(QuickQuestionScanner.scan(session: s).isEmpty)
        s.filesChanged = [plan.path]
        s.turnStartedAt = Date().addingTimeInterval(60)
        XCTAssertTrue(QuickQuestionScanner.scan(session: s).isEmpty)
        s.turnFiles = [plan.path]
        XCTAssertEqual(QuickQuestionScanner.scan(session: s).count, 1)
    }

    func testClaudeWriteAndCodexApplyPatchFindOnlyCurrentTurnMarkdown() throws {
        _ = try write("## Open questions\n1. Which account?", "plan.md")
        let claudeCall = json(["type": "assistant", "message": ["content": [["type": "tool_use", "name": "Write", "id": "write",
             "input": ["file_path": "plan.md", "content": "content irrelevant"]]]]])
        let claudeLog = try write(claudeCall + "\n", "claude.jsonl")
        XCTAssertEqual(QuickQuestionScanner.scan(session: session(.claude, transcript: claudeLog)).map(\.kind), [.markdown])
        try (claudeCall + "\n" + claude("user", "Answered; continue") + "\n").write(to: claudeLog, atomically: true, encoding: .utf8)
        XCTAssertTrue(QuickQuestionScanner.scan(session: session(.claude, transcript: claudeLog)).isEmpty)
        let codexCall = json(["type": "response_item", "payload": ["type": "custom_tool_call", "name": "apply_patch", "call_id": "edit",
             "input": "*** Begin Patch\n*** Add File: plan.md\n+## Open questions\n*** End Patch"]])
        let codexLog = try write(codexCall + "\n", "codex.jsonl")
        XCTAssertEqual(QuickQuestionScanner.scan(session: session(.codex, transcript: codexLog)).map(\.kind), [.markdown])
    }

    func testFileBoundsAndUnsupportedFormats() throws {
        let large = try write("## Open questions\n1. Which account?\n" + String(repeating: "x", count: 512 * 1024), "large.md")
        let plain = try write("## Open questions\n1. Which account?", "plain.txt")
        XCTAssertNil(QuickQuestionScanner.file(path: large.path, sessionID: "s"))
        XCTAssertNil(QuickQuestionScanner.file(path: plain.path, sessionID: "s"))
        XCTAssertTrue(QuickQuestionScanner.scan(session: session(transcript: directory)).isEmpty)
    }
}
