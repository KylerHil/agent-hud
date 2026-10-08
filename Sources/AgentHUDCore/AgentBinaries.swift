import Foundation

/// Where the `claude` and `codex` executables are, and the environment to run them in. An app opened
/// from Finder gets launchd's bare PATH, so agents started by the broker take the user's login-shell
/// environment instead: that's what finds `node`, `pnpm` and the rest when they run commands.
public enum AgentBinaries {
    /// The login shell's environment, read once. Falls back to this process's environment.
    public static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        let shell = env["SHELL"].flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil } ?? "/bin/zsh"
        if let out = run(shell, ["-l", "-c", "env -0"], timeout: 8) {
            for entry in out.split(separator: "\0") {
                guard let eq = entry.firstIndex(of: "=") else { continue }
                env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
            }
        }
        // Nothing an agent runs should think it's inside Agent HUD's own process.
        for key in ["__CFBundleIdentifier", "XPC_SERVICE_NAME"] { env[key] = nil }
        return env
    }()

    public static func claude() -> String? {
        find("claude", extra: [Paths.userHome.appendingPathComponent(".local/bin/claude").path,
                               Paths.userHome.appendingPathComponent(".claude/local/claude").path,
                               "/opt/homebrew/bin/claude", "/usr/local/bin/claude"])
    }

    /// `codex` on PATH, else the newest copy bundled with the VS Code extension, else ChatGPT.app's.
    public static func codex() -> String? {
        if let p = find("codex", extra: ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]) { return p }
        let fm = FileManager.default
        for base in [".vscode/extensions", ".cursor/extensions", ".windsurf/extensions"] {
            let dir = Paths.userHome.appendingPathComponent(base)
            let candidates = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.hasPrefix("openai.chatgpt-") }
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            for ext in candidates {
                let bin = dir.appendingPathComponent(ext).appendingPathComponent("bin")
                for arch in (try? fm.contentsOfDirectory(atPath: bin.path)) ?? [] {
                    let p = bin.appendingPathComponent(arch).appendingPathComponent("codex").path
                    if fm.isExecutableFile(atPath: p) { return p }
                }
            }
        }
        let app = "/Applications/ChatGPT.app/Contents/Resources/codex"
        return fm.isExecutableFile(atPath: app) ? app : nil
    }

    public static func path(for agent: AgentKind) -> String? {
        switch agent {
        case .claude: claude()
        case .codex: codex()
        case .chatgpt: nil
        }
    }

    private static func find(_ name: String, extra: [String]) -> String? {
        let dirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for d in dirs {
            let p = (d as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return extra.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs a command and returns its stdout, or nil if it fails or takes longer than `timeout` seconds.
    @discardableResult
    public static func run(_ exe: String, _ args: [String], cwd: String? = nil, env: [String: String]? = nil,
                           timeout: TimeInterval = 30) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if let env { p.environment = env }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // Read while it runs, so a large output can't fill the pipe and stall it.
        var data = Data()
        let reader = DispatchQueue(label: "agenthud.run.read")
        let done = DispatchSemaphore(value: 0)
        reader.async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return nil
        }
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
