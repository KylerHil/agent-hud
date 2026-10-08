import Foundation

/// One `codex app-server` over stdio, hosting every Codex thread the broker owns (docs/Coordinator-Plan.md §10.2).
public final class CodexServer {
    private let queue: DispatchQueue
    private var process: AgentProcess?
    private var nextID = 1
    private var waiting: [Int: ([String: Any]?, String?) -> Void] = [:]
    private var ready = false
    private var backlog: [() -> Void] = []
    /// Thread id → its driver.
    private var threads: [String: CodexDriver] = [:]
    public var onExit: ((String?) -> Void)?

    public init(queue: DispatchQueue) { self.queue = queue }

    public var isRunning: Bool { process?.isRunning == true }

    func ensureStarted() throws {
        if process?.isRunning == true { return }
        guard let exe = AgentBinaries.codex() else { throw DriverError.missing("codex") }
        var env = AgentBinaries.environment
        env["AGENTHUD_MANAGED"] = "1"
        let p = AgentProcess(executable: exe, arguments: ["app-server"], cwd: Paths.userHome.path, environment: env, queue: queue)
        p.onLine = { [weak self] obj, _ in self?.handle(obj) }
        p.onExit = { [weak self] status, tail in self?.exited(status, tail) }
        process = p
        ready = false
        try p.start()
        call("initialize", ["clientInfo": ["name": "agenthud", "title": "Agent HUD", "version": "2"]], force: true) { [weak self] _, error in
            guard let self else { return }
            if let error {
                let failedProcess = self.process; self.process = nil
                let pending = self.backlog; self.backlog = []
                self.ready = true
                pending.forEach { $0() }
                self.ready = false
                failedProcess?.terminate()
                self.onExit?(error)
                return
            }
            self.process?.write(["jsonrpc": "2.0", "method": "initialized"])
            self.ready = true
            let pending = self.backlog
            self.backlog = []
            pending.forEach { $0() }
        }
    }

    func register(_ thread: String, _ driver: CodexDriver) { threads[thread] = driver }
    func unregister(_ thread: String) { threads[thread] = nil }

    func call(_ method: String, _ params: [String: Any], force: Bool = false, _ done: @escaping ([String: Any]?, String?) -> Void) {
        guard ready || force else { backlog.append { [weak self] in self?.call(method, params, done) }; return }
        let id = nextID
        nextID += 1
        waiting[id] = done
        queue.asyncAfter(deadline: .now() + 60) { [weak self] in
            self?.waiting.removeValue(forKey: id)?(nil, "Codex didn't answer \(method) within 60 seconds. Check the agent connection and retry.")
        }
        if process?.write(["jsonrpc": "2.0", "id": id, "method": method, "params": params]) != true {
            waiting[id] = nil
            done(nil, "The Codex app-server isn't running.")
        }
    }

    func respond(_ id: Any, result: [String: Any]) {
        process?.write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    func respondError(_ id: Any, _ message: String) {
        process?.write(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": message]])
    }

    public func stop() { process?.terminate() }

    private func handle(_ o: [String: Any]) {
        let method = o["method"] as? String
        if method == nil, let id = o["id"] as? Int, let done = waiting.removeValue(forKey: id) {
            if let err = o["error"] as? [String: Any] { done(nil, err["message"] as? String ?? "Codex error") }
            else { done(o["result"] as? [String: Any] ?? [:], nil) }
            return
        }
        guard let method else { return }
        let params = o["params"] as? [String: Any] ?? [:]
        let thread = params["threadId"] as? String ?? (params["thread"] as? [String: Any])?["id"] as? String
        if let id = o["id"] {
            if let thread, let d = threads[thread] { d.serverRequest(id: id, method: method, params: params) }
            else if method.hasSuffix("requestApproval") { respond(id, result: ["decision": "decline"]) }
            else { respondError(id, "Agent HUD doesn't handle \(method).") }
            return
        }
        if let thread, let d = threads[thread] { d.notification(method, params) }
        else if method == "serverRequest/resolved" { threads.values.forEach { $0.notification(method, params) } }
    }

    private func exited(_ status: Int32, _ tail: String) {
        ready = false
        let pending = waiting; waiting = [:]
        for done in pending.values { done(nil, "The Codex app-server stopped.") }
        let queued = backlog; backlog = []
        ready = true
        queued.forEach { $0() }
        ready = false
        let error = status == 0 || status == 15 ? nil : (tail.isEmpty ? "codex app-server exited with status \(status)" : tail)
        let drivers = Array(threads.values)
        threads = [:]
        for d in drivers { d.serverExited(error) }
        onExit?(error)
    }
}

/// One Codex thread on the shared app-server.
public final class CodexDriver: AgentDriver {
    public private(set) var session: ManagedSession
    private let options: StartOptions
    private let server: CodexServer
    private weak var host: AgentDriverHost?
    private var currentTurn: String?
    private var requests: [String: (rpc: Any, method: String, params: [String: Any])] = [:]
    private var lastText: String?
    private var interrupting = false
    private var stopped = false
    private var stopRequestInFlight = false
    private var queued: [(text: String, id: String, limits: TurnLimits?)] = []

    public init(key: String, options: StartOptions, server: CodexServer, host: AgentDriverHost) {
        self.options = options
        self.server = server
        self.host = host
        session = ManagedSession(id: key, agent: .codex, cwd: options.cwd, status: .starting,
                                 capabilities: ManagedSession.capabilities(for: .codex), startedAt: Date())
        session.permissionMode = options.permissionMode ?? "workspace-write"
        session.model = options.model
        session.title = options.title
        session.pairID = options.pairID
    }

    public func start() throws {
        try server.ensureStarted()
        var params: [String: Any] = ["cwd": options.cwd, "approvalPolicy": "on-request", "approvalsReviewer": "user",
                                     "sandbox": options.permissionMode ?? "workspace-write"]
        if let m = options.model, !m.isEmpty { params["model"] = m }
        let method: String
        if let r = options.resume {
            params["threadId"] = r
            method = options.fork ? "thread/fork" : "thread/resume"
            if !options.fork {
                session.sessionId = r
                server.register(r, self)
            }
        } else { method = "thread/start" }
        server.call(method, params) { [weak self] result, error in
            guard let self else { return }
            guard let thread = result?["thread"] as? [String: Any], let id = thread["id"] as? String else {
                self.session.status = .failed
                self.session.error = error ?? "Codex didn't start a thread."
                if let id = self.session.sessionId { self.server.unregister(id) }
                self.changed()
                self.host?.driverExited(self.session.id, error: self.session.error)
                return
            }
            guard !self.stopped else { self.finishStop(); return }
            self.session.sessionId = id
            self.session.transcriptPath = thread["path"] as? String
            if let m = result?["model"] as? String { self.session.model = m }
            self.session.status = .idle
            self.server.register(id, self)
            self.changed()
            if let p = self.options.prompt, !p.isEmpty { self.send(p, id: UUID().uuidString, steer: false, limits: nil) }
            self.drainQueue()
        }
        changed()
    }

    public func send(_ text: String, id: String, steer: Bool, limits: TurnLimits?) {
        guard !stopped else { return }
        if session.status == .starting || ([.busy, .waiting].contains(session.status) && !steer) {
            queued.append((text, id, limits))
            appendOutbox(OutboxMessage(id: id, text: text, state: .queued, at: Date()))
            changed()
            return
        }
        guard let thread = session.sessionId else {
            appendOutbox(OutboxMessage(id: id, text: text, state: .failed, at: Date(), error: "The thread hasn't started yet."))
            changed()
            return
        }
        let input: [[String: Any]] = [["type": "text", "text": text]]
        let steering = steer && currentTurn != nil && session.status != .idle
        appendOutbox(OutboxMessage(id: id, text: text, state: .forwarded, at: Date(), steer: steering))
        let done: ([String: Any]?, String?) -> Void = { [weak self] result, error in
            guard let self, let i = self.session.outbox.firstIndex(where: { $0.id == id }) else { return }
            if self.stopped {
                if let turn = (result?["turn"] as? [String: Any])?["id"] as? String { self.cancelForStop(turn) }
                else if error != nil { self.finishStop() }
                return
            }
            if let error {
                self.session.outbox[i].state = .failed
                self.session.outbox[i].error = error
                if !steering && self.currentTurn == nil {
                    self.session.status = .idle
                    self.session.error = error
                    self.session.turnStartedAt = nil
                    self.session.currentDetail = nil
                    self.host?.driverTurnFinished(self.session.id, reply: nil, plan: nil, failed: true, interrupted: false)
                }
            } else {
                self.session.outbox[i].state = .observed
                if let turn = (result?["turn"] as? [String: Any])?["id"] as? String { self.currentTurn = turn }
            }
            self.changed()
        }
        if steering, let turn = currentTurn {
            server.call("turn/steer", ["threadId": thread, "expectedTurnId": turn, "input": input, "clientUserMessageId": id], done)
        } else {
            var params: [String: Any] = ["threadId": thread, "input": input, "clientUserMessageId": id]
            let readOnly = limits?.readOnly ?? (session.permissionMode == "read-only")
            params["sandboxPolicy"] = readOnly ? ["type": "readOnly"] : ["type": "workspaceWrite", "writableRoots": [session.cwd], "networkAccess": false]
            if let a = limits?.approval { params["approvalPolicy"] = a }
            session.status = .busy
            session.error = nil
            session.turnStartedAt = Date()
            session.currentDetail = "Starting Codex turn"
            lastText = nil
            server.call("turn/start", params, done)
        }
        changed()
    }

    public func interrupt() {
        interrupting = true
        guard let thread = session.sessionId, let turn = currentTurn else { return }
        server.call("turn/interrupt", ["threadId": thread, "turnId": turn]) { [weak self] _, error in
            if let error { self?.session.error = error; self?.changed() }
        }
    }

    public func setPermissionMode(_ mode: String) {
        session.permissionMode = mode
        changed()
    }

    public func answer(requestId: String, decision: String, answers: [String: [String]]?, message: String?) {
        guard let r = requests.removeValue(forKey: requestId) else { return }
        session.pending.removeAll { $0.id == requestId }
        let allow = decision != "deny"
        switch r.method {
        case "item/tool/requestUserInput":
            var out: [String: Any] = [:]
            for (k, v) in answers ?? [:] { out[k] = ["answers": v] }
            server.respond(r.rpc, result: ["answers": out])
        case "item/permissions/requestApproval":
            server.respond(r.rpc, result: ["permissions": allow ? (r.params["permissions"] ?? [:]) : [:],
                                           "scope": decision == "allowSession" ? "session" : "turn"])
        case "mcpServer/elicitation/request":
            server.respond(r.rpc, result: ["action": allow ? "accept" : "decline", "content": [:]])
        default:
            server.respond(r.rpc, result: ["decision": allow ? (decision == "allowSession" ? "acceptForSession" : "accept") : "decline"])
        }
        if session.pending.isEmpty, session.status == .waiting { session.status = .busy }
        changed()
    }

    public func stop() {
        guard !stopped else { return }
        stopped = true
        queued = []
        for i in session.outbox.indices where session.outbox[i].state == .queued {
            session.outbox[i].state = .failed
            session.outbox[i].error = "The session was stopped before this message ran."
        }
        for r in requests.values { server.respondError(r.rpc, "The user stopped this session.") }
        requests = [:]
        session.pending = []
        if let turn = currentTurn { cancelForStop(turn) }
        else if session.status == .busy || session.status == .starting || session.status == .waiting {
            session.currentDetail = "Stopping · waiting for Codex confirmation"
            changed()
        } else { finishStop() }
    }

    private func cancelForStop(_ turn: String) {
        guard !stopRequestInFlight else { return }
        stopRequestInFlight = true
        guard let thread = session.sessionId else { return finishStop() }
        server.call("turn/interrupt", ["threadId": thread, "turnId": turn]) { [weak self] _, error in
            guard let self, self.session.status != .exited else { return }
            self.stopRequestInFlight = false
            if let error {
                self.stopped = false
                self.session.error = "Couldn't confirm the stop: " + error
                self.changed()
            } else { self.finishStop() }
        }
    }

    private func finishStop() {
        guard session.status != .exited else { return }
        if let t = session.sessionId { server.unregister(t) }
        session.status = .exited
        session.currentDetail = nil
        changed()
        host?.driverExited(session.id, error: nil)
    }

    // MARK: From the server

    func serverRequest(id: Any, method: String, params: [String: Any]) {
        let key = "rpc-" + UUID().uuidString
        let pending: PendingRequest
        switch method {
        case "item/commandExecution/requestApproval":
            let cmd = params["command"] as? String ?? (params["command"] as? [String])?.joined(separator: " ") ?? "a command"
            if case .deny(let m)? = host?.driverPolicy(session.id, tool: "Bash", input: ["command": cmd]) {
                server.respond(id, result: ["decision": "decline"]); _ = m; return
            }
            pending = PendingRequest(id: key, kind: .permission, tool: "Command", summary: String(cmd.prefix(160)),
                                     detail: [cmd, params["reason"] as? String].compactMap { $0 }.joined(separator: "\n\n"), since: Date())
        case "item/fileChange/requestApproval":
            if case .deny? = host?.driverPolicy(session.id, tool: "Edit", input: [:]) {
                server.respond(id, result: ["decision": "decline"]); return
            }
            pending = PendingRequest(id: key, kind: .permission, tool: "File change",
                                     summary: params["reason"] as? String ?? "Apply file changes",
                                     detail: (params["grantRoot"] as? String).map { "Write access to " + $0 }, since: Date())
        case "item/permissions/requestApproval":
            pending = PendingRequest(id: key, kind: .permission, tool: "Permissions",
                                     summary: params["reason"] as? String ?? "More sandbox access", since: Date())
        case "item/tool/requestUserInput":
            let qs = (params["questions"] as? [[String: Any]] ?? []).map { q in
                PendingQuestion(id: q["id"] as? String ?? UUID().uuidString, header: q["header"] as? String,
                                question: q["question"] as? String ?? "",
                                options: (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String },
                                multiSelect: false)
            }
            pending = PendingRequest(id: key, kind: .question, tool: "Question", summary: qs.first?.question ?? "Codex has a question",
                                     questions: qs, since: Date())
        case "mcpServer/elicitation/request":
            pending = PendingRequest(id: key, kind: .permission, tool: "MCP", summary: params["message"] as? String ?? "An MCP server asks for input",
                                     since: Date())
        default:
            server.respondError(id, "Agent HUD doesn't handle \(method).")
            return
        }
        requests[key] = (id, method, params)
        session.pending.append(pending)
        session.status = .waiting
        changed()
    }

    func notification(_ method: String, _ params: [String: Any]) {
        if stopped {
            if method == "turn/started", let turn = (params["turn"] as? [String: Any])?["id"] as? String { cancelForStop(turn) }
            else if method == "turn/completed" { finishStop() }
            return
        }
        session.lastActivity = Date()
        switch method {
        case "turn/started":
            currentTurn = (params["turn"] as? [String: Any])?["id"] as? String ?? currentTurn
            session.status = session.pending.isEmpty ? .busy : .waiting
            if interrupting { interrupt() }
        case "item/started":
            if let item = params["item"] as? [String: Any] {
                session.currentDetail = (item["command"] as? String) ?? (item["type"] as? String)
            }
        case "item/agentMessage/delta":
            session.currentDetail = "Codex is responding"
        case "item/completed":
            if let item = params["item"] as? [String: Any], item["type"] as? String == "agentMessage",
               let t = item["text"] as? String, !t.isEmpty { lastText = t }
        case "turn/completed":
            let turn = params["turn"] as? [String: Any] ?? [:]
            let status = turn["status"] as? String
            let items = turn["items"] as? [[String: Any]] ?? []
            let reply = items.last { $0["type"] as? String == "agentMessage" }?["text"] as? String ?? lastText
            let interrupted = status == "interrupted"
            let failed = status == "failed"
            session.lastTurnStatus = failed ? "failed" : interrupted ? "interrupted" : "completed"
            session.lastTurnDuration = session.turnStartedAt.map { Date().timeIntervalSince($0) }
            session.turnStartedAt = nil
            session.currentDetail = nil
            session.turns += 1
            session.lastReply = reply
            session.error = failed ? ((turn["error"] as? [String: Any])?["message"] as? String ?? "The turn failed.") : nil
            session.status = .idle
            session.pending = []
            requests = [:]
            currentTurn = nil
            interrupting = false
            changed()
            host?.driverTurnFinished(session.id, reply: reply, plan: nil, failed: failed, interrupted: interrupted)
            drainQueue()
            return
        case "serverRequest/resolved":
            // Answered elsewhere (or timed out): drop the card.
            if let rid = params["requestId"] {
                let gone = requests.filter { "\($0.value.rpc)" == "\(rid)" }.map(\.key)
                for k in gone { requests[k] = nil }
                session.pending.removeAll { gone.contains($0.id) }
                if session.pending.isEmpty && session.status == .waiting { session.status = .busy }
            }
        case "thread/status/changed":
            if let s = (params["status"] as? [String: Any])?["type"] as? String {
                if s == "idle", session.pending.isEmpty, currentTurn == nil { session.status = .idle }
                if s == "active", session.status == .idle { session.status = .busy }
            }
        case "error":
            if let e = (params["error"] as? [String: Any])?["message"] as? String { session.error = e }
        default:
            return
        }
        changed()
    }

    func serverExited(_ error: String?) {
        stopped = true
        queued = []
        for i in session.outbox.indices where [.queued, .forwarded].contains(session.outbox[i].state) {
            session.outbox[i].state = .failed
            session.outbox[i].error = "Codex disconnected before delivery was confirmed. Review the transcript before retrying."
        }
        session.status = error == nil ? .exited : .failed
        session.error = error
        session.pending = []
        requests = [:]
        changed()
        host?.driverExited(session.id, error: error)
    }

    private func drainQueue() {
        guard session.status == .idle, !stopped, !queued.isEmpty else { return }
        let next = queued.removeFirst()
        send(next.text, id: next.id, steer: false, limits: next.limits)
    }

    private func appendOutbox(_ m: OutboxMessage) {
        if let i = session.outbox.firstIndex(where: { $0.id == m.id }) { session.outbox[i] = m; return }
        session.outbox.append(m)
        if session.outbox.count > 30 { session.outbox.removeFirst(session.outbox.count - 30) }
    }

    private func changed() { host?.driverChanged(session) }
}
