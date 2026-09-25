import AgentHUDCore
import AppKit
import ServiceManagement
import SwiftUI

/// Settings, shown inside the panel (which grows for it) rather than in a window of their own.
struct PanelSettingsView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { model.mode = .list } label: {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Back to sessions")
                .accessibilityLabel("Back to sessions")
                Text("Settings").font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize()
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            // The tabs get a row of their own, so the title never has to squeeze in beside them.
            Picker("Section", selection: Binding(get: { model.settingsTab }, set: { model.settingsTab = $0 })) {
                Text("General").tag(SettingsTab.general)
                Text("Sources").tag(SettingsTab.sources)
                Text("Notifications").tag(SettingsTab.notifications)
                Text("Permissions").tag(SettingsTab.permissions)
                Text("Hooks").tag(SettingsTab.hooks)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 8)
            Divider().opacity(0.5)
            SettingsView(model: model, settings: model.settings)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct SettingsView: View {
    let model: AppModel
    @Bindable var settings: AppSettings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        switch model.settingsTab {
        case .general: general
        case .sources: SourcesPane(model: model, settings: settings)
        case .notifications: notifications
        case .permissions: PermissionsPane(model: model, settings: settings)
        case .hooks: Form { Section("Hooks") { HooksPane(onChange: { model.refreshLegacyHooks() }) } }.formStyle(.grouped)
        }
    }

    private var general: some View {
        Form {
            Section("Panel") {
                LabeledContent("Opacity") {
                    Slider(value: $settings.opacity, in: 0.3...1) { Text("Opacity") }
                        .labelsHidden()
                        .frame(width: 180)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Toggle("Group sessions by project", isOn: $settings.groupByProject)
                    Text("One row per project, showing its most urgent session and a colored dot for each session. Projects start collapsed: click to jump to that session, or ▸ to see the rest.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Show idle sessions", isOn: $settings.showIdle)
                VStack(alignment: .leading, spacing: 3) {
                    Picker("Menu bar pill", selection: $settings.pillDetail) {
                        ForEach(PillDetail.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Text("Collapsing the panel puts it in the menu bar, beside the dots. Icon only is a capsule colored by the most urgent session; Full adds who needs you or what an agent is doing; Compact shows just the name. On a notched MacBook a wide pill can disappear behind the notch.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Toggle("Show how full each session's context is", isOn: $settings.showContextGauge)
                    Text("A small ring on each row. It turns orange past 80%, before the agent compacts the conversation.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Picker("Claude context window", selection: $settings.claudeContextWindow) {
                    Text("Automatic").tag(0)
                    Text("200K tokens").tag(200_000)
                    Text("1M tokens").tag(1_000_000)
                }
                .disabled(!settings.showContextGauge)
                .help("Transcripts don't record the window size. Automatic assumes 200K until a session uses more than that.")
                Toggle("Pulse when a session needs input", isOn: $settings.pulse)
                Stepper("Mark running sessions stale after \(Int(settings.staleMinutes)) min",
                        value: $settings.staleMinutes, in: 2...120, step: 1)
                Stepper("Keep ended sessions for \(Int(settings.endedRetentionMinutes)) min",
                        value: $settings.endedRetentionMinutes, in: 0...60, step: 1)
            }
            Section {
                Toggle("Terminals", isOn: $settings.showTerminalSessions)
                    .help("Terminal, iTerm2, Ghostty, Warp and WezTerm")
                Toggle("tmux", isOn: $settings.showTmuxSessions)
                Toggle("Editors", isOn: $settings.showEditorSessions)
                    .help("VS Code, Cursor and Windsurf")
                Toggle("Desktop apps", isOn: $settings.showAppSessions)
                    .help("The Claude, ChatGPT and Codex apps")
            } header: {
                Text("Show sessions from")
            } footer: {
                Text("Hidden sessions don't appear in the panel or menu bar and don't notify you.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Start new sessions in", selection: $settings.launchHost) {
                    ForEach(Launcher.Host.allCases.filter(\.isInstalled)) { Text($0.title).tag($0.rawValue) }
                }
            } header: {
                Text("Find and start")
            } footer: {
                Text("Type a project name in the finder (\(settings.findShortcut.display)) to start a new Claude session there, or to resume an earlier conversation by its title.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Updates") {
                UpdatesSection(updater: model.updater, settings: settings)
            }
            Section("Shortcuts") {
                Toggle("Global shortcuts", isOn: $settings.hotkeysEnabled)
                LabeledContent("Find and jump to a session") {
                    ShortcutRecorder(model: model, shortcut: $settings.findShortcut, fallback: .findDefault)
                }
                .disabled(!settings.hotkeysEnabled)
                LabeledContent("Show or hide the panel") {
                    ShortcutRecorder(model: model, shortcut: $settings.panelShortcut, fallback: .panelDefault)
                }
                .disabled(!settings.hotkeysEnabled)
                LabeledContent("Collapse to pill or expand") {
                    ShortcutRecorder(model: model, shortcut: $settings.collapseShortcut, fallback: .collapseDefault)
                }
                .disabled(!settings.hotkeysEnabled)
            }
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Toggle("Detect agent processes (liveness, sessions without hooks)", isOn: $settings.trackProcesses)
            }
        }
        .formStyle(.grouped)
    }

    private var notifications: some View {
        Form {
            Section("Notifications") {
                Toggle("Notify when a session needs input", isOn: $settings.notifyNeedsInput)
                Toggle("Notify when a session finishes its turn", isOn: $settings.notifyFinished)
                Picker("Only for turns that took at least", selection: $settings.finishedMinMinutes) {
                    Text("Any length").tag(0.0)
                    Text("1 min").tag(1.0)
                    Text("2 min").tag(2.0)
                    Text("5 min").tag(5.0)
                    Text("10 min").tag(10.0)
                }
                .disabled(!settings.notifyFinished)
                .help("The banner says how long it took, what it edited and ran, and whether its tests passed")
                Toggle("Play sound", isOn: $settings.playSound)
                Picker("Remind again while waiting", selection: $settings.remindMinutes) {
                    Text("Never").tag(0.0)
                    Text("Every 2 min").tag(2.0)
                    Text("Every 5 min").tag(5.0)
                    Text("Every 10 min").tag(10.0)
                    Text("Every 15 min").tag(15.0)
                }
                .disabled(!settings.notifyNeedsInput)
            }
            Section {
                if settings.notificationsPaused {
                    LabeledContent("Paused until \(Date(timeIntervalSince1970: settings.pausedUntil).formatted(date: .omitted, time: .shortened))") {
                        Button("Resume") { settings.pausedUntil = 0 }
                    }
                } else {
                    LabeledContent("Pause all notifications") {
                        Button("1 Hour") { settings.pausedUntil = Date().addingTimeInterval(3600).timeIntervalSince1970 }
                    }
                }
            } footer: {
                Text("Banners offer Show, Snooze and Mute Session. Answer the agent's prompt in the agent itself.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// Where AgentHUD looks for sessions, with a live status line for each.
struct SourcesPane: View {
    let model: AppModel
    @Bindable var settings: AppSettings
    @State private var claudeHooks = false
    @State private var codexHooks = false
    @State private var axTrusted = ChatWatcher.isTrusted

    var body: some View {
        Form {
            Section {
                source("Claude Code in terminals and editors", tag: "HOOKS",
                       detail: "Terminal, iTerm2, Ghostty, VS Code, Cursor. Full state, including permission prompts.",
                       status: claudeHooks ? "Hooks installed · \(live { $0.agent == .claude && !$0.isDesktop && !$0.isChat })"
                           : "Hooks not installed: see the Hooks tab", ok: claudeHooks, isOn: nil)
                source("Claude desktop app", tag: "CODE TAB",
                       detail: "Code sessions in Claude.app. Titles and running or idle come from its session files; "
                           + "with hooks installed, permission prompts show too. Jump brings Claude forward.",
                       status: appStatus("/Applications/Claude.app", count: live { $0.hostKind == "claude-desktop" && !$0.isChat }),
                       ok: FileManager.default.fileExists(atPath: "/Applications/Claude.app"), isOn: $settings.watchClaudeDesktop)
                source("Codex CLI and IDE extension", tag: "HOOKS",
                       detail: "Falls back to ~/.codex/sessions logs until the hooks are trusted in Codex's /hooks.",
                       status: (codexHooks ? "Hooks installed" : "Rollout logs only") + " · \(live { $0.agent == .codex && !$0.isDesktop })",
                       ok: codexHooks, isOn: nil)
                source("ChatGPT desktop app (Codex)", tag: "CODEX",
                       detail: "ChatGPT.app runs codex with the same ~/.codex, so its tasks show up like any Codex session. "
                           + "Approvals are only visible once the Codex hooks are trusted.",
                       status: appStatus("/Applications/ChatGPT.app", count: live { $0.hostKind == "chatgpt" && !$0.isChat }),
                       ok: FileManager.default.fileExists(atPath: "/Applications/ChatGPT.app"), isOn: $settings.watchChatGPT)
            } header: {
                Text("Where Agent HUD looks for sessions. Everything stays on this Mac.")
            }
            Section {
                if Paths.isSandboxed {
                    Text("Watching ordinary chats needs Accessibility, which App Store apps can't use. It's available in the direct-download build.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                } else {
                source("Chats in Claude and ChatGPT", tag: "EXPERIMENTAL",
                       detail: "Reads the apps' windows through Accessibility to show Responding… and Reply ready "
                           + "for ordinary chats. Only window titles and the Stop button are read; no message text is stored.",
                       status: !axTrusted ? "Needs Accessibility permission"
                           : settings.watchChats ? "Watching · \(live { $0.isChat })" : "Off",
                       ok: axTrusted, isOn: $settings.watchChats)
                if settings.watchChats && !axTrusted {
                    Button("Grant Accessibility Access…") { ChatWatcher.requestAccess() }
                }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            claudeHooks = HookInstaller.isInstalled(.claude)
            codexHooks = HookInstaller.isInstalled(.codex)
        }
        .task {
            // Accessibility is granted in System Settings, so notice it without a relaunch.
            while !Task.isCancelled {
                axTrusted = ChatWatcher.isTrusted
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func live(_ match: (Session) -> Bool) -> String {
        let n = model.store.sessions.values.filter { $0.state != .ended && match($0) }.count
        return n == 1 ? "1 live session" : "\(n) live sessions"
    }

    private func appStatus(_ path: String, count: String) -> String {
        FileManager.default.fileExists(atPath: path) ? "Installed · \(count)" : "Not installed"
    }

    private func source(_ title: String, tag: String, detail: String, status: String, ok: Bool,
                        isOn: Binding<Bool>?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(tag)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(tag == "EXPERIMENTAL" ? Color.orange : .secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background((tag == "EXPERIMENTAL" ? Color.orange : Color.primary).opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 4))
                }
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Label(status, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(ok ? Color.green : .orange)
            }
            Spacer(minLength: 8)
            if let isOn {
                Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch)
            } else {
                Text("Always on").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct UpdatesSection: View {
    let updater: Updater
    @Bindable var settings: AppSettings

    var body: some View {
        LabeledContent("Agent HUD \(Updater.currentVersion)") {
            HStack(spacing: 8) {
                statusText
                switch updater.status {
                case .available(let r):
                    Button(updater.viaHomebrew ? "Update to \(r.version)" : "Download \(r.version)") { updater.install() }
                        .buttonStyle(.borderedProminent)
                case .installing, .checking:
                    ProgressView().controlSize(.small)
                default:
                    Button("Check Now") { updater.check() }
                }
            }
        }
        Toggle("Check for updates daily", isOn: $settings.checkForUpdates)
        Toggle("Install updates automatically", isOn: $settings.installUpdatesAutomatically)
            .disabled(!settings.checkForUpdates || !updater.viaHomebrew)
            .help(updater.viaHomebrew ? "Runs brew upgrade in the background when no session is waiting on you, then relaunches"
                  : "Available when installed with Homebrew")
    }

    @ViewBuilder
    private var statusText: some View {
        switch updater.status {
        case .idle: EmptyView()
        case .checking: Text("Checking…").foregroundStyle(.secondary)
        case .upToDate: Text("Up to date").foregroundStyle(.secondary)
        case .available: Text("New version").foregroundStyle(.orange)
        case .installing: Text("Updating; Agent HUD will restart").foregroundStyle(.secondary)
        case .failed(let msg): Text(msg).foregroundStyle(.red).lineLimit(1).help(msg)
        }
    }
}

/// Commands you keep approving, as allow rules for the project. Nothing is added without a click, and the
/// change is shown first.
struct PermissionsPane: View {
    let model: AppModel
    @Bindable var settings: AppSettings
    @State private var previewing: String?
    @State private var message: (text: String, ok: Bool)?

    var body: some View {
        Form {
            Section {
                if let m = message {
                    Label(m.text, systemImage: m.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5)).foregroundStyle(m.ok ? Color.green : .red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.suggestions.isEmpty {
                    Text("Nothing to suggest yet. When you approve the same command in a project at least 3 times in two weeks, it shows up here.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(model.suggestions) { row($0) }
                }
            } header: {
                Text("Commands you keep approving. Allowing one lets Claude run it in that project without asking.")
            } footer: {
                Text("Rules go in the project's .claude/settings.local.json, your personal settings that aren't committed. The previous file is backed up to ~/.agenthud/backups. You still answer every other prompt in the agent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !settings.dismissedSuggestions.isEmpty {
                Section {
                    Button("Show \(settings.dismissedSuggestions.count) dismissed suggestion\(settings.dismissedSuggestions.count == 1 ? "" : "s") again") {
                        settings.dismissedSuggestions = []
                        model.refreshSuggestions()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshSuggestions() }
    }

    private func row(_ s: PermissionSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(s.label).font(.system(size: 12.5, weight: .semibold, design: .monospaced)).lineLimit(1)
                Text("in \(s.project)").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 6)
                Text("approved \(s.count)×").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    .help("Last approved \(s.last.formatted(.relative(presentation: .named)))")
            }
            if !s.examples.isEmpty {
                Text(s.examples.joined(separator: "\n"))
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(3).truncationMode(.tail)
            }
            if previewing == s.id {
                preview(s)
            }
            HStack(spacing: 8) {
                Button(previewing == s.id ? "Hide change" : "Preview change") {
                    previewing = previewing == s.id ? nil : s.id
                }
                .buttonStyle(.link)
                .font(.system(size: 11.5))
                Spacer()
                Button("Dismiss") { model.dismissSuggestion(s) }
                    .controlSize(.small)
                Button("Allow \(s.rule)") { add(s) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .lineLimit(1)
                    .help("Adds \(s.rule) to \(PermissionRules.localSettings(root: s.root).path)")
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func preview(_ s: PermissionSuggestion) -> some View {
        if let plan = try? PermissionRules.plan(adding: s.rule, root: s.root) {
            ScrollView(.horizontal) {
                Text(plan.diff.isEmpty ? "No change" : plan.diff)
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(maxHeight: 180)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        } else {
            Text("Couldn't read \(PermissionRules.localSettings(root: s.root).path).").font(.caption).foregroundStyle(.red)
        }
    }

    private func add(_ s: PermissionSuggestion) {
        do {
            try model.accept(s)
            previewing = nil
            message = ("Allowed \(s.rule) in \(s.project). If a session that's already running still asks, restart it.", true)
        } catch {
            message = (error.localizedDescription, false)
        }
    }
}
