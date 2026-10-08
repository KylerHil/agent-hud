import Darwin
import Foundation

/// The broker process: owns managed agent sessions and pairs, and serves Agent HUD over a Unix socket.
/// Everything runs on `queue`; git and test commands run on `work` and report back to `queue`.
public final class BrokerService: AgentDriverHost {
    let queue = DispatchQueue(label: "agenthud.broker")
    private let work = DispatchQueue(label: "agenthud.broker.work", attributes: .concurrent)
    private var drivers: [String: AgentDriver] = [:]
    private var sessions: [String: ManagedSession] = [:]
    private var pairs: [String: PairState] = [:]
    private var editors: [String: EditorWorkspace] = [:]
    private var editorConnections: [String: LineConnection] = [:]
    private var editorCommands: [String: (editorID: String, done: (String?) -> Void)] = [:]
    private var clients: [ObjectIdentifier: LineConnection] = [:]
    private lazy var codex = CodexServer(queue: queue)
    private var listener: DispatchSourceRead?
    private var forgetting: Set<String> = []
    private var dirtySessions: Set<String> = []
    private var dirtyPairs: Set<String> = []
    private var removedSessions: [String] = []
    private var removedPairs: [String] = []
    private var flushScheduled = false
    private var saveScheduled = false
    private var lastBusy = Date()
    private var lockFD: Int32 = -1
    /// Which pair turn each session is taking: the phase, and whether the worktree must stay clean.
    private var pairTurns: [String: PairPhase] = [:]
    private let idleExit: TimeInterval

    public init(idleExit: TimeInterval = 600) { self.idleExit = idleExit }

    /// Binds the socket and runs until idle. Returns false when another broker already runs.
    public func run() -> Bool {
        Paths.ensureDir(Paths.home)
        lockFD = open(BrokerInfo.lockFile.path, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            log("another broker is running")
            return false
        }
        signal(SIGPIPE, SIG_IGN)
        queue.sync { load() }
        listener = LineSocket.listen(path: BrokerInfo.socketPath, queue: queue) { [weak self] c in self?.accept(c) }
        guard listener != nil else {
            log("couldn't listen on \(BrokerInfo.socketPath)")
            return false
        }
        log("broker \(getpid()) listening on \(BrokerInfo.socketPath)")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in self?.checkIdle() }
        timer.resume()
        _ = timer
        dispatchMain()
    }

    // MARK: Clients

    private func accept(_ c: LineConnection) {
        clients[ObjectIdentifier(c)] = c
        c.onLine = { [weak self, weak c] data in
            guard let self, let c, let req = try? BrokerCoding.decoder.decode(BrokerRequest.self, from: data) else { return }
            self.handle(req, from: c)
        }
        c.onClose = { [weak self, weak c] in
            guard let self, let c else { return }
            self.clients[ObjectIdentifier(c)] = nil
            for id in self.editorConnections.filter({ $0.value === c }).map(\.key) { self.disconnectEditor(id) }
        }
    }

    private func reply(_ c: LineConnection, _ req: BrokerRequest, ok: Bool = true, error: String? = nil, key: String? = nil) {
        var m = BrokerMessage(kind: "reply")
        m.replyTo = req.id
        m.ok = ok && error == nil
        m.error = error
        m.key = key
        c.send(m)
    }

    private func handle(_ req: BrokerRequest, from c: LineConnection) {
        lastBusy = Date()
        switch req.op {
        case "hello":
            var m = BrokerMessage(kind: "snapshot")
            m.version = BrokerInfo.protocolVersion
            m.brokerPID = getpid()
            m.sessions = Array(sessions.values)
            m.pairs = Array(pairs.values)
            m.editors = Array(editors.values)
            c.send(m)
            reply(c, req)
        case "editorHello", "editorHeartbeat":
            guard var editor = req.editor, !editor.id.isEmpty else { return reply(c, req, error: "Missing workspace identity.") }
            editor.lastSeen = Date()
            editor.connected = true
            editor.folders = Array(Set(editor.folders.filter { $0.hasPrefix("/") }.map(EditorWorkspace.canonical))).sorted()
            if let old = editorConnections[editor.id], old !== c { old.close() }
            let previous = editors[editor.id]
            editors[editor.id] = editor
            editorConnections[editor.id] = c
            if req.op == "editorHello" || previous?.folders != editor.folders || previous?.focused != editor.focused || previous?.connected != true || previous?.trusted != editor.trusted {
                broadcastEditors()
            }
            reply(c, req)
        case "editorResult":
            guard let id = req.commandID, let pending = editorCommands[id], editorConnections[pending.editorID] === c else {
                return reply(c, req, error: "No such editor command on this connection.")
            }
            editorCommands[id] = nil
            pending.done(req.ok == true ? nil : (req.error ?? "VS Code couldn't perform the action."))
            reply(c, req)
        case "editorAction":
            guard let action = req.action, EditorCommand.actions.contains(action), let cwd = req.text,
                  let editor = req.editorID.flatMap({ editors[$0] }) ?? EditorWorkspace.best(in: Array(editors.values), for: cwd),
                  editor.connected, editor.contains(cwd), let target = editorConnections[editor.id] else {
                return reply(c, req, error: "No connected VS Code bridge for this folder. Enable Agent HUD Workspace Bridge in that window, then Retry.")
            }
            var result: String?
            if action == "result" { result = req.session.flatMap { sessions[$0]?.lastReply } ?? "No completed reply yet." }
            let command = EditorCommand(id: req.id, editorID: editor.id, action: action, cwd: cwd, text: result)
            editorCommands[req.id] = (editor.id, { [weak self, weak c] error in
                if let self, let c { self.reply(c, req, error: error) }
            })
            var message = BrokerMessage(kind: "editorCommand"); message.editorCommand = command
            target.send(message)
            queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let pending = self?.editorCommands.removeValue(forKey: req.id) else { return }
                pending.done("VS Code didn't acknowledge the action. Check that window and reconnect the bridge.")
            }
        case "start":
            guard let o = req.start else { return reply(c, req, error: "Nothing to start.") }
            switch startSession(o) {
            case .success(let key): reply(c, req, key: key)
            case .failure(let e): reply(c, req, error: e.localizedDescription)
            }
        case "send":
            guard let key = req.session, let d = drivers[key], let text = req.text else {
                return reply(c, req, error: "That session isn't running. Resume it first.")
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return reply(c, req, error: "Enter a task or reply first.") }
            guard !d.session.outbox.contains(where: { $0.id == req.id }) else { return reply(c, req) }
            guard d.session.outbox.filter({ [.queued, .forwarded].contains($0.state) }).count < 20 else {
                return reply(c, req, error: "This agent already has 20 unconfirmed messages. Wait for progress before sending more.")
            }
            d.send(text, id: req.id, steer: req.steer ?? false, limits: nil)
            save()
            reply(c, req)
        case "interrupt":
            guard let d = drivers[req.session ?? ""] else { return reply(c, req, error: "That session isn't connected. Resume it first.") }
            d.interrupt()
            reply(c, req)
        case "answer":
            guard let key = req.session, let d = drivers[key], let rid = req.requestId,
                  d.session.pending.contains(where: { $0.id == rid }) else { return reply(c, req, error: "That prompt is no longer pending. Refresh the session.") }
            d.answer(requestId: rid, decision: req.decision ?? "deny", answers: req.answers, message: req.message)
            reply(c, req)
        case "mode":
            if let key = req.session, let mode = req.text { drivers[key]?.setPermissionMode(mode) }
            reply(c, req)
        case "stop":
            if let key = req.session { drivers[key]?.stop() }
            reply(c, req)
        case "forget":
            if let key = req.session {
                if let d = drivers[key] { forgetting.insert(key); d.stop() }
                else { removeSession(key) }
            }
            reply(c, req)
        case "pairStart":
            guard let config = req.pair else { return reply(c, req, error: "No pair to start.") }
            startPair(config) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let id): self.reply(c, req, key: id)
                case .failure(let e): self.reply(c, req, error: e.localizedDescription)
                }
            }
        case "pairAction":
            guard let id = req.pairID, pairs[id] != nil else { return reply(c, req, error: "No such pair.") }
            pairAction(id, req.action ?? "", text: req.text) { [weak self] error in self?.reply(c, req, error: error) }
        case "shutdown":
            // Asked by a newer app: only when nothing is running.
            if drivers.values.contains(where: { [.busy, .waiting, .starting].contains($0.session.status) }) {
                reply(c, req, error: "Sessions are still working.")
            } else {
                reply(c, req)
                queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.shutdown() }
            }
        default:
            reply(c, req, error: "Unknown request \(req.op).")
        }
    }

    // MARK: Sessions

    private func startSession(_ o: StartOptions, key: String = UUID().uuidString) -> Result<String, Error> {
        var directory: ObjCBool = false
        guard o.cwd.hasPrefix("/"), FileManager.default.fileExists(atPath: o.cwd, isDirectory: &directory), directory.boolValue else {
            return .failure(DriverError.failed("The folder \(o.cwd) doesn't exist."))
        }
        if let resume = o.resume, !o.fork,
           sessions.values.contains(where: { $0.agent == o.agent && $0.sessionId == resume && drivers[$0.id] != nil }) {
            return .failure(DriverError.failed("This conversation is already managed. Select its existing session instead."))
        }
        let d: AgentDriver
        switch o.agent {
        case .claude: d = ClaudeDriver(key: key, options: o, queue: queue, host: self)
        case .codex: d = CodexDriver(key: key, options: o, server: codex, host: self)
        case .chatgpt: return .failure(DriverError.failed("ChatGPT chats can't be started here."))
        }
        drivers[key] = d
        do {
            try d.start()
        } catch {
            drivers[key] = nil
            log("start failed: \(error)")
            return .failure(error)
        }
        driverChanged(d.session)
        save()
        log("started \(o.agent.rawValue) \(key) in \(o.cwd)\(o.resume.map { " resuming \($0)" } ?? "")")
        return .success(key)
    }

    public func driverChanged(_ s: ManagedSession) {
        var s = s
        // Keep what the broker learned across driver restarts (a resumed session keeps its key).
        if s.sessionId == nil { s.sessionId = sessions[s.id]?.sessionId }
        if s.transcriptPath == nil { s.transcriptPath = sessions[s.id]?.transcriptPath }
        let previousOutcome = sessions[s.id]?.lastTurnStatus
        let previousTurns = sessions[s.id]?.turns
        sessions[s.id] = s
        dirtySessions.insert(s.id)
        if [.busy, .waiting, .starting].contains(s.status) { lastBusy = Date() }
        scheduleFlush()
        if s.lastTurnStatus != previousOutcome || s.turns != previousTurns { save() }
    }

    private func removeSession(_ key: String) {
        sessions[key] = nil
        dirtySessions.remove(key)
        removedSessions.append(key)
        scheduleFlush()
        save()
    }

    public func driverExited(_ key: String, error: String?) {
        drivers[key] = nil
        if forgetting.remove(key) != nil { removeSession(key); return }
        log("session \(key) exited\(error.map { ": \($0)" } ?? "")")
        if let pid = sessions[key]?.pairID, var p = pairs[pid], p.status == .running, pairTurns[key] != nil {
            pairTurns[key] = nil
            p.status = .waitingOnYou
            p.reason = "\(sessions[key]?.agent.displayName ?? "An agent") stopped mid-turn\(error.map { ": \($0)" } ?? ".")"
            pairs[pid] = p
            dirtyPairs.insert(pid)
            scheduleFlush()
        }
    }

    public func driverTurnFinished(_ key: String, reply: String?, plan: String?, failed: Bool, interrupted: Bool) {
        guard let s = sessions[key], let pid = s.pairID, pairs[pid] != nil, let phase = pairTurns.removeValue(forKey: key) else { return }
        let input = PairInput.turnFinished(agent: s.agent, reply: reply, plan: plan, failed: failed, interrupted: interrupted)
        guard let p = pairs[pid], p.config.useWorktree, !phase.writes, let wt = p.worktree else { return feed(pid, input) }
        // A read-only turn must leave the worktree as it was. Anything else is thrown away.
        work.async { [weak self] in
            let dirty = Git.run(["status", "--porcelain"], in: wt).out
                .split(separator: "\n").map { String($0.dropFirst(3)) }

            self?.queue.async {
                if !dirty.isEmpty {
                    self?.waitOnYou(pid, "A review turn changed files: " + dirty.joined(separator: ", ") + ". Changes were preserved. Inspect them before continuing.")
                    return
                }
                self?.feed(pid, input)
            }
        }
    }

    public func driverPolicy(_ key: String, tool: String, input: [String: Any]) -> ToolPolicy {
        guard let s = sessions[key], let pid = s.pairID, let p = pairs[pid] else { return .ask }
        let phase = pairTurns[key]
        let writes = phase?.writes == true
        if tool == "ExitPlanMode" {
            return .deny("Agent HUD has your plan and passes it on. Stop here and end your turn.")
        }
        if writes { return .ask }
        if ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(tool) {
            return .deny("This is a read-only turn in a pair (\(p.phase.label.lowercased())). Don't change files; describe changes instead.")
        }
        if tool == "Bash", let cmd = input["command"] as? String {
            return Self.isReadOnly(cmd) ? .allow
                : .deny("This is a read-only turn in a pair. Only read-only commands (git diff/log/show/status, rg, grep, ls, cat, sed -n, head, tail, find, wc) run here.")
        }
        return .ask
    }

    /// Commands a read-only pair turn may run without asking: inspection only, no redirects.
    static func isReadOnly(_ command: String) -> Bool {
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.contains(">") || c.contains("`") || c.contains("$(") || c.contains(";") || c.contains("&&") || c.contains("||") { return false }
        let allowed = ["git diff", "git log", "git show", "git status", "git blame", "git ls-files", "git rev-parse",
                       "rg ", "grep ", "ls", "cat ", "head ", "tail ", "wc ", "find ", "sed -n ", "pwd", "tree"]
        return c.split(separator: "|").allSatisfy { part in
            let p = part.trimmingCharacters(in: .whitespaces)
            return allowed.contains { p == $0.trimmingCharacters(in: .whitespaces) || p.hasPrefix($0) }
                && !(p.hasPrefix("find ") && (p.contains("-delete") || p.contains("-exec")))
        }
    }

    // MARK: Pairs

    private func startPair(_ config: PairConfig, done: @escaping (Result<String, Error>) -> Void) {
        let id = UUID().uuidString
        work.async { [weak self] in
            let prepared = Self.prepareWorkspace(config)
            self?.queue.async {
                guard let self else { return }
                switch prepared {
                case .failure(let e):
                    done(.failure(e))
                case .success(let ws):
                    var p = PairState(id: id, config: config, now: Date())
                    p.branch = ws.branch
                    p.worktree = ws.worktree
                    p.baseSHA = ws.base
                    p.buildSHA = ws.base
                    self.pairs[id] = p
                    for agent in Set([config.planner, config.builder, config.reviewer]) {
                        let mode = agent == .claude ? (config.planner == .claude ? "plan" : config.builderMode) : "workspace-write"
                        let o = StartOptions(agent: agent, cwd: p.workDir, permissionMode: mode,
                                             title: "Pair: " + config.goal.prefix(60), pairID: id)
                        switch self.startSession(o) {
                        case .success(let key): p.sessions[agent.rawValue] = key
                        case .failure(let e):
                            self.pairs[id] = nil
                            p.sessions.values.forEach { self.drivers[$0]?.stop() }
                            return done(.failure(e))
                        }
                    }
                    self.pairs[id] = p
                    done(.success(id))
                    self.feed(id, .begin)
                }
            }
        }
    }

    struct Workspace { var branch: String?; var worktree: String?; var base: String }

    static func prepareWorkspace(_ c: PairConfig) -> Result<Workspace, Error> {
        let top = Git.run(["rev-parse", "--show-toplevel"], in: c.root)
        guard top.ok else { return .failure(DriverError.failed("\(c.root) isn't a git repository.")) }
        let root = top.out.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = Git.run(["rev-parse", "HEAD"], in: root)
        guard head.ok else { return .failure(DriverError.failed("The repository has no commits yet.")) }
        let base = head.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard c.useWorktree else {
            guard Git.run(["status", "--porcelain"], in: root).out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(DriverError.failed("The checkout has existing changes. Use a new worktree so the pair won't commit unrelated work."))
            }
            let branch = Git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: root).out.trimmingCharacters(in: .whitespacesAndNewlines)
            return .success(Workspace(branch: branch, worktree: nil, base: base))
        }
        let slug = Self.slug(c.goal)
        let repo = (root as NSString).lastPathComponent
        let parent = (root as NSString).deletingLastPathComponent
        var n = 1
        var branch = "pair/" + slug, path = (parent as NSString).appendingPathComponent("\(repo)-pair-\(slug)")
        while Git.run(["rev-parse", "--verify", "--quiet", branch], in: root).ok || FileManager.default.fileExists(atPath: path) {
            n += 1
            branch = "pair/\(slug)-\(n)"
            path = (parent as NSString).appendingPathComponent("\(repo)-pair-\(slug)-\(n)")
        }
        let add = Git.run(["worktree", "add", "-b", branch, path, base], in: root)
        guard add.ok else { return .failure(DriverError.failed("git worktree add failed: \(add.err.trimmingCharacters(in: .whitespacesAndNewlines))")) }
        return .success(Workspace(branch: branch, worktree: path, base: base))
    }

    static func slug(_ goal: String) -> String {
        let words = goal.lowercased().split { !$0.isLetter && !$0.isNumber }.prefix(4)
        let s = words.joined(separator: "-")
        return s.isEmpty ? "work" : String(s.prefix(40))
    }

    /// Runs the pair engine and carries out what it asks for.
    private func feed(_ id: String, _ input: PairInput) {
        guard var p = pairs[id] else { return }
        let actions = PairEngine.step(&p, input)
        pairs[id] = p
        dirtyPairs.insert(id)
        scheduleFlush()
        for a in actions { perform(a, pair: id) }
    }

    private func perform(_ action: PairAction, pair id: String) {
        guard let p = pairs[id] else { return }
        switch action {
        case .send(let agent, let text, let phase):
            guard let key = p.sessions[agent.rawValue] else { return }
            guard let d = drivers[key] else {
                // The agent stopped since: start it again on the same conversation, then send.
                return revive(id, agent: agent) { [weak self] in self?.perform(action, pair: id) }
            }
            pairTurns[key] = phase
            if agent == .claude {
                d.setPermissionMode(phase.writes ? p.config.builderMode : "plan")
                d.send(text, id: UUID().uuidString, steer: false, limits: nil)
            } else {
                let approval = phase.writes ? (p.config.builderMode == "default" ? "on-request" : "never") : "never"
                d.send(text, id: UUID().uuidString, steer: false, limits: TurnLimits(readOnly: !phase.writes, approval: approval))
            }
        case .commit(let message):
            let dir = p.workDir
            work.async { [weak self] in
                _ = Git.run(["add", "-A"], in: dir)
                let empty = Git.run(["diff", "--cached", "--quiet"], in: dir).ok
                var input = PairInput.committed(sha: nil, files: [])
                if !empty {
                    let commit = Git.run(["commit", "-m", message], in: dir, timeout: 300)
                    if commit.ok {
                        let sha = Git.run(["rev-parse", "HEAD"], in: dir).out.trimmingCharacters(in: .whitespacesAndNewlines)
                        let files = Git.run(["diff", "--name-only", "HEAD~1", "HEAD"], in: dir).out.split(separator: "\n").map(String.init)
                        input = .committed(sha: sha, files: files)
                    } else {
                        let err = (commit.err + commit.out).trimmingCharacters(in: .whitespacesAndNewlines)
                        self?.queue.async { self?.waitOnYou(id, "git commit failed: \(err.suffix(400))") }
                        return
                    }
                }
                self?.queue.async { self?.feed(id, input) }
            }
        case .runTests:
            guard let cmd = p.config.testCommand else { return }
            let dir = p.workDir
            log("pair \(id): running \(cmd)")
            work.async { [weak self] in
                let r = Git.sh(cmd, in: dir, timeout: 1800)
                self?.queue.async { self?.feed(id, .tests(passed: r.ok, output: r.out + r.err)) }
            }
        case .review:
            let dir = p.workDir
            let range = "\(p.baseSHA ?? "HEAD~1")..\(p.buildSHA ?? "HEAD")"
            work.async { [weak self] in
                let stat = Git.run(["diff", "--stat", range], in: dir).out
                var diff = Git.run(["diff", range], in: dir).out
                let limit = 60_000
                let truncated = diff.utf8.count > limit
                if truncated { diff = String(diff.prefix(limit)) }
                self?.queue.async {
                    guard let self, let p = self.pairs[id] else { return }
                    let text = PairEngine.reviewPrompt(p, stat: stat, diff: diff, truncated: truncated)
                    self.perform(.send(agent: p.config.reviewer, text: text, phase: .review), pair: id)
                }
            }
        case .interruptAll:
            for key in p.sessions.values {
                pairTurns[key] = nil
                drivers[key]?.interrupt()
            }
        }
    }

    private func waitOnYou(_ id: String, _ reason: String) {
        guard var p = pairs[id] else { return }
        p.status = .waitingOnYou
        p.reason = reason
        p.events.append(PairEvent(at: Date(), kind: .warning, phase: p.phase, round: p.round, text: reason))
        pairs[id] = p
        dirtyPairs.insert(id)
        scheduleFlush()
    }

    /// Starts a pair agent again on its conversation (after the broker or the agent restarted).
    private func revive(_ id: String, agent: AgentKind, then: @escaping () -> Void) {
        guard var p = pairs[id], let key = p.sessions[agent.rawValue] else { return }
        let old = sessions[key]
        let mode = agent == .claude ? "plan" : "workspace-write"
        let o = StartOptions(agent: agent, cwd: p.workDir, resume: old?.sessionId, permissionMode: mode,
                             title: old?.title, pairID: id)
        switch startSession(o, key: key) {
        case .success:
            // Codex resumes asynchronously; give it a moment to load the thread.
            queue.asyncAfter(deadline: .now() + (agent == .codex ? 3 : 0.5), execute: then)
        case .failure(let e):
            p.status = .waitingOnYou
            p.reason = "Couldn't restart \(agent.displayName): \(e.localizedDescription)"
            pairs[id] = p
            dirtyPairs.insert(id)
            scheduleFlush()
        }
    }

    private func pairAction(_ id: String, _ action: String, text: String?, done: @escaping (String?) -> Void) {
        guard let p = pairs[id] else { return done("No such pair.") }
        switch action {
        case "approvePlan": feed(id, .approvePlan(notes: text)); done(nil)
        case "pause": feed(id, .pause); done(nil)
        case "resume", "retry": feed(id, .resume); done(nil)
        case "stop": feed(id, .stop); done(nil)
        case "keepGoing":
            guard let goal = text, !goal.isEmpty else { return done("Give the pair a goal.") }
            feed(id, .keepGoing(goal: goal)); done(nil)
        case "merge":
            guard let branch = p.branch, p.worktree != nil else { return done("This pair works in your checkout; there's nothing to merge.") }
            let root = p.config.root
            work.async { [weak self] in
                let status = Git.run(["status", "--porcelain", "--untracked-files=no"], in: root).out
                let error: String?
                if !status.isEmpty {
                    error = "Your checkout has uncommitted changes. Commit or stash them, then merge."
                } else {
                    let m = Git.run(["merge", "--no-ff", "--no-edit", branch], in: root, timeout: 300)
                    if !m.ok { _ = Git.run(["merge", "--abort"], in: root) }
                    error = m.ok ? nil : "git merge failed and was aborted: " + (m.err + m.out).trimmingCharacters(in: .whitespacesAndNewlines).suffix(400)
                }
                self?.queue.async {
                    if error == nil, var q = self?.pairs[id] {
                        q.events.append(PairEvent(at: Date(), kind: .you, round: q.round, text: "Merged \(branch) into your checkout."))
                        self?.pairs[id] = q
                        self?.dirtyPairs.insert(id)
                        self?.scheduleFlush()
                    }
                    done(error)
                }
            }
        case "remove":
            feed(id, .stop)
            for key in p.sessions.values {
                drivers.removeValue(forKey: key)?.stop()
                sessions[key] = nil
                removedSessions.append(key)
            }
            let worktree = p.worktree, root = p.config.root, deleteWorktree = text == "worktree"
            pairs[id] = nil
            removedPairs.append(id)
            scheduleFlush()
            guard deleteWorktree, let worktree else { return done(nil) }
            work.async { [weak self] in
                let r = Git.run(["worktree", "remove", worktree], in: root)
                self?.queue.async { done(r.ok ? nil : "The worktree has uncommitted changes, so it was kept: \(worktree)") }
            }
        default:
            done("Unknown action \(action).")
        }
    }

    // MARK: Broadcast and persistence

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.flush() }
    }

    private func flush() {
        flushScheduled = false
        var messages: [BrokerMessage] = []
        for key in dirtySessions { if let s = sessions[key] { var m = BrokerMessage(kind: "session"); m.session = s; messages.append(m) } }
        for id in dirtyPairs { if let p = pairs[id] { var m = BrokerMessage(kind: "pair"); m.pair = p; messages.append(m) } }
        for key in removedSessions { var m = BrokerMessage(kind: "removed"); m.removed = key; messages.append(m) }
        for id in removedPairs { var m = BrokerMessage(kind: "pairRemoved"); m.removed = id; messages.append(m) }
        dirtySessions = []; dirtyPairs = []; removedSessions = []; removedPairs = []
        for c in clients.values { for m in messages { c.send(m) } }
        if !saveScheduled {
            saveScheduled = true
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.save() }
        }
    }

    private struct Saved: Codable {
        var sessions: [ManagedSession]
        var pairs: [PairState]
    }

    private func save() {
        saveScheduled = false
        let saved = Saved(sessions: Array(sessions.values), pairs: Array(pairs.values))
        guard let data = try? BrokerCoding.encoder.encode(saved) else { return }
        let url = BrokerInfo.stateFile
        try? data.write(to: url, options: .atomic)
        chmod(url.path, 0o600)
    }

    /// After a restart nothing is running: sessions show as stopped (resumable), and a pair that was mid-turn
    /// waits for you rather than replaying a turn that may have already changed files.
    private func load() {
        guard let data = try? Data(contentsOf: BrokerInfo.stateFile),
              let saved = try? BrokerCoding.decoder.decode(Saved.self, from: data) else { return }
        for var s in saved.sessions {
            if s.status != .exited && s.status != .failed {
                s.status = .exited
                s.error = "The broker restarted. Review the last output before resuming; work was not replayed."
                    + (s.pending.first.map { " Last request: " + $0.summary } ?? "")
                s.lastTurnStatus = "interrupted"
            }
            for i in s.outbox.indices where [.queued, .forwarded].contains(s.outbox[i].state) {
                s.outbox[i].state = .failed
                s.outbox[i].error = "The broker restarted before delivery was confirmed. Review the transcript before retrying."
            }
            s.pid = nil
            s.pending = []
            sessions[s.id] = s
        }
        for var p in saved.pairs {
            if p.status == .running {
                p.status = .waitingOnYou
                p.reason = "Agent HUD's broker restarted during \(p.phase.label.lowercased()). Check the worktree, then Resume to run that step again."
            }
            pairs[p.id] = p
        }
    }

    private func broadcastEditors() {
        var m = BrokerMessage(kind: "editors"); m.editors = Array(editors.values)
        for c in clients.values { c.send(m) }
    }

    private func disconnectEditor(_ id: String) {
        editorConnections[id] = nil
        editors[id]?.connected = false
        let pending = editorCommands.filter { $0.value.editorID == id }
        for (key, value) in pending { editorCommands[key] = nil; value.done("The VS Code window disconnected. Reopen or reconnect it, then Retry.") }
        broadcastEditors()
    }

    private func checkIdle() {
        for id in editors.values.filter({ $0.connected && Date().timeIntervalSince($0.lastSeen) > 45 }).map(\.id) {
            editorConnections[id]?.close()
        }
        for id in editors.values.filter({ !$0.connected && Date().timeIntervalSince($0.lastSeen) > 3600 }).map(\.id) { editors[id] = nil }

        let live = drivers.values.contains { $0.session.status != .exited && $0.session.status != .failed }
        let pairRunning = pairs.values.contains { $0.status == .running }
        if !live, !pairRunning, clients.isEmpty, Date().timeIntervalSince(lastBusy) > idleExit {
            log("idle; exiting")
            shutdown()
        }
    }

    private func shutdown() {
        save()
        drivers.values.forEach { $0.stop() }
        codex.stop()
        listener?.cancel()
        unlink(BrokerInfo.socketPath)
        exit(0)
    }

    func log(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        guard let h = try? FileHandle(forWritingTo: BrokerInfo.logFile) else {
            try? line.write(to: BrokerInfo.logFile, atomically: true, encoding: .utf8)
            return
        }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data(line.utf8))
    }
}
