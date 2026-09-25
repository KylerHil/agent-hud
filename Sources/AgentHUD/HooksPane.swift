import SwiftUI
import AgentHUDCore

/// Hook install status plus Install/Uninstall, always previewing the exact diff first (inline, in the panel).
struct HooksPane: View {
    var onChange: () -> Void = {}
    @State private var installed: [HookInstaller.Target: Bool] = [:]
    @State private var legacy: [HookInstaller.Target: Bool] = [:]
    @State private var pending: [HookInstaller.Plan] = []
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(HookInstaller.Target.allCases, id: \.self) { t in
                HStack {
                    Image(systemName: installed[t] == true ? "checkmark.circle.fill"
                          : legacy[t] == true ? "arrow.triangle.2.circlepath" : "circle.dashed")
                        .foregroundStyle(installed[t] == true ? .green : legacy[t] == true ? .orange : .secondary)
                    VStack(alignment: .leading) {
                        Text(t.displayName)
                        Text(legacy[t] == true && installed[t] != true ? "Uses the old AgentWatch reporter: install to update"
                             : t.file.path)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            if pending.isEmpty {
                HStack {
                    Button(legacy.values.contains(true) ? "Update Hooks…" : "Install Hooks…") { preview(install: true) }
                    Button("Uninstall Hooks…") { preview(install: false) }
                }
            } else {
                diff
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .onAppear(perform: refresh)
    }

    private var diff: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(pending.first?.install == true ? "Install Agent HUD hooks" : "Remove Agent HUD hooks").font(.headline)
            Text("Backups are written to \(Paths.backupsDir.path) before anything changes.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(pending, id: \.target) { plan in
                        ForEach(plan.warnings, id: \.self) { Text("⚠︎ \($0)").font(.caption) }
                        Text(plan.diff)
                            .font(.system(size: 10.5, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .frame(height: 240)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                Button("Cancel") { pending = [] }
                Button("Apply") { apply() }.buttonStyle(.borderedProminent)
            }
        }
    }

    private func refresh() {
        for t in HookInstaller.Target.allCases {
            installed[t] = HookInstaller.isInstalled(t)
            legacy[t] = HookInstaller.hasLegacyHooks(t)
        }
    }

    private func preview(install: Bool) {
        do {
            pending = try HookInstaller.Target.allCases.map { try HookInstaller.plan($0, install: install) }
                .filter(\.changed)
            if pending.isEmpty { message = install ? "Hooks are already installed." : "No Agent HUD hooks to remove." }
        } catch {
            message = error.localizedDescription
        }
    }

    private func apply() {
        do {
            // Sandboxed builds point hooks at the reporter inside the app instead of copying it out.
            if pending.first?.install == true, !Paths.isSandboxed {
                let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/agenthud-report")
                try HookInstaller.installReporter(from: bundled)
            }
            var backups: [URL] = []
            for plan in pending { backups += try HookInstaller.apply(plan) }
            let codex = pending.contains { $0.target == .codex && $0.install }
            message = "Done." + (backups.isEmpty ? "" : " Backups: " + backups.map(\.lastPathComponent).joined(separator: ", "))
                + (codex ? "\nIn Codex, run /hooks and trust the Agent HUD entries." : "")
        } catch {
            message = error.localizedDescription
        }
        pending = []
        refresh()
        onChange()
    }
}
