import AgentWatchCore
import SwiftUI

/// Hook install status plus Install/Uninstall, always previewing the exact diff first.
struct HooksPane: View {
    @State private var installed: [HookInstaller.Target: Bool] = [:]
    @State private var pending: [HookInstaller.Plan] = []
    @State private var showingDiff = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(HookInstaller.Target.allCases, id: \.self) { t in
                HStack {
                    Image(systemName: installed[t] == true ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(installed[t] == true ? .green : .secondary)
                    VStack(alignment: .leading) {
                        Text(t.displayName)
                        Text(t.file.path).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            HStack {
                Button("Install Hooks…") { preview(install: true) }
                Button("Uninstall Hooks…") { preview(install: false) }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .onAppear(perform: refresh)
        .sheet(isPresented: $showingDiff) { diffSheet }
    }

    private var diffSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(pending.first?.install == true ? "Install AgentWatch hooks" : "Remove AgentWatch hooks")
                .font(.headline)
            Text("Backups are written to \(Paths.backupsDir.path) before anything changes.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(pending, id: \.target) { plan in
                        ForEach(plan.warnings, id: \.self) { Text("⚠️ \($0)").font(.caption) }
                        Text(plan.diff)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .frame(width: 640, height: 420)
            .background(Color(nsColor: .textBackgroundColor))
            HStack {
                Spacer()
                Button("Cancel") { showingDiff = false }.keyboardShortcut(.cancelAction)
                Button("Apply") { apply() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private func refresh() {
        for t in HookInstaller.Target.allCases { installed[t] = HookInstaller.isInstalled(t) }
    }

    private func preview(install: Bool) {
        do {
            pending = try HookInstaller.Target.allCases.map { try HookInstaller.plan($0, install: install) }
                .filter(\.changed)
            if pending.isEmpty {
                message = install ? "Hooks are already installed." : "No AgentWatch hooks to remove."
            } else {
                showingDiff = true
            }
        } catch {
            message = error.localizedDescription
        }
    }

    private func apply() {
        showingDiff = false
        do {
            if pending.first?.install == true {
                let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/agentwatch-report")
                try HookInstaller.installReporter(from: bundled)
            }
            var backups: [URL] = []
            for plan in pending { backups += try HookInstaller.apply(plan) }
            let codex = pending.contains { $0.target == .codex && $0.install }
            message = "Done." + (backups.isEmpty ? "" : " Backups: " + backups.map(\.lastPathComponent).joined(separator: ", "))
                + (codex ? "\nIn Codex, run /hooks and trust the AgentWatch entries." : "")
        } catch {
            message = error.localizedDescription
        }
        pending = []
        refresh()
    }
}
