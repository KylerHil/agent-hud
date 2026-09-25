import AgentHUDCore
import AppKit

/// Starts a new agent session in a project, or resumes an old one, in the app you use for it.
/// VS Code (and Cursor, Windsurf) get the Claude extension's own link, so the conversation opens in the
/// editor; terminals get a new window running `claude` in the project folder.
enum Launcher {
    /// Where new sessions open. `automatic` picks the app you last used for that project.
    enum Host: String, CaseIterable, Identifiable {
        case automatic, vscode, cursor, terminal, iterm, wezterm, ghostty
        var id: String { rawValue }

        var title: String {
            switch self {
            case .automatic: "Where I last used the project"
            case .vscode: "VS Code"
            case .cursor: "Cursor"
            case .terminal: "Terminal"
            case .iterm: "iTerm2"
            case .wezterm: "WezTerm"
            case .ghostty: "Ghostty"
            }
        }

        var isEditor: Bool { self == .vscode || self == .cursor }

        var bundleID: String {
            switch self {
            case .automatic, .terminal: "com.apple.Terminal"
            case .vscode: "com.microsoft.VSCode"
            case .cursor: "com.todesktop.230313mzl4w4u92"
            case .iterm: "com.googlecode.iterm2"
            case .wezterm: "com.github.wez.wezterm"
            case .ghostty: "com.mitchellh.ghostty"
            }
        }

        var isInstalled: Bool { self == .automatic || NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }

        /// A session's recorded host (`vscode`, `iterm`, `tmux`…) as somewhere to open a new one.
        init?(hostKind: String?) {
            switch hostKind {
            case "vscode": self = .vscode
            case "cursor": self = .cursor
            case "terminal", "tmux": self = .terminal
            case "iterm": self = .iterm
            case "wezterm": self = .wezterm
            case "ghostty": self = .ghostty
            default: return nil
            }
        }

        /// Claude's transcript `entrypoint`: `claude-vscode` ran in an editor, `cli` in a terminal.
        init?(entrypoint: String?) {
            switch entrypoint {
            case "claude-vscode": self = .vscode
            case "cli": self = .terminal
            default: return nil
            }
        }
    }

    /// Opens `agent` in `dir`, resuming `sessionId` when given. `terminal` is used when `host` is an editor
    /// that can't run this agent (Codex has no editor link).
    static func open(agent: AgentKind, dir: String, sessionId: String?, host: Host, terminal: Host) {
        var host = host == .automatic ? terminal : host
        if host.isEditor && agent != .claude { host = terminal }
        if !host.isInstalled { host = .terminal }
        Focuser.note("launch \(agent.rawValue) in \(dir) via \(host.rawValue)\(sessionId.map { " resuming \($0)" } ?? "")")
        if host.isEditor {
            openInEditor(host, dir: dir, sessionId: sessionId)
            return
        }
        let command = shellCommand(agent: agent, sessionId: sessionId)
        switch host {
        case .iterm:
            runScript("""
                tell application "iTerm"
                    activate
                    set w to (create window with default profile)
                    tell current session of w to write text "\(appleScriptEscape("cd \(quote(dir)) && \(command)"))"
                end tell
                """)
        case .wezterm:
            spawnWezTerm(dir: dir, command: command)
        case .ghostty:
            let shell = userShell
            run("/usr/bin/open", ["-na", "Ghostty", "--args", "--working-directory=\(dir)", "-e", shell, "-lic",
                                  "\(command); exec \(shell) -l"])
        default:
            runScript("""
                tell application "Terminal"
                    activate
                    do script "\(appleScriptEscape("cd \(quote(dir)) && \(command)"))"
                end tell
                """)
        }
    }

    static func shellCommand(agent: AgentKind, sessionId: String?) -> String {
        switch agent {
        case .codex: sessionId.map { "codex resume \($0)" } ?? "codex"
        default: sessionId.map { "claude --resume \($0)" } ?? "claude"
        }
    }

    /// Focuses (or opens) the editor window for `dir`, then hands the Claude extension its link, which the
    /// now-front window handles: a new conversation, or `?session=` to reopen one.
    private static func openInEditor(_ host: Host, dir: String, sessionId: String?) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: host.bundleID) else { return }
        var target = URL(fileURLWithPath: dir)
        if let file = EditorWindows.storageFile(appPath: app.path), let data = try? Data(contentsOf: file),
           let open = EditorWindows.target(storage: data, containing: dir) {
            target = open // the window already showing this folder, not a new one
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let scheme = host == .cursor ? "cursor" : "vscode"
        var link = "\(scheme)://anthropic.claude-code/open"
        if let sessionId { link += "?session=\(sessionId)" }
        // Sent once: a moment after the editor confirms the folder opened (so its window is the one in front
        // to get the link), or after 2.5 s regardless. VS Code sometimes never confirms, for instance while it's
        // still busy opening another folder, and waiting for it meant no conversation at all.
        var sent = false
        func send(after delay: Double) {
            guard !sent else { return }
            sent = true
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Focuser.note("editor link \(link)")
                if let url = URL(string: link) { NSWorkspace.shared.open(url) }
            }
        }
        NSWorkspace.shared.open([target], withApplicationAt: app, configuration: config) { _, error in
            DispatchQueue.main.async {
                if let error { Focuser.note("editor open: \(error.localizedDescription)") }
                send(after: 1.2)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { send(after: 0) }
    }

    /// `wezterm start` opens a window in the running WezTerm (or starts it), with the command in a login
    /// shell that stays open after the agent exits.
    private static func spawnWezTerm(dir: String, command: String) {
        guard let bin = WezTerm.binary else {
            run("/usr/bin/open", ["-a", "WezTerm"])
            return
        }
        let shell = userShell
        run(bin, ["start", "--cwd", dir, "--", shell, "-lic", "\(command); exec \(shell) -l"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSRunningApplication.runningApplications(withBundleIdentifier: Host.wezterm.bundleID).first?.activate()
        }
    }

    private static var userShell: String {
        ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
    }

    static func quote(_ s: String) -> String {
        s.allSatisfy { $0.isLetter || $0.isNumber || "/._-~".contains($0) } ? s
            : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func run(_ bin: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { Focuser.note("launch failed: \(error.localizedDescription)") }
    }

    private static func runScript(_ source: String) {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            Focuser.note("launch AppleScript failed: \(error[NSAppleScript.errorMessage] ?? error)")
            if (error[NSAppleScript.errorNumber] as? Int) == -1743 {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
            }
        }
    }
}
