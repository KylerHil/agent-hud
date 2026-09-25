import XCTest
@testable import AgentHUDCore

final class HookInstallerTests: XCTestCase {
    var home: URL!

    override func setUp() {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("aw-home-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        setenv("AGENTHUD_USER_HOME", home.path, 1)
        setenv("AGENTHUD_HOME", home.appendingPathComponent(".agenthud").path, 1)
    }

    override func tearDown() {
        unsetenv("AGENTHUD_USER_HOME")
        unsetenv("AGENTHUD_HOME")
        try? FileManager.default.removeItem(at: home)
    }

    let existing = """
    {
      "theme": "dark",
      "hooks": {
        "PreToolUse": [
          {
            "matcher": "Bash",
            "hooks": [
              {
                "type": "command",
                "command": "my-guard.sh"
              }
            ]
          }
        ]
      },
      "enabledPlugins": {
        "a": true
      }
    }

    """

    func json(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    func testClaudeInstallMergesIsIdempotentAndUninstallRestores() throws {
        let file = Paths.claudeSettings
        try existing.write(to: file, atomically: true, encoding: .utf8)

        let plan = try HookInstaller.plan(.claude, install: true, reporter: "/r/agenthud-report")
        XCTAssertTrue(plan.changed)
        XCTAssertTrue(plan.diff.contains("+"))
        let backups = try HookInstaller.apply(plan)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try String(contentsOf: backups[0], encoding: .utf8), existing)

        let obj = try json(file)
        XCTAssertEqual(obj["theme"] as? String, "dark")
        let hooks = obj["hooks"] as! [String: [[String: Any]]]
        XCTAssertEqual(Set(hooks.keys), Set(HookInstaller.Target.claude.events))
        XCTAssertEqual(hooks["PreToolUse"]?.count, 2, "user's Bash guard kept, ours appended")
        XCTAssertEqual((hooks["PreToolUse"]?[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String, "my-guard.sh")
        let ours = (hooks["Stop"]?[0]["hooks"] as? [[String: Any]])?.first
        XCTAssertEqual(ours?["command"] as? String, "'/r/agenthud-report' --agent claude")
        XCTAssertEqual(ours?["async"] as? Bool, true)
        // Key order preserved: theme, hooks, enabledPlugins.
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertLessThan(text.range(of: "\"theme\"")!.lowerBound, text.range(of: "\"enabledPlugins\"")!.lowerBound)

        XCTAssertFalse(try HookInstaller.plan(.claude, install: true, reporter: "/r/agenthud-report").changed,
                       "second install is a no-op")

        try HookInstaller.apply(try HookInstaller.plan(.claude, install: false))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), existing, "uninstall restores the original byte-for-byte")
        XCTAssertFalse(try HookInstaller.plan(.claude, install: false).changed)
    }

    func testClaudeInstallWithNoHooksKeyAndUninstallRemovesIt() throws {
        let original = "{\n  \"theme\": \"dark\"\n}\n"
        try original.write(to: Paths.claudeSettings, atomically: true, encoding: .utf8)
        try HookInstaller.apply(try HookInstaller.plan(.claude, install: true, reporter: "/r/agenthud-report"))
        XCTAssertTrue(HookInstaller.isInstalled(.claude))
        try HookInstaller.apply(try HookInstaller.plan(.claude, install: false))
        XCTAssertEqual(try String(contentsOf: Paths.claudeSettings, encoding: .utf8), original)
    }

    func testCodexCreatesAndRemovesHooksJSON() throws {
        try "model = \"x\"\nnotify = [\"foo\"]\n".write(to: Paths.codexConfig, atomically: true, encoding: .utf8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.codexHooks.path))
        let plan = try HookInstaller.plan(.codex, install: true, reporter: "/r/agenthud-report")
        let backups = try HookInstaller.apply(plan)
        XCTAssertEqual(backups.map(\.lastPathComponent).filter { $0.hasPrefix("codex-config.toml") }.count, 1)
        let hooks = try json(Paths.codexHooks)["hooks"] as! [String: Any]
        XCTAssertEqual(Set(hooks.keys), Set(HookInstaller.Target.codex.events))
        XCTAssertEqual(try String(contentsOf: Paths.codexConfig, encoding: .utf8), "model = \"x\"\nnotify = [\"foo\"]\n",
                       "config.toml untouched")
        try HookInstaller.apply(try HookInstaller.plan(.codex, install: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.codexHooks.path))
    }

    func testCodexRefusesWhenConfigHasInlineHooks() throws {
        try "[[hooks.Stop]]\nmatcher = \"\"\n".write(to: Paths.codexConfig, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try HookInstaller.plan(.codex, install: true))
    }

    func testUninstallWhenFileMissingIsNoop() throws {
        XCTAssertFalse(try HookInstaller.plan(.claude, install: false).changed)
        XCTAssertFalse(try HookInstaller.plan(.codex, install: false).changed)
    }

    /// Hooks from before the rename (AgentWatch's reporter) are replaced, not duplicated, on install.
    func testInstallReplacesLegacyAgentWatchHooks() throws {
        let file = Paths.claudeSettings
        let legacy = """
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"'/u/.agentwatch/bin/agentwatch-report' --agent claude","async":true}]}]}}
        """
        try legacy.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(HookInstaller.hasLegacyHooks(.claude))
        XCTAssertFalse(HookInstaller.isInstalled(.claude))
        try HookInstaller.apply(try HookInstaller.plan(.claude, install: true, reporter: "/r/agenthud-report"))
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("agentwatch-report"))
        XCTAssertTrue(HookInstaller.isInstalled(.claude))
        let stop = ((try json(file)["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]) ?? []
        XCTAssertEqual(stop.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }.count, 1)
    }
}
