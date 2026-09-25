import Foundation
import AgentHUDCore

/// Carries an AgentWatch install over to AgentHUD: the data folder and the saved settings.
/// Hooks are left alone until you update them (the panel shows a banner), since editing
/// ~/.claude/settings.json always goes through the diff preview.
enum Migration {
    /// Hooks run the copy of the reporter in ~/.agenthud/bin, which app updates don't touch. Replace it with
    /// this version's whenever they differ, so a `brew upgrade` updates what the hooks run too.
    static func refreshReporter() {
        guard !Paths.isSandboxed, FileManager.default.fileExists(atPath: Paths.installedReporter.path) else { return }
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/agenthud-report")
        guard FileManager.default.fileExists(atPath: bundled.path) else { return }
        _ = try? HookInstaller.installReporter(from: bundled)
    }

    static let legacyDefaults = "local.agentwatch.AgentWatch"

    static func run() {
        Paths.migrateLegacyHome()
        refreshReporter()
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromAgentWatch") else { return }
        defaults.set(true, forKey: "migratedFromAgentWatch")
        // Sandboxed builds can't read another app's preferences; they simply start fresh.
        guard let old = defaults.persistentDomain(forName: legacyDefaults) else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }
}
