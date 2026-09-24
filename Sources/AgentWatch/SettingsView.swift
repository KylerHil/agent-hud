import AgentWatchCore
import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    var hooks: HooksPane? = nil
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
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
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Toggle("Detect agent processes (liveness, sessions without hooks)", isOn: $settings.trackProcesses)
            }
            if let hooks {
                Section("Hooks") { hooks }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
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

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let content: () -> AnyView

    init(content: @escaping () -> AnyView) { self.content = content }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "AgentWatch Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: content())
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
