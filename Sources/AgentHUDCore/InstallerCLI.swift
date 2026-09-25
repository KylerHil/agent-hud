import Foundation

/// `agenthud-report install-hooks | uninstall-hooks | hooks-status [--claude] [--codex] [--dry-run] [--yes]`
public enum InstallerCLI {
    public static func run(command: String, args: [String]) -> Int32 {
        var targets = HookInstaller.Target.allCases.filter { args.contains("--\($0.rawValue)") }
        if targets.isEmpty { targets = HookInstaller.Target.allCases }
        let dryRun = args.contains("--dry-run")
        let yes = args.contains("--yes") || args.contains("-y")

        switch command {
        case "install-hooks": return change(targets, install: true, dryRun: dryRun, yes: yes)
        case "uninstall-hooks": return change(targets, install: false, dryRun: dryRun, yes: yes)
        case "hooks-status":
            for t in HookInstaller.Target.allCases {
                print("\(t.displayName): \(HookInstaller.isInstalled(t) ? "installed" : "not installed")  (\(t.file.path))")
            }
            let r = Paths.installedReporter
            print("Reporter: \(FileManager.default.isExecutableFile(atPath: r.path) ? r.path : "not installed")")
            return 0
        default:
            err("unknown command '\(command)'. Use install-hooks, uninstall-hooks or hooks-status.")
            return 64
        }
    }

    static func change(_ targets: [HookInstaller.Target], install: Bool, dryRun: Bool, yes: Bool) -> Int32 {
        var plans: [HookInstaller.Plan] = []
        for t in targets {
            do {
                let plan = try HookInstaller.plan(t, install: install)
                plan.warnings.forEach { print("⚠️  \($0)") }
                if plan.changed {
                    print("── \(t.displayName): \(plan.file.path)")
                    print(plan.diff)
                    plans.append(plan)
                } else {
                    print("── \(t.displayName): already \(install ? "installed" : "clean"), nothing to do.")
                }
            } catch {
                err("\(t.displayName): \(error.localizedDescription)")
                return 1
            }
        }
        if install, !dryRun {
            let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            do {
                if try HookInstaller.installReporter(from: me) { print("Installed reporter at \(Paths.installedReporter.path)") }
            } catch {
                err("could not install reporter: \(error.localizedDescription)")
                return 1
            }
        }
        guard !plans.isEmpty, !dryRun else { return 0 }
        if !yes {
            guard isatty(STDIN_FILENO) != 0 else {
                err("refusing to modify config without confirmation; re-run with --yes")
                return 1
            }
            print("Apply these changes? Backups go to \(Paths.backupsDir.path). [y/N] ", terminator: "")
            guard let answer = readLine(), ["y", "yes"].contains(answer.lowercased()) else {
                print("Cancelled; nothing changed.")
                return 1
            }
        }
        for plan in plans {
            do {
                let backups = try HookInstaller.apply(plan)
                print("✓ \(plan.target.displayName) updated." + (backups.isEmpty ? "" : " Backup: "
                      + backups.map(\.path).joined(separator: ", ")))
            } catch {
                err("\(plan.target.displayName): \(error.localizedDescription)")
                return 1
            }
        }
        if install, plans.contains(where: { $0.target == .codex }) {
            print("""

            Codex runs a new hook only after you trust it: open Codex (CLI or the VS Code extension), \
            run /hooks, and trust the AgentHUD entries. Until then AgentHUD falls back to Codex's session logs.
            """)
        }
        if install, plans.contains(where: { $0.target == .claude }) {
            print("Claude Code: new sessions use the hooks; restart already-running sessions if they don't show up.")
        }
        return 0
    }

    static func err(_ s: String) {
        FileHandle.standardError.write(Data("agenthud-report: \(s)\n".utf8))
    }
}
