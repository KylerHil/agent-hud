import Foundation

/// What a pair allows the agent holding (or not holding) the turn to do with a tool.
public enum ToolPolicy: Sendable {
    /// Ask the user, as usual.
    case ask
    case allow
    case deny(String)
}

/// The broker side of a driver: everything here is called on the broker's queue.
public protocol AgentDriverHost: AnyObject {
    func driverChanged(_ session: ManagedSession)
    /// A turn ended. `reply` is the agent's last message; `plan` is a plan Claude handed in through ExitPlanMode.
    func driverTurnFinished(_ key: String, reply: String?, plan: String?, failed: Bool, interrupted: Bool)
    func driverExited(_ key: String, error: String?)
    func driverPolicy(_ key: String, tool: String, input: [String: Any]) -> ToolPolicy
}

/// Per-turn limits a pair puts on an agent.
public struct TurnLimits: Sendable {
    public var readOnly: Bool
    /// Codex approval policy for the turn: "never", "on-request".
    public var approval: String?
    public init(readOnly: Bool, approval: String? = nil) { self.readOnly = readOnly; self.approval = approval }
}

public protocol AgentDriver: AnyObject {
    var session: ManagedSession { get }
    func start() throws
    func send(_ text: String, id: String, steer: Bool, limits: TurnLimits?)
    func interrupt()
    func answer(requestId: String, decision: String, answers: [String: [String]]?, message: String?)
    func setPermissionMode(_ mode: String)
    func stop()
}

// MARK: - Claude

/// One `claude -p` process in stream-json mode (docs/Coordinator-Plan.md §10.1).
public final class ClaudeDriver: AgentDriver {
    public private(set) var session: ManagedSession
    private let options: StartOptions
    private let queue: DispatchQueue
    private weak var host: AgentDriverHost?
    private var process: AgentProcess?
    /// Inputs of outstanding can_use_tool requests, to echo back on allow.
    private var toolInputs: [String: [String: Any]] = [:]
    private var capturedPlan: String?
    private var lastAssistantText: String?
    private var interrupting = false
    private var stopping = false
    private var queued: [(text: String, id: String)] = []

    public init(key: String, options: StartOptions, queue: DispatchQueue, host: AgentDriverHost) {
        self.options = options
        self.queue = queue
        self.host = host
        session = ManagedSession(id: key, agent: .claude, cwd: options.cwd, status: .starting,
                                 capabilities: ManagedSession.capabilities(for: .claude), startedAt: Date())
        session.permissionMode = options.permissionMode
        session.model = options.model
        session.title = options.title
        session.pairID = options.pairID
        if let r = options.resume, !options.fork { session.sessionId = r }
    }

    static func arguments(_ o: StartOptions) -> [String] {
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--permission-prompts", "host", "--permission-prompt-tool", "stdio", "--replay-user-messages"]
        if let r = o.resume {
            args += ["--resume", r]
            if o.fork { args.append("--fork-session") }
        }
        if let m = o.permissionMode, !m.isEmpty, m != "default" { args += ["--permission-mode", m] }
        if let m = o.model, !m.isEmpty { args += ["--model", m] }
        return args
    }

    public func start() throws {
        guard let exe = AgentBinaries.claude() else { throw DriverError.missing("claude") }
        var env = AgentBinaries.environment
        env["AGENTHUD_MANAGED"] = "1"
        let p = AgentProcess(executable: exe, arguments: Self.arguments(options), cwd: options.cwd, environment: env, queue: queue)
        p.onLine = { [weak self] obj, _ in self?.handle(obj) }
        p.onExit = { [weak self] status, tail in self?.exited(status, tail) }
        process = p
        try p.start()
        session.pid = p.pid
        p.write(["type": "control_request", "request_id": "init-" + UUID().uuidString, "request": ["subtype": "initialize"]])
        if let prompt = options.prompt, !prompt.isEmpty { send(prompt, id: UUID().uuidString, steer: false, limits: nil) }
        changed()
    }

    public func send(_ text: String, id: String, steer: Bool, limits: TurnLimits?) {
        if [.busy, .waiting].contains(session.status) {
            queued.append((text, id))
            appendOutbox(OutboxMessage(id: id, text: text, state: .queued, at: Date()))
            changed()
            return
        }
        forward(text, id: id)
    }

    private func forward(_ text: String, id: String) {
        var msg = OutboxMessage(id: id, text: text, state: .queued, at: Date())
        if process?.write(["type": "user", "message": ["role": "user", "content": text]]) == true {
            msg.state = .forwarded
            session.status = .busy
            session.error = nil
            session.turnStartedAt = Date()
            session.currentDetail = "Waiting for Claude output"
        } else {
            msg.state = .failed
            msg.error = "The Claude process isn't running."
        }
        if let i = session.outbox.firstIndex(where: { $0.id == id }) { session.outbox[i] = msg } else { appendOutbox(msg) }
        changed()
    }

    public func interrupt() {
        interrupting = true
        process?.write(["type": "control_request", "request_id": "int-" + UUID().uuidString, "request": ["subtype": "interrupt"]])
    }

    public func setPermissionMode(_ mode: String) {
        guard session.permissionMode != mode else { return }
        process?.write(["type": "control_request", "request_id": "mode-" + UUID().uuidString,
                        "request": ["subtype": "set_permission_mode", "mode": mode]])
        session.permissionMode = mode
        changed()
    }

    public func answer(requestId: String, decision: String, answers: [String: [String]]?, message: String?) {
        guard let input = toolInputs.removeValue(forKey: requestId) else { return }
        let request = session.pending.first { $0.id == requestId }
        session.pending.removeAll { $0.id == requestId }
        var response: [String: Any]
        if decision == "deny" {
            response = ["behavior": "deny", "message": message ?? "The user declined this from Agent HUD."]
        } else {
            var updated = input
            if request?.kind == .question, let answers {
                // AskUserQuestion takes the chosen labels keyed by question text.
                var byQuestion: [String: String] = [:]
                for q in request?.questions ?? [] { if let a = answers[q.id] { byQuestion[q.question] = a.joined(separator: ", ") } }
                updated["answers"] = byQuestion
            }
            response = ["behavior": "allow", "updatedInput": updated]
            if decision == "allowSession", let tool = request?.tool {
                response["updatedPermissions"] = [["type": "addRules", "rules": [["toolName": tool]],
                                                   "behavior": "allow", "destination": "session"]]
            }
        }
        process?.write(["type": "control_response",
                        "response": ["subtype": "success", "request_id": requestId, "response": response]])
        if session.pending.isEmpty, session.status == .waiting { session.status = .busy }
        changed()
    }

    public func stop() {
        stopping = true
        process?.closeInput()
        process?.terminate()
    }

    // MARK: Output

    private func handle(_ o: [String: Any]) {
        session.lastActivity = Date()
        switch o["type"] as? String {
        case "system":
            if o["subtype"] as? String == "init" {
                if let sid = o["session_id"] as? String, session.sessionId != sid {
                    session.sessionId = sid
                    session.transcriptPath = Self.transcriptPath(cwd: o["cwd"] as? String ?? options.cwd, sessionId: sid)
                }
                if let m = o["model"] as? String { session.model = m }
                if let m = o["permissionMode"] as? String { session.permissionMode = m }
                if session.status == .starting { session.status = .idle }
            }
        case "user":
            if o["isReplay"] as? Bool == true {
                let text = Self.text(o["message"])
                if let i = session.outbox.firstIndex(where: { $0.state == .forwarded && (text == nil || $0.text == text) }) {
                    session.outbox[i].state = .observed
                }
                session.status = session.pending.isEmpty ? .busy : .waiting
                capturedPlan = nil
                lastAssistantText = nil
            }
        case "assistant":
            session.currentDetail = "Claude is responding"
            if let m = o["message"] as? [String: Any], let blocks = m["content"] as? [[String: Any]],
               let tool = blocks.last(where: { $0["type"] as? String == "tool_use" }), let name = tool["name"] as? String {
                session.currentDetail = name + (ChatTranscript.toolDetail(name: name, input: tool["input"] as? [String: Any] ?? [:]).map { ": " + $0 } ?? "")
            }
            if session.status != .waiting { session.status = .busy }
            if let t = Self.text(o["message"]), !t.isEmpty { lastAssistantText = t }
        case "result":
            let interrupted = o["subtype"] as? String == "error_during_execution" && interrupting
            let failed = (o["is_error"] as? Bool == true) && !interrupted
            let reply = o["result"] as? String ?? lastAssistantText
            session.lastTurnStatus = failed ? "failed" : interrupted ? "interrupted" : "completed"
            session.lastTurnDuration = session.turnStartedAt.map { Date().timeIntervalSince($0) }
            session.turnStartedAt = nil
            session.currentDetail = nil
            session.turns += 1
            session.lastReply = reply
            session.error = failed ? (reply ?? (o["subtype"] as? String)) : nil
            session.pending = []
            toolInputs = [:]
            session.status = .idle
            interrupting = false
            let plan = capturedPlan
            capturedPlan = nil
            changed()
            host?.driverTurnFinished(session.id, reply: reply, plan: plan, failed: failed, interrupted: interrupted)
            if !queued.isEmpty && !stopping {
                let next = queued.removeFirst()
                forward(next.text, id: next.id)
            }
            return
        case "control_request":
            guard let id = o["request_id"] as? String, let req = o["request"] as? [String: Any],
                  req["subtype"] as? String == "can_use_tool" else { break }
            let tool = req["tool_name"] as? String ?? "Tool"
            let input = req["input"] as? [String: Any] ?? [:]
            if tool == "ExitPlanMode", let plan = input["plan"] as? String { capturedPlan = plan }
            switch host?.driverPolicy(session.id, tool: tool, input: input) ?? .ask {
            case .allow:
                process?.write(["type": "control_response", "response": ["subtype": "success", "request_id": id,
                                "response": ["behavior": "allow", "updatedInput": input]]])
            case .deny(let message):
                process?.write(["type": "control_response", "response": ["subtype": "success", "request_id": id,
                                "response": ["behavior": "deny", "message": message]]])
            case .ask:
                toolInputs[id] = input
                session.pending.append(Self.pending(id: id, tool: tool, input: input))
                session.status = .waiting
            }
        case "control_cancel_request":
            if let id = o["request_id"] as? String {
                toolInputs[id] = nil
                session.pending.removeAll { $0.id == id }
                if session.pending.isEmpty, session.status == .waiting { session.status = .busy }
            }
        default:
            break
        }
        changed()
    }

    private func exited(_ status: Int32, _ tail: String) {
        session.pid = nil
        session.pending = []
        for i in session.outbox.indices where [.queued, .forwarded].contains(session.outbox[i].state) {
            session.outbox[i].state = .failed
            session.outbox[i].error = "Claude stopped before delivery was confirmed. Review the transcript before retrying."
        }
        queued = []
        let clean = stopping || status == 0 || status == 15
        session.status = clean ? .exited : .failed
        if !clean { session.error = tail.isEmpty ? "claude exited with status \(status)" : tail }
        changed()
        host?.driverExited(session.id, error: session.error)
    }

    private func appendOutbox(_ m: OutboxMessage) {
        session.outbox.append(m)
        if session.outbox.count > 30 { session.outbox.removeFirst(session.outbox.count - 30) }
    }

    private func changed() { host?.driverChanged(session) }

    // MARK: Helpers

    static func text(_ message: Any?) -> String? {
        guard let m = message as? [String: Any] else { return nil }
        if let s = m["content"] as? String { return s }
        let blocks = m["content"] as? [[String: Any]] ?? []
        let t = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        return t.isEmpty ? nil : t
    }

    /// Where Claude keeps a session's transcript: the cwd with every non-alphanumeric character as "-".
    public static func transcriptPath(cwd: String, sessionId: String) -> String {
        let dir = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return Paths.claudeProjects.appendingPathComponent(dir).appendingPathComponent(sessionId + ".jsonl").path
    }

    static func pending(id: String, tool: String, input: [String: Any]) -> PendingRequest {
        if tool == "AskUserQuestion", let raw = input["questions"] as? [[String: Any]] {
            let qs = raw.enumerated().map { i, q in
                PendingQuestion(id: String(i), header: q["header"] as? String, question: q["question"] as? String ?? "",
                                options: (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String },
                                multiSelect: q["multiSelect"] as? Bool ?? false)
            }
            return PendingRequest(id: id, kind: .question, tool: tool, summary: qs.first?.question ?? "Question",
                                  questions: qs, since: Date())
        }
        let summary = ChatTranscript.toolDetail(name: tool, input: input) ?? tool
        var detail: String?
        if let c = input["command"] as? String { detail = c }
        else if tool == "ExitPlanMode", let p = input["plan"] as? String { detail = p }
        else if let old = input["old_string"] as? String, let new = input["new_string"] as? String {
            detail = "− " + old.prefix(400) + "\n+ " + new.prefix(400)
        } else if let content = input["content"] as? String { detail = String(content.prefix(800)) }
        return PendingRequest(id: id, kind: .permission, tool: tool, summary: summary, detail: detail, since: Date())
    }
}

public enum DriverError: Error, LocalizedError {
    case missing(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let name): "Couldn't find `\(name)`. Install it, or make sure your login shell's PATH finds it."
        case .failed(let s): s
        }
    }
}
