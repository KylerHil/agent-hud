import Foundation

/// What the broker must do next for a pair.
public enum PairAction: Equatable, Sendable {
    /// Send `text` to the agent, with the limits for `phase` (read-only unless the phase writes).
    case send(agent: AgentKind, text: String, phase: PairPhase)
    /// Commit everything in the worktree; answer with `.committed`.
    case commit(message: String)
    /// Run the test command; answer with `.tests`.
    case runTests
    /// Build the review prompt from the diff and send it to the reviewer.
    case review
    /// Stop whatever turn is running.
    case interruptAll
}

public enum PairInput: Sendable {
    case begin
    case turnFinished(agent: AgentKind, reply: String?, plan: String?, failed: Bool, interrupted: Bool)
    /// `sha` nil: there was nothing to commit.
    case committed(sha: String?, files: [String])
    case tests(passed: Bool, output: String)
    /// A read-only agent changed files anyway; they were discarded.
    case discarded([String])
    case approvePlan(notes: String?)
    case keepGoing(goal: String)
    case pause, resume, stop
}

/// The pair's turn-taking, as a pure state machine: the broker feeds it what happened and carries out the
/// actions it returns. Plan → review plan → (revise) → you approve → build → tests → review → fix … → done.
public enum PairEngine {
    public static func step(_ s: inout PairState, _ input: PairInput, now: Date = Date()) -> [PairAction] {
        s.updatedAt = now
        switch input {
        case .begin:
            s.phase = .plan
            s.status = .running
            note(&s, .note, nil, "Pair started on \(s.branch ?? "the current checkout").", now)
            return dispatch(&s, now: now)

        case .turnFinished(let agent, let reply, let plan, let failed, let interrupted):
            guard s.status == .running, agent == s.agent(for: s.phase) else { return [] }
            if interrupted {
                return wait(&s, "\(agent.displayName)'s turn was interrupted.", now)
            }
            if failed {
                return wait(&s, "\(agent.displayName) hit an error: \(reply ?? "no details")", now)
            }
            note(&s, .reply, agent, reply ?? "", now)
            return finished(&s, agent: agent, reply: reply ?? "", plan: plan, now: now)

        case .committed(let sha, let files):
            guard s.status == .running, s.phase.writes else { return [] }
            guard let sha else {
                return wait(&s, "\(s.config.builder.displayName) finished without changing any files.", now)
            }
            s.buildSHA = sha
            note(&s, .commit, s.config.builder, "Committed \(short(sha)): \(files.count) file\(files.count == 1 ? "" : "s") changed.", now)
            if let guardDir = s.config.pathGuard?.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")), !guardDir.isEmpty {
                let outside = files.filter { !$0.hasPrefix(guardDir + "/") }
                if !outside.isEmpty {
                    return wait(&s, "Changes landed outside \(guardDir)/: \(outside.prefix(5).joined(separator: ", ")).", now)
                }
            }
            if s.config.testCommand?.isEmpty == false { return [.runTests] }
            return startReview(&s, now: now)

        case .tests(let passed, let output):
            guard s.status == .running, s.phase.writes else { return [] }
            s.testsPassed = passed
            note(&s, .tests, nil, passed ? "Tests passed: \(s.config.testCommand ?? "")"
                                         : "Tests failed: \(s.config.testCommand ?? "")\n" + tail(output, lines: 30), now)
            if passed {
                s.testFailuresInARow = 0
                return startReview(&s, now: now)
            }
            s.testFailuresInARow += 1
            if s.testFailuresInARow >= 2 { return wait(&s, "Tests failed twice in a row.", now) }
            s.fixNotes = "The tests fail after your change. `\(s.config.testCommand ?? "")` printed:\n\n```\n\(tail(output, lines: 60))\n```"
            s.phase = .fix
            return dispatch(&s, now: now)

        case .discarded(let files):
            note(&s, .warning, nil, "The reviewer changed files in a read-only turn; those changes were discarded: "
                 + files.prefix(8).joined(separator: ", "), now)
            return []

        case .approvePlan(let notes):
            guard s.phase == .approvePlan else { return [] }
            if let notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                s.plan = (s.plan ?? "") + "\n\nNotes from the user:\n" + notes
            }
            note(&s, .you, nil, "You approved the plan" + (notes?.isEmpty == false ? " with notes." : "."), now)
            s.status = .running
            s.reason = nil
            s.phase = .build
            return dispatch(&s, now: now)

        case .keepGoing(let goal):
            guard [.done, .waitingOnYou, .stopped, .paused].contains(s.status) else { return [] }
            s.config.goal = goal
            s.baseSHA = s.buildSHA ?? s.baseSHA
            s.plan = nil; s.fixNotes = nil; s.lastVerdict = nil; s.testsPassed = nil
            s.round = 0; s.testFailuresInARow = 0; s.verdictRetries = 0
            s.status = .running
            s.reason = nil
            s.phase = .plan
            note(&s, .you, nil, "New goal: \(goal)", now)
            return dispatch(&s, now: now)

        case .pause:
            guard s.status == .running else { return [] }
            s.pauseRequested = true
            note(&s, .you, nil, "Pause requested: the pair stops after this turn.", now)
            return []

        case .resume:
            guard s.status == .paused || s.status == .waitingOnYou else { return [] }
            s.status = .running
            s.reason = nil
            s.pauseRequested = false
            note(&s, .you, nil, "Resumed at \(s.phase.label.lowercased()).", now)
            return dispatch(&s, now: now)

        case .stop:
            guard s.status != .done && s.status != .stopped else { return [] }
            s.status = .stopped
            s.reason = "Stopped by you."
            note(&s, .you, nil, "Stopped.", now)
            return [.interruptAll]
        }
    }

    /// Starts the current phase.
    static func dispatch(_ s: inout PairState, now: Date) -> [PairAction] {
        if s.pauseRequested {
            s.pauseRequested = false
            s.status = .paused
            s.reason = "Paused before \(s.phase.label.lowercased())."
            return []
        }
        switch s.phase {
        case .approvePlan:
            s.status = .waitingOnYou
            s.reason = "The plan is ready for your approval."
            return []
        case .done:
            s.status = .done
            s.reason = nil
            return []
        case .review:
            return [.review]
        default:
            guard let agent = s.agent(for: s.phase), let text = prompt(s) else { return [] }
            note(&s, .handoff, agent, "\(s.phase.label)\(s.round > 0 && s.phase == .fix ? " · round \(s.round)" : "")", now)
            return [.send(agent: agent, text: text, phase: s.phase)]
        }
    }

    private static func finished(_ s: inout PairState, agent: AgentKind, reply: String, plan: String?, now: Date) -> [PairAction] {
        switch s.phase {
        case .plan, .revisePlan:
            let text = (plan ?? reply).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return wait(&s, "\(agent.displayName) didn't return a plan.", now) }
            s.plan = text
            if s.phase == .plan {
                s.phase = .reviewPlan
                s.verdictRetries = 0
            } else {
                s.phase = s.config.approvePlan ? .approvePlan : .build
            }
            return dispatch(&s, now: now)

        case .reviewPlan:
            guard let v = parseVerdict(reply) else { return askForVerdict(&s, now: now) }
            s.lastVerdict = v
            note(&s, .verdict, agent, verdictLine(v), now)
            if v.approved {
                s.phase = s.config.approvePlan ? .approvePlan : .build
            } else {
                s.fixNotes = findingsText(v, reply: reply)
                s.phase = .revisePlan
            }
            return dispatch(&s, now: now)

        case .build, .fix:
            return [.commit(message: s.phase == .build ? "pair: build \(s.slug)" : "pair: fix round \(s.round) \(s.slug)")]

        case .review:
            guard let v = parseVerdict(reply), matches(v.sha, s.buildSHA) else { return askForVerdict(&s, now: now) }
            s.lastVerdict = v
            s.verdictRetries = 0
            note(&s, .verdict, agent, verdictLine(v), now)
            if v.approved {
                s.phase = .done
                note(&s, .note, nil, "\(agent.displayName) approved \(short(s.buildSHA ?? "")) after \(s.round) round\(s.round == 1 ? "" : "s").", now)
                return dispatch(&s, now: now)
            }
            if s.round >= s.config.maxRounds {
                return wait(&s, "Round \(s.round) of \(s.config.maxRounds) ended without approval.", now)
            }
            s.fixNotes = findingsText(v, reply: reply)
            s.phase = .fix
            return dispatch(&s, now: now)

        case .approvePlan, .done:
            return []
        }
    }

    private static func startReview(_ s: inout PairState, now: Date) -> [PairAction] {
        s.round += 1
        s.verdictRetries = 0
        s.phase = .review
        note(&s, .handoff, s.config.reviewer, "Review \(short(s.baseSHA ?? ""))..\(short(s.buildSHA ?? "")) · round \(s.round)", now)
        return dispatch(&s, now: now)
    }

    /// A reviewer with no usable verdict gets one reminder; after that the pair waits for you.
    private static func askForVerdict(_ s: inout PairState, now: Date) -> [PairAction] {
        guard s.verdictRetries < 1 else {
            return wait(&s, "\(s.config.reviewer.displayName) didn't give a usable verdict.", now)
        }
        s.verdictRetries += 1
        let sha = s.phase == .review ? s.buildSHA.map(short) : nil
        return [.send(agent: s.config.reviewer, text: """
            Your reply didn't end with a usable verdict block\(sha.map { " for commit \($0)" } ?? ""). Reply with only the block:

            ```json
            {"verdict": "approve", \(sha.map { "\"sha\": \"\($0)\", " } ?? "")"findings": []}
            ```
            Use "changes" instead of "approve" if anything must change, and list each finding.
            """, phase: s.phase)]
    }

    private static func wait(_ s: inout PairState, _ reason: String, _ now: Date) -> [PairAction] {
        s.status = .waitingOnYou
        s.reason = reason
        note(&s, .warning, nil, reason, now)
        return []
    }

    private static func note(_ s: inout PairState, _ kind: PairEvent.Kind, _ agent: AgentKind?, _ text: String, _ now: Date) {
        s.events.append(PairEvent(at: now, kind: kind, agent: agent, phase: s.phase, round: s.round, text: text))
        if s.events.count > 300 { s.events.removeFirst(s.events.count - 300) }
    }

    // MARK: Prompts

    static func prompt(_ s: PairState) -> String? {
        let c = s.config
        let place = "Work in \(s.workDir)" + (s.branch.map { " (git branch \($0))" } ?? "") + "."
        switch s.phase {
        case .plan:
            return """
                You're the planner in a two-agent pair run by Agent HUD. \(c.reviewer.displayName) reviews your plan\
                \(c.approvePlan ? ", the user approves it," : ",") and then \(c.builder.displayName) builds it.

                Goal:
                \(c.goal)

                \(place) Read whatever code you need, but don't change any files. Write a concrete, numbered plan: \
                which files change, what changes in each, and how to test it. Keep it under 60 lines and end with the plan.
                """
        case .reviewPlan:
            return """
                You're the reviewer in a two-agent pair run by Agent HUD. \(c.planner.displayName) wrote the plan below. \
                Check that it's correct and complete, fits this codebase, and has no simpler route. \(place) Read the \
                code as needed, but don't change any files.

                Goal:
                \(c.goal)

                Plan:
                <plan>
                \(s.plan ?? "")
                </plan>

                \(verdictInstructions(sha: nil))
                """
        case .revisePlan:
            return """
                \(c.reviewer.displayName) reviewed your plan and asked for changes:

                \(s.fixNotes ?? "")

                Revise the plan. Reply with the full revised plan. Don't change any files.
                """
        case .build:
            return """
                You're the builder in a two-agent pair run by Agent HUD. Build this plan. \(place)

                Goal:
                \(c.goal)

                Plan:
                <plan>
                \(s.plan ?? "")
                </plan>

                Make the changes and run the relevant tests\(c.testCommand.map { " (`\($0)` runs after your turn)" } ?? ""). \
                Don't commit; Agent HUD commits your work when your turn ends, and \(c.reviewer.displayName) reviews it. \
                End with a short summary of what you changed.
                """
        case .fix:
            return """
                \(s.fixNotes ?? "Address the review.")

                Fix this in \(s.workDir). Don't commit; Agent HUD commits when your turn ends and sends it back for review. \
                End with a short summary of what you changed.
                """
        case .review, .approvePlan, .done:
            return nil
        }
    }

    /// The diff review prompt; the broker supplies the diff.
    public static func reviewPrompt(_ s: PairState, stat: String, diff: String, truncated: Bool) -> String {
        let c = s.config
        let base = short(s.baseSHA ?? ""), head = short(s.buildSHA ?? "")
        let tests = c.testCommand.map { s.testsPassed == true ? "`\($0)` passes." : "`\($0)` hasn't passed." }
            ?? "No test command is set; check the tests yourself if it matters."
        return """
            You're the reviewer in a two-agent pair run by Agent HUD. \(c.builder.displayName) built the goal below. \
            Review the change from \(base) to \(head) (round \(s.round) of \(c.maxRounds)) in \(s.workDir). Read any \
            file you need, but don't change files: your turn is read-only.

            Goal:
            \(c.goal)

            \(tests)

            ```
            \(stat)
            ```

            ```diff
            \(diff)
            ```
            \(truncated ? "\nThe diff was cut at 60 KB. Run `git diff \(base)..\(head)` to read the rest.\n" : "")
            \(verdictInstructions(sha: head))
            """
    }

    static func verdictInstructions(sha: String?) -> String {
        """
        End your reply with a verdict block exactly like this:

        ```json
        {"verdict": "approve", \(sha.map { "\"sha\": \"\($0)\", " } ?? "")"findings": [{"file": "path", "line": 0, "issue": "what to change", "severity": "blocker"}]}
        ```
        Use "approve" when it's ready (nits allowed, with severity "nit"); use "changes" when something must change.
        """
    }

    // MARK: Verdicts

    /// The last ```json block (or bare object) with a "verdict" key.
    public static func parseVerdict(_ text: String) -> ReviewVerdict? {
        var candidates: [String] = []
        let fence = try! NSRegularExpression(pattern: "```(?:json)?\\s*(\\{[\\s\\S]*?\\})\\s*```")
        for m in fence.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let r = Range(m.range(at: 1), in: text) { candidates.append(String(text[r])) }
        }
        if candidates.isEmpty, let start = text.range(of: "{\"verdict\"", options: .backwards),
           let end = text.range(of: "}", options: .backwards), end.lowerBound > start.lowerBound {
            // Unfenced: from the last {"verdict" to the last }, widening to balance nested findings.
            candidates.append(String(text[start.lowerBound...end.lowerBound]))
        }
        for c in candidates.reversed() {
            guard let v = try? JSONDecoder().decode(ReviewVerdict.self, from: Data(c.utf8)) else { continue }
            let verdict = v.verdict.lowercased()
            guard verdict == "approve" || verdict == "changes" else { continue }
            return v
        }
        return nil
    }

    /// A verdict about another commit isn't a verdict about this one.
    static func matches(_ verdictSHA: String?, _ build: String?) -> Bool {
        guard let v = verdictSHA?.trimmingCharacters(in: .whitespaces), !v.isEmpty, let b = build else { return true }
        return b.hasPrefix(v) || v.hasPrefix(b)
    }

    static func findingsText(_ v: ReviewVerdict, reply: String) -> String {
        let summary = reply.components(separatedBy: "```").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let list = v.findings.map { f in
            "- " + [f.file.map { $0 + (f.line.map { ":\($0)" } ?? "") }, f.severity.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
                + (f.file == nil && f.severity == nil ? "" : ": ") + f.issue
        }.joined(separator: "\n")
        return [summary.isEmpty ? nil : summary, list.isEmpty ? nil : "Findings:\n" + list].compactMap { $0 }.joined(separator: "\n\n")
    }

    static func verdictLine(_ v: ReviewVerdict) -> String {
        let blockers = v.findings.filter { $0.severity?.lowercased() == "blocker" }.count
        let others = v.findings.count - blockers
        if v.approved { return "Approved" + (v.findings.isEmpty ? "." : " with \(v.findings.count) nit\(v.findings.count == 1 ? "" : "s").") }
        return "Changes requested: \(blockers) blocker\(blockers == 1 ? "" : "s")" + (others > 0 ? ", \(others) other." : ".")
    }

    public static func short(_ sha: String) -> String { String(sha.prefix(8)) }

    static func tail(_ text: String, lines: Int) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }
}
