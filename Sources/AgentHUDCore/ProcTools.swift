import Darwin
import Foundation

/// Native process introspection (sysctl + libproc) so we never shell out to ps/lsof.
public enum ProcTools {
    public struct Entry: Sendable {
        public let pid: pid_t
        public let ppid: pid_t
        public let comm: String
        public let tty: String?
        public var started: Date? = nil
        /// Exited but not yet reaped by its parent: the name survives, the cwd and executable don't.
        public var zombie = false
    }

    public static func entry(_ pid: pid_t) -> Entry? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        return makeEntry(info)
    }

    public static func allProcesses() -> [Entry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride + 16
        var buf = [kinfo_proc](repeating: kinfo_proc(), count: count)
        size = count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &buf, &size, nil, 0) == 0 else { return [] }
        return buf.prefix(size / MemoryLayout<kinfo_proc>.stride).map(makeEntry)
    }

    private static func makeEntry(_ info: kinfo_proc) -> Entry {
        var p = info.kp_proc
        let comm = withUnsafePointer(to: &p.p_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
        let dev = info.kp_eproc.e_tdev
        var tty: String?
        if dev != -1, let name = devname(dev, S_IFCHR) {
            let s = String(cString: name)
            if s != "??" { tty = s }
        }
        let tv = info.kp_proc.p_un.__p_starttime
        let started = tv.tv_sec > 0 ? Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1e6) : nil
        return Entry(pid: info.kp_proc.p_pid, ppid: info.kp_eproc.e_ppid, comm: comm, tty: tty, started: started,
                     zombie: info.kp_proc.p_stat == SZOMB)
    }

    public static func executablePath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    public static func cwd(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    public static func isAlive(_ pid: pid_t) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    /// Which agent a process is, judged by its executable name.
    public static func agentKind(pid: pid_t, comm: String) -> AgentKind? {
        let name = executablePath(pid).map { ($0 as NSString).lastPathComponent } ?? comm
        switch name {
        case "claude", "claude.exe": return .claude
        case "codex": return .codex
        default: return nil
        }
    }

    /// Outermost `.app` bundle in an executable path:
    /// `/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/…` → `/Applications/Visual Studio Code.app`.
    public static func outerAppBundle(of path: String) -> String? {
        guard let r = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app") : nil) else { return nil }
        return String(path[..<r.upperBound]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .withLeadingSlash
    }

    public struct Ancestry: Sendable {
        public var agentPid: pid_t?
        public var tty: String?
        public var hostApp: String?
        public var hostKind: String?
        /// The agent runs inside tmux: the tmux server is its ancestor instead of a terminal app.
        public var inTmux = false
    }

    /// Walk up from `start` to find the agent process that spawned us and the app hosting it.
    public static func ancestry(from start: pid_t, agent: AgentKind?, env: [String: String]) -> Ancestry {
        var result = Ancestry()
        var pid = start
        var hops = 0
        while pid > 1, hops < 32, let e = entry(pid) {
            hops += 1
            if e.comm == "tmux" || e.comm.hasPrefix("tmux: ") { result.inTmux = true }
            if result.agentPid == nil, let kind = agentKind(pid: pid, comm: e.comm), agent == nil || kind == agent {
                result.agentPid = pid
                result.tty = e.tty
            }
            if let path = executablePath(pid), let app = outerAppBundle(of: path),
               !isAgentBundle(app) {
                result.hostApp = app // keep overwriting: the outermost ancestor wins
            }
            pid = e.ppid
        }
        if result.tty == nil { result.tty = entry(start)?.tty }
        // The tmux server is daemonized, so nothing above it names the terminal; the pane is found at click time.
        result.hostKind = result.inTmux && result.hostApp == nil ? "tmux"
            : hostKind(app: result.hostApp, termProgram: env["TERM_PROGRAM"] == "tmux" ? nil : env["TERM_PROGRAM"])
        if result.hostKind == nil, env["TMUX"] != nil { result.hostKind = "tmux" }
        if result.hostApp == nil, let kind = result.hostKind { result.hostApp = defaultAppPath(forKind: kind) }
        return result
    }

    /// Bundles that wrap an agent binary rather than host it: Claude desktop ships Claude Code as
    /// `…/Claude/claude-code/<version>/claude.app`. `/Applications/Claude.app` itself is a real host.
    private static func isAgentBundle(_ app: String) -> Bool {
        let name = (app as NSString).lastPathComponent.lowercased()
        return app.contains("/claude-code/") || app.contains("/claude-code-vm/") || name == "agenthud.app"
    }

    /// Whether an app whose main executable is `<bundle>/Contents/MacOS/<name>` is running.
    public static func isAppRunning(executableName name: String, bundleName: String) -> Bool {
        allProcesses().contains { e in
            e.comm == name && (executablePath(e.pid)?.hasSuffix("/\(bundleName)/Contents/MacOS/\(name)") ?? false)
        }
    }

    public static func hostKind(app: String?, termProgram: String?) -> String? {
        let name = app.map { ($0 as NSString).lastPathComponent.lowercased() } ?? ""
        if name.contains("visual studio code") { return "vscode" }
        if name.contains("cursor") { return "cursor" }
        if name.contains("windsurf") { return "windsurf" }
        if name.contains("iterm") { return "iterm" }
        if name == "terminal.app" { return "terminal" }
        if name.contains("ghostty") { return "ghostty" }
        if name.contains("warp") { return "warp" }
        if name.contains("wezterm") { return "wezterm" }
        if name == "claude.app" { return "claude-desktop" }
        if name.contains("chatgpt") { return "chatgpt" }
        if name == "codex.app" { return "codex-desktop" }
        switch termProgram {
        case "vscode": return "vscode"
        case "iTerm.app": return "iterm"
        case "Apple_Terminal": return "terminal"
        case "ghostty": return "ghostty"
        case "WarpTerminal": return "warp"
        case "WezTerm": return "wezterm"
        default: break
        }
        return name.isEmpty ? nil : (name as NSString).deletingPathExtension
    }

    public static func defaultAppPath(forKind kind: String) -> String? {
        let candidates: [String: String] = [
            "iterm": "/Applications/iTerm.app",
            "terminal": "/System/Applications/Utilities/Terminal.app",
            "ghostty": "/Applications/Ghostty.app",
            "vscode": "/Applications/Visual Studio Code.app",
            "warp": "/Applications/Warp.app",
            "wezterm": "/Applications/WezTerm.app",
            "claude-desktop": "/Applications/Claude.app",
            "chatgpt": "/Applications/ChatGPT.app",
        ]
        guard let p = candidates[kind], FileManager.default.fileExists(atPath: p) else { return nil }
        return p
    }
}

private extension String {
    var withLeadingSlash: String { hasPrefix("/") ? self : "/" + self }
}
