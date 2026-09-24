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
    }

    /// Desktop apps are out of scope; only terminals and editors are tracked.
    static let ignoredHosts: Set<String> = ["claude", "chatgpt", "codex"]

    public static func agentProcesses() -> [AgentProcess] {
        let candidates = ProcTools.allProcesses().filter { ["claude", "claude.exe", "codex"].contains($0.comm) }
        return candidates.compactMap { e in
            guard let kind = ProcTools.agentKind(pid: e.pid, comm: e.comm) else { return nil }
            let anc = ProcTools.ancestry(from: e.pid, agent: kind, env: [:])
            if let host = anc.hostKind, ignoredHosts.contains(host) { return nil }
            return AgentProcess(pid: e.pid, agent: kind, cwd: ProcTools.cwd(e.pid), tty: e.tty.map { "/dev/" + $0 },
                                hostApp: anc.hostApp, hostKind: anc.hostKind)
        }
    }

    /// Events that bring the store in line with the process table:
    /// - a session whose agent process is gone has ended;
    /// - a Claude process no hooked session claims gets a placeholder row.
    ///   (Codex app-servers run with cwd "/" and host many threads, so they only count for liveness.)
    public static func reconcile(store: SessionStore, processes: [AgentProcess], now: Date = Date()) -> [AgentEvent] {
        var events: [AgentEvent] = []
        let alive = Set(processes.map(\.pid))
        var claimed = Set<Int32>()
        for s in store.sessions.values {
            guard let pid = s.pid else { continue }
            if s.state != .ended && !alive.contains(pid) {
                var e = AgentEvent(ts: now.timeIntervalSince1970, agent: s.agent, event: "ProcessExited",
                                   sessionId: s.sessionId)
                e.origin = "scanner"
                events.append(e)
            } else if s.state != .ended {
                claimed.insert(pid)
            }
        }
        for p in processes where p.agent == .claude && !claimed.contains(p.pid) {
            var e = AgentEvent(ts: now.timeIntervalSince1970, agent: .claude, event: "ProcessSeen",
                               sessionId: "pid-\(p.pid)")
            e.pid = p.pid
            e.cwd = p.cwd
            e.tty = p.tty
            e.hostApp = p.hostApp
            e.hostKind = p.hostKind
            e.origin = "scanner"
            events.append(e)
        }
        return events
    }
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
            if r.originator?.contains("vscode") == true {
                e.hostKind = "vscode"
                e.hostApp = FileManager.default.fileExists(atPath: "/Applications/Visual Studio Code.app")
                    ? "/Applications/Visual Studio Code.app" : nil
            }
            events.append(e)
        }
        return events
    }
}
