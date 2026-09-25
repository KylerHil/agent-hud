import Foundation

/// Finds running claude/codex processes. Used for liveness and to show sessions that predate the hooks.
public enum ProcessScanner {
    public struct AgentProcess: Equatable, Sendable {
        public var pid: Int32
        public var agent: AgentKind
        public var cwd: String?
        public var tty: String?
        public var hostApp: String?
        public var hostKind: String?
        public var started: Date? = nil
    }

    /// Editors start short-lived helper `claude` processes (a few seconds each, never hooked).
    /// Only a process that has lived this long gets a placeholder row.
    public static let placeholderMinAge: TimeInterval = 30

    public static func agentProcesses() -> [AgentProcess] {
        let candidates = ProcTools.allProcesses().filter { !$0.zombie && ["claude", "claude.exe", "codex"].contains($0.comm) }
        return candidates.compactMap { e in
            guard let kind = ProcTools.agentKind(pid: e.pid, comm: e.comm) else { return nil }
            let anc = ProcTools.ancestry(from: e.pid, agent: kind, env: [:])
            return AgentProcess(pid: e.pid, agent: kind, cwd: ProcTools.cwd(e.pid), tty: e.tty.map { "/dev/" + $0 },
                                hostApp: anc.hostApp, hostKind: anc.hostKind, started: e.started)
        }
    }

    /// Events that bring the store in line with the process table:
    /// - a session whose agent process is gone has ended;
    /// - a Claude process no hooked session claims gets a placeholder row.
    ///   (Codex app-servers run with cwd "/" and host many threads, so they only count for liveness.
    ///   Claude desktop's processes are covered by `ClaudeDesktopScanner`, which knows their session ids.)
    public static func reconcile(store: SessionStore, processes: [AgentProcess], now: Date = Date()) -> [AgentEvent] {
        var events: [AgentEvent] = []
        let alive = Set(processes.map(\.pid))
        var claimed = Set<Int32>()
        /// Placeholder rows already shown, by pid.
        var placeholders: [Int32: Session] = [:]
        for s in store.sessions.values {
            guard let pid = s.pid else { continue }
            if s.state != .ended && !alive.contains(pid) {
                var e = AgentEvent(ts: now.timeIntervalSince1970, agent: s.agent, event: "ProcessExited",
                                   sessionId: s.sessionId)
                e.origin = "scanner"
                events.append(e)
            } else if s.state != .ended {
                if isPlaceholder(s) { placeholders[pid] = s } else { claimed.insert(pid) }
            }
        }
        // Editors keep a Claude process per open panel, so one project can have many hookless processes.
        // They get one row per project and app, not one each.
        var groups: [String: [AgentProcess]] = [:]
        for p in processes where p.agent == .claude && !claimed.contains(p.pid) && p.hostKind != "claude-desktop" {
            if placeholders[p.pid] == nil, let started = p.started, now.timeIntervalSince(started) < placeholderMinAge { continue }
            // Without a working folder there's no project to show or window to jump to.
            guard let cwd = p.cwd, !cwd.isEmpty, cwd != "/" else { continue }
            groups[ProjectRoot.root(of: cwd) + "|" + (p.hostApp ?? p.hostKind ?? ""), default: []].append(p)
        }
        var shown = Set<Int32>()
        for ps in groups.values {
            // Keep the row already shown, so it doesn't jump around; else the newest process.
            let rep = ps.first { placeholders[$0.pid] != nil }
                ?? ps.max { ($0.started ?? .distantPast) < ($1.started ?? .distantPast) }!
            shown.insert(rep.pid)
            let title = ps.count > 1 ? "\(ps.count) Claude processes without hooks" : nil
            if let existing = placeholders[rep.pid], existing.title == title { continue }
            var e = AgentEvent(ts: now.timeIntervalSince1970, agent: .claude, event: "ProcessSeen",
                               sessionId: "pid-\(rep.pid)")
            e.pid = rep.pid
            e.cwd = rep.cwd
            e.tty = rep.tty
            e.hostApp = rep.hostApp
            e.hostKind = rep.hostKind
            e.title = title ?? (placeholders[rep.pid]?.title != nil ? "1 Claude process without hooks" : nil)
            e.origin = "scanner"
            events.append(e)
        }
        // Rows for processes now covered by another row (or by a hooked session) go.
        for (pid, s) in placeholders where !shown.contains(pid) && alive.contains(pid) {
            var e = AgentEvent(ts: now.timeIntervalSince1970, agent: s.agent, event: "ProcessExited", sessionId: s.sessionId)
            e.origin = "scanner"
            events.append(e)
        }
        return events
    }

    /// A row made from a process alone, with no hook events behind it.
    static func isPlaceholder(_ s: Session) -> Bool { !s.hasHooks && s.sessionId.hasPrefix("pid-") }
}

/// Infers Codex session state from ~/.codex/sessions rollout logs, for sessions the hooks don't cover
/// (hooks not installed or not yet trusted). Rollouts record turns starting and ending, but not approvals.
public final class RolloutScanner {
    public struct Info: Equatable, Sendable {
        public var sessionId: String
        public var path: String
        public var cwd: String?
        public var originator: String?
        public var running: Bool
        public var lastPrompt: String?
        public var lastMessage: String?
        public var modified: Date
    }

    private let root: URL
    private var cache: [String: (mtime: Date, size: UInt64, info: Info?)] = [:]

    public init(root: URL = Paths.codexSessions) { self.root = root }

    /// Rollouts touched within `window`, from the last few day folders.
    public func recent(now: Date = Date(), window: TimeInterval = 6 * 3600) -> [Info] {
        var results: [Info] = []
        let fm = FileManager.default
        let cal = Calendar.current
        var seenDirs = Set<String>()
        for dayOffset in 0...2 {
            guard let day = cal.date(byAdding: .day, value: -dayOffset, to: now) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let dir = root.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
            guard seenDirs.insert(dir.path).inserted,
                  let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") {
                let path = dir.appendingPathComponent(name).path
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let mtime = attrs[.modificationDate] as? Date,
                      now.timeIntervalSince(mtime) < window else { continue }
                let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
                if let hit = cache[path], hit.mtime == mtime, hit.size == size {
                    if let info = hit.info { results.append(info) }
                    continue
                }
                let info = Self.parse(path: path, modified: mtime)
                cache[path] = (mtime, size, info)
                if let info { results.append(info) }
            }
        }
        return results
    }

    static func parse(path: String, modified: Date) -> Info? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        // session_meta is the first line; it can be large (it embeds instructions), so read generously.
        let head = (try? h.read(upToCount: 256 * 1024)) ?? Data()
        guard let nl = head.firstIndex(of: 0x0A) ?? (head.isEmpty ? nil : head.endIndex),
              let meta = try? JSONSerialization.jsonObject(with: head[..<nl]) as? [String: Any],
              meta["type"] as? String == "session_meta",
              let payload = meta["payload"] as? [String: Any],
              let id = (payload["id"] as? String) ?? (payload["session_id"] as? String) else { return nil }
        var info = Info(sessionId: id, path: path, cwd: payload["cwd"] as? String,
                        originator: (payload["originator"] as? String) ?? (payload["source"] as? String),
                        running: false, modified: modified)
        for line in TranscriptProbe.tailLines(path, bytes: 128 * 1024) {
            guard line.contains("\"event_msg\""),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let p = obj["payload"] as? [String: Any], let type = p["type"] as? String else { continue }
            switch type {
            case "task_started": info.running = true
            case "task_complete":
                info.running = false
                info.lastMessage = (p["last_agent_message"] as? String)?.preview(240)
            case "turn_aborted":
                info.running = false
                info.lastMessage = "Interrupted"
            case "user_message": info.lastPrompt = (p["message"] as? String)?.preview(120)
            default: break
            }
        }
        return info
    }

    /// Which app started a rollout, from its `originator` (`codex_vscode`, `Codex Desktop`, `codex_cli_rs`…).
    static func host(originator: String?) -> String? {
        guard let o = originator?.lowercased() else { return nil }
        if o.contains("vscode") { return "vscode" }
        if o.contains("chatgpt") || o.contains("desktop") || o.contains("codex_app") { return "chatgpt" }
        return nil
    }

    /// Events for rollouts whose inferred state differs from the store, skipping sessions hooks already cover.
    public static func reconcile(store: SessionStore, rollouts: [Info], codexAlive: Bool,
                                 now: Date = Date()) -> [AgentEvent] {
        let hookedPaths = Set(store.sessions.values.filter { $0.agent == .codex && $0.hasHooks }
            .compactMap(\.transcriptPath))
        var events: [AgentEvent] = []
        for r in rollouts {
            let key = SessionStore.key(.codex, r.sessionId)
            let existing = store.sessions[key]
            if existing?.hasHooks == true || hookedPaths.contains(r.path) { continue }
            let age = now.timeIntervalSince(r.modified)
            // A "running" turn whose log has been silent for 30 min died with its process.
            let running = r.running && age < 1800
            if existing == nil && !running && age > 2 * 3600 { continue } // old idle threads aren't news
            let name: String
            if !codexAlive { name = "ProcessExited" } else { name = running ? "RolloutRunning" : "RolloutIdle" }
            if existing == nil && name == "ProcessExited" { continue }
            if let s = existing {
                let current = s.state
                let wanted: SessionState = name == "ProcessExited" ? .ended : (running ? .running : .idle)
                if current == wanted { continue }
            }
            var e = AgentEvent(ts: now.timeIntervalSince1970, agent: .codex, event: name, sessionId: r.sessionId)
            e.cwd = r.cwd
            e.transcriptPath = r.path
            e.message = r.lastMessage
            e.prompt = r.lastPrompt
            e.origin = "rollout"
            if let kind = host(originator: r.originator) {
                e.hostKind = kind
                e.hostApp = ProcTools.defaultAppPath(forKind: kind)
            }
            events.append(e)
        }
        return events
    }
}

/// Finds sessions in the Claude desktop app's Code tab. Claude.app keeps one small JSON file per session
/// (`claude-code-sessions/<account>/<org>/local_<id>.json`) naming the Claude Code session id, folder and title;
/// the transcript lives in ~/.claude/projects like any other Claude Code session.
/// Hooks, when they fire for desktop sessions, take over state; this still supplies the title.
public final class ClaudeDesktopScanner {
    public struct Info: Equatable, Sendable {
        public var sessionId: String
        public var cwd: String?
        public var title: String?
        public var transcriptPath: String?
        public var lastActivity: Date
        /// Claude.app's own id for the session (`local_…`), which its deep links take.
        public var localId: String?

        /// Opens this session in Claude.app.
        public var openURL: String? { localId.map { "claude://code/continue?session=\($0)" } }
    }

    private let root: URL
    private let projects: URL
    private var cache: [String: (mtime: Date, info: Info?)] = [:]

    public init(root: URL = Paths.claudeDesktopSessions, projects: URL = Paths.claudeProjects) {
        self.root = root
        self.projects = projects
    }

    /// Sessions active within `window`, by their metadata or their transcript.
    public func recent(now: Date = Date(), window: TimeInterval = 6 * 3600) -> [Info] {
        let fm = FileManager.default
        var results: [Info] = []
        for account in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            let accountDir = root.appendingPathComponent(account)
            for org in (try? fm.contentsOfDirectory(atPath: accountDir.path)) ?? [] {
                let dir = accountDir.appendingPathComponent(org)
                for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
                where name.hasPrefix("local_") && name.hasSuffix(".json") {
                    let path = dir.appendingPathComponent(name).path
                    guard let mtime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { continue }
                    var info: Info?
                    if let hit = cache[path], hit.mtime == mtime, hit.info?.transcriptPath != nil {
                        info = hit.info
                    } else {
                        info = (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { Self.parse($0, projects: projects) }
                        if info?.localId == nil { info?.localId = (name as NSString).deletingPathExtension }
                        cache[path] = (mtime, info)
                    }
                    guard let info else { continue }
                    let touched = max(info.lastActivity, info.transcriptPath.flatMap(TranscriptProbe.modificationDate) ?? .distantPast)
                    if now.timeIntervalSince(touched) < window { results.append(info) }
                }
            }
        }
        return results
    }

    static func parse(_ data: Data, projects: URL) -> Info? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["cliSessionId"] as? String, !id.isEmpty,
              obj["isArchived"] as? Bool != true else { return nil }
        let cwd = obj["cwd"] as? String
        let ms = (obj["lastActivityAt"] as? Double) ?? (obj["createdAt"] as? Double) ?? 0
        let title = (obj["title"] as? String).flatMap { $0.isEmpty ? nil : $0.preview(80) }
        let local = (obj["sessionId"] as? String).flatMap { $0.hasPrefix("local_") ? $0 : nil }
        return Info(sessionId: id, cwd: cwd, title: title,
                    transcriptPath: transcriptPath(projects: projects, cwd: cwd, sessionId: id),
                    lastActivity: Date(timeIntervalSince1970: ms / 1000), localId: local)
    }

    /// `~/.claude/projects/<cwd with every non-alphanumeric as "-">/<id>.jsonl`, else a search of all projects.
    static func transcriptPath(projects: URL, cwd: String?, sessionId: String) -> String? {
        let fm = FileManager.default
        if let cwd {
            let dir = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
            let p = projects.appendingPathComponent(dir).appendingPathComponent("\(sessionId).jsonl").path
            if fm.fileExists(atPath: p) { return p }
        }
        for dir in (try? fm.contentsOfDirectory(atPath: projects.path)) ?? [] {
            let p = projects.appendingPathComponent(dir).appendingPathComponent("\(sessionId).jsonl").path
            if fm.fileExists(atPath: p) { return p }
        }
        return nil
    }

    /// Events that bring desktop sessions in line with their files. Running vs idle comes from the transcript
    /// (a turn is open until an assistant entry ends it); needs-input can only come from hooks.
    public static func reconcile(store: SessionStore, sessions: [Info], appRunning: Bool,
                                 now: Date = Date()) -> [AgentEvent] {
        var events: [AgentEvent] = []
        for d in sessions {
            let existing = store.sessions[SessionStore.key(.claude, d.sessionId)]
            func event(_ name: String) -> AgentEvent {
                var e = AgentEvent(ts: now.timeIntervalSince1970, agent: .claude, event: name, sessionId: d.sessionId)
                e.cwd = d.cwd
                e.transcriptPath = d.transcriptPath
                e.title = d.title
                e.openURL = d.openURL
                e.hostKind = "claude-desktop"
                e.hostApp = ProcTools.defaultAppPath(forKind: "claude-desktop")
                e.origin = "desktop"
                return e
            }
            if !appRunning {
                if let s = existing, s.state != .ended, !s.hasHooks { events.append(event("ProcessExited")) }
                continue
            }
            if let s = existing, s.hasHooks {
                if (d.title != nil && s.title != d.title) || (d.openURL != nil && s.openURL != d.openURL) {
                    events.append(event("SessionTitle"))
                }
                continue
            }
            let written = d.transcriptPath.flatMap(TranscriptProbe.modificationDate) ?? .distantPast
            let age = now.timeIntervalSince(max(d.lastActivity, written))
            let open = d.transcriptPath.flatMap(TranscriptProbe.claudeTurnEnded).map { !$0 } ?? false
            // An open turn with a transcript silent for 10 minutes was abandoned (app quit mid-turn, crash).
            let running = open && age < 600
            if existing == nil && !running && age > 2 * 3600 { continue }
            let wanted: SessionState = running ? .running : .idle
            if let s = existing, s.state == wanted, s.title == d.title, s.openURL == d.openURL { continue }
            events.append(event(running ? "RolloutRunning" : "RolloutIdle"))
        }
        return events
    }
}
