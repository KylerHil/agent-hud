import XCTest
@testable import AgentHUDCore

final class PairEngineTests: XCTestCase {
    private func pair(approve: Bool = true, tests: String? = nil, rounds: Int = 3, guardDir: String? = nil) -> PairState {
        var s = PairState(id: "p1", config: PairConfig(goal: "Export estimates as PDF", root: "/repo", approvePlan: approve,
                                                      maxRounds: rounds, testCommand: tests, pathGuard: guardDir), now: Date())
        s.branch = "pair/estimate-pdf"
        s.worktree = "/repo-pair-estimate-pdf"
        s.baseSHA = "base0000"
        return s
    }

    private func verdict(_ v: String, sha: String? = nil, findings: String = "[]") -> String {
        "Looks fine overall.\n\n```json\n{\"verdict\": \"\(v)\"\(sha.map { ", \"sha\": \"\($0)\"" } ?? ""), \"findings\": \(findings)}\n```"
    }

    private func finished(_ a: AgentKind, _ reply: String, plan: String? = nil) -> PairInput {
        .turnFinished(agent: a, reply: reply, plan: plan, failed: false, interrupted: false)
    }

    private func sentTo(_ actions: [PairAction]) -> (AgentKind, PairPhase)? {
        for a in actions { if case .send(let agent, _, let phase) = a { return (agent, phase) } }
        return nil
    }

    func testHappyPathWithApproval() {
        var s = pair(tests: "pnpm test")
        XCTAssertEqual(sentTo(PairEngine.step(&s, .begin))?.0, .claude)
        XCTAssertEqual(s.phase, .plan)

        let a1 = PairEngine.step(&s, finished(.claude, "ignored", plan: "1. Add route\n2. Add button"))
        XCTAssertEqual(s.plan, "1. Add route\n2. Add button", "a plan from ExitPlanMode wins over the reply text")
        XCTAssertEqual(sentTo(a1)?.0, .codex)
        XCTAssertEqual(s.phase, .reviewPlan)

        XCTAssertTrue(PairEngine.step(&s, finished(.codex, verdict("approve"))).isEmpty)
        XCTAssertEqual(s.status, .waitingOnYou)
        XCTAssertEqual(s.phase, .approvePlan)

        let a3 = PairEngine.step(&s, .approvePlan(notes: "Keep the filename as the job name"))
        XCTAssertEqual(sentTo(a3)?.1, .build)
        XCTAssertTrue(s.plan!.contains("job name"))

        XCTAssertEqual(PairEngine.step(&s, finished(.claude, "Built it.")), [.commit(message: "pair: build estimate-pdf")])
        XCTAssertEqual(PairEngine.step(&s, .committed(sha: "abc12345ff", files: ["src/a.ts"])), [.runTests])
        XCTAssertEqual(PairEngine.step(&s, .tests(passed: true, output: "ok")), [.review])
        XCTAssertEqual(s.round, 1)
        XCTAssertEqual(s.phase, .review)

        XCTAssertTrue(PairEngine.step(&s, finished(.codex, verdict("approve", sha: "abc12345"))).isEmpty)
        XCTAssertEqual(s.status, .done)
        XCTAssertEqual(s.phase, .done)
    }

    func testPlanChangesGoBackToThePlanner() {
        var s = pair(approve: false)
        _ = PairEngine.step(&s, .begin)
        _ = PairEngine.step(&s, finished(.claude, "Plan v1"))
        let a = PairEngine.step(&s, finished(.codex, verdict("changes", findings: #"[{"issue": "Reuse estimateTotals()", "severity": "blocker"}]"#)))
        XCTAssertEqual(s.phase, .revisePlan)
        guard case .send(.claude, let text, .revisePlan)? = a.first else { return XCTFail("revise goes to the planner") }
        XCTAssertTrue(text.contains("Reuse estimateTotals()"))
        // Without plan approval, a revised plan goes straight to the builder.
        XCTAssertEqual(sentTo(PairEngine.step(&s, finished(.claude, "Plan v2")))?.1, .build)
        XCTAssertEqual(s.plan, "Plan v2")
    }

    func testFailingTestsGoToFixThenStopOnTheSecondFailure() {
        var s = pair(approve: false, tests: "swift test")
        _ = PairEngine.step(&s, .begin)
        _ = PairEngine.step(&s, finished(.claude, "Plan"))
        _ = PairEngine.step(&s, finished(.codex, verdict("approve")))
        _ = PairEngine.step(&s, finished(.claude, "Built"))
        _ = PairEngine.step(&s, .committed(sha: "1111", files: ["a.swift"]))
        let fix = PairEngine.step(&s, .tests(passed: false, output: "XCTAssertEqual failed"))
        XCTAssertEqual(sentTo(fix)?.1, .fix)
        XCTAssertTrue(s.fixNotes!.contains("XCTAssertEqual failed"))
        _ = PairEngine.step(&s, finished(.claude, "Fixed"))
        _ = PairEngine.step(&s, .committed(sha: "2222", files: ["a.swift"]))
        XCTAssertTrue(PairEngine.step(&s, .tests(passed: false, output: "still failing")).isEmpty)
        XCTAssertEqual(s.status, .waitingOnYou)
        XCTAssertEqual(s.reason, "Tests failed twice in a row.")
    }

    func testRoundLimitWaitsForYou() {
        var s = pair(approve: false, rounds: 1)
        _ = PairEngine.step(&s, .begin)
        _ = PairEngine.step(&s, finished(.claude, "Plan"))
        _ = PairEngine.step(&s, finished(.codex, verdict("approve")))
        _ = PairEngine.step(&s, finished(.claude, "Built"))
        XCTAssertEqual(PairEngine.step(&s, .committed(sha: "aaaa", files: ["x"])), [.review])
        XCTAssertTrue(PairEngine.step(&s, finished(.codex, verdict("changes", sha: "aaaa"))).isEmpty)
        XCTAssertEqual(s.status, .waitingOnYou)
        XCTAssertTrue(s.reason!.contains("Round 1 of 1"))
    }

    func testMissingOrStaleVerdictIsNeverApproval() {
        var s = pair(approve: false)
        _ = PairEngine.step(&s, .begin)
        _ = PairEngine.step(&s, finished(.claude, "Plan"))
        _ = PairEngine.step(&s, finished(.codex, verdict("approve")))
        _ = PairEngine.step(&s, finished(.claude, "Built"))
        _ = PairEngine.step(&s, .committed(sha: "feedbeef", files: ["x"]))
        // A verdict about another commit asks again rather than approving.
        let retry = PairEngine.step(&s, finished(.codex, verdict("approve", sha: "0ldc0mm1")))
        guard case .send(.codex, let text, .review)? = retry.first else { return XCTFail("asks for the verdict again") }
        XCTAssertTrue(text.contains("feedbeef"))
        XCTAssertEqual(s.status, .running)
        // Prose with no block, a second time: the pair waits.
        XCTAssertTrue(PairEngine.step(&s, finished(.codex, "LGTM!")).isEmpty)
        XCTAssertEqual(s.status, .waitingOnYou)
        XCTAssertNotEqual(s.phase, .done)
    }

    func testPathGuardStopsChangesOutsideTheFolder() {
        var s = pair(approve: false, guardDir: "src")
        _ = PairEngine.step(&s, .begin)
        _ = PairEngine.step(&s, finished(.claude, "Plan"))
        _ = PairEngine.step(&s, finished(.codex, verdict("approve")))
        _ = PairEngine.step(&s, finished(.claude, "Built"))
        XCTAssertTrue(PairEngine.step(&s, .committed(sha: "1", files: ["src/a.ts", "package.json"])).isEmpty)
        XCTAssertEqual(s.status, .waitingOnYou)
        XCTAssertTrue(s.reason!.contains("package.json"))
    }

    func testPauseTakesEffectAtTheNextHandoffAndResumeContinues() {
        var s = pair(approve: false)
        _ = PairEngine.step(&s, .begin)
        _ = PairEngine.step(&s, .pause)
        XCTAssertEqual(s.status, .running, "the running turn finishes first")
        XCTAssertTrue(PairEngine.step(&s, finished(.claude, "Plan")).isEmpty)
        XCTAssertEqual(s.status, .paused)
        XCTAssertEqual(s.phase, .reviewPlan)
        XCTAssertEqual(sentTo(PairEngine.step(&s, .resume))?.1, .reviewPlan)
    }

    func testStopInterruptsAndIgnoresLateTurns() {
        var s = pair()
        _ = PairEngine.step(&s, .begin)
        XCTAssertEqual(PairEngine.step(&s, .stop), [.interruptAll])
        XCTAssertTrue(PairEngine.step(&s, finished(.claude, "Plan")).isEmpty)
        XCTAssertEqual(s.status, .stopped)
        // Keep going restarts at Plan with a new goal.
        XCTAssertEqual(sentTo(PairEngine.step(&s, .keepGoing(goal: "Name the PDF after the job")))?.1, .plan)
        XCTAssertEqual(s.config.goal, "Name the PDF after the job")
    }

    func testParsesVerdicts() {
        XCTAssertEqual(PairEngine.parseVerdict(verdict("approve"))?.approved, true)
        XCTAssertEqual(PairEngine.parseVerdict("text {\"verdict\": \"changes\", \"findings\": []} done")?.approved, false)
        XCTAssertNil(PairEngine.parseVerdict("```json\n{\"verdict\": \"maybe\"}\n```"))
        XCTAssertNil(PairEngine.parseVerdict("I approve."))
        let two = verdict("changes") + "\n\nActually:\n" + verdict("approve")
        XCTAssertEqual(PairEngine.parseVerdict(two)?.approved, true, "the last block counts")
    }
}
