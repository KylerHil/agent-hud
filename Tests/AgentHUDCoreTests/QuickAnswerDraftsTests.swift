import XCTest
@testable import AgentHUDCore

final class QuickAnswerDraftsTests: XCTestCase {
    private func source() -> QuickQuestionSource {
        .init(id: "plan-v1", sessionID: "claude:demo", title: "plan.md", path: "/tmp/plan.md", kind: .markdown,
              questions: [.init(id: "one", number: "3", text: "Which database?", line: 4),
                          .init(id: "two", number: "7", text: "Who can sign in?", line: 8)],
              sourceText: "sample", sourceVersion: "v1", updatedAt: Date())
    }

    func testPartialAnswerKeepsNumberAndQuestionAndDoesNotInventChoices() throws {
        let reply = try XCTUnwrap(QuickAnswerComposer.reply(source: source(), answers: ["two": "Team members only"]))
        XCTAssertTrue(reply.contains("7. Who can sign in?\nAnswer: Team members only"))
        XCTAssertFalse(reply.contains("1. Who"))
        XCTAssertTrue(reply.contains("1 question is still unanswered"))
        XCTAssertNil(QuickAnswerComposer.reply(source: source(), answers: ["one": "  \n  "]))
    }

    func testDraftRoundTripAndHandledStateAreIndependent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("drafts.json")
        var drafts = QuickAnswerDrafts()
        drafts.setAnswer("SQLite\nLocal only", sourceID: "plan-v1", questionID: "one")
        XCTAssertFalse(drafts.isHandled("plan-v1"))
        drafts.attach(path: "/tmp/my-plan.md", sessionID: "claude:demo")
        drafts.attach(path: "/tmp/my-plan.md", sessionID: "claude:demo")
        try drafts.save(to: url)
        var restored = try QuickAnswerDrafts.load(from: url)
        XCTAssertEqual(restored.answer(sourceID: "plan-v1", questionID: "one"), "SQLite\nLocal only")
        XCTAssertEqual(restored.attachedPlans["claude:demo"], ["/tmp/my-plan.md"])
        XCTAssertEqual(restored.answer(sourceID: "plan-v2", questionID: "one"), "")
        restored.setHandled(true, sourceID: "plan-v1")
        XCTAssertTrue(restored.isHandled("plan-v1"))
        XCTAssertFalse(restored.isHandled("plan-v2"))
        restored.setHandled(false, sourceID: "plan-v1")
        XCTAssertFalse(restored.isHandled("plan-v1"))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testMalformedDraftsFailInsteadOfSilentlyOverwriting() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("drafts.json")
        try Data("broken json".utf8).write(to: url)
        XCTAssertThrowsError(try QuickAnswerDrafts.load(from: url))
        XCTAssertEqual(try String(contentsOf: url), "broken json")
    }
}
