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
                Text("Settings").font(.system(size: 13, weight: .semibold))
                Spacer()
                Picker("Section", selection: Binding(get: { model.settingsTab }, set: { model.settingsTab = $0 })) {
                    Text("General").tag(SettingsTab.general)
                    Text("Sources").tag(SettingsTab.sources)
                    Text("Notifications").tag(SettingsTab.notifications)
                    Text("Hooks").tag(SettingsTab.hooks)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
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
                Toggle("Show idle sessions", isOn: $settings.showIdle)
                Toggle("Pulse when a session needs input", isOn: $settings.pulse)
                Stepper("Mark running sessions stale after \(Int(settings.staleMinutes)) min",
                        value: $settings.staleMinutes, in: 2...120, step: 1)
                Stepper("Keep ended sessions for \(Int(settings.endedRetentionMinutes)) min",
                        value: $settings.endedRetentionMinutes, in: 0...60, step: 1)
            }
            Section("Shortcuts") {
                Toggle("Global shortcuts", isOn: $settings.hotkeysEnabled)
                LabeledContent("Find a session") { Text("⌃⌥Space").foregroundStyle(.secondary) }
                LabeledContent("Show or hide the panel") { Text("⌃⌥A").foregroundStyle(.secondary) }
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
