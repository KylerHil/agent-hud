import AgentHUDCore
import AppKit
import ApplicationServices

/// Experimental: sees ordinary chats in Claude and ChatGPT through Accessibility. While a reply streams,
/// both apps show a Stop button in the window; when it goes away, the reply is ready.
/// Only the window title and that button are read, and no message text is stored.
final class ChatWatcher: @unchecked Sendable {
    struct Target {
        var bundleID: String
        var agent: AgentKind
        var hostKind: String
    }

    static let targets = [
        Target(bundleID: "com.anthropic.claudefordesktop", agent: .claude, hostKind: "claude-desktop"),
        Target(bundleID: "com.openai.chat", agent: .chatgpt, hostKind: "chatgpt"),
        Target(bundleID: "com.openai.codex", agent: .chatgpt, hostKind: "chatgpt"),
    ]

    /// One chat window as seen right now.
    struct Seen: Sendable {
        var key: String
        var agent: AgentKind
        var hostKind: String
        var hostApp: String?
        var title: String
        var responding: Bool
    }

    private let queue = DispatchQueue(label: "agenthud.chats", qos: .utility)
    private var busy = false

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to Privacy & Security → Accessibility.
    static func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Collects chat windows in the background and hands them back on the main actor.
    /// Disabled or untrusted yields no windows, which ends any chat rows still around.
    @MainActor
    func observe(enabled: Bool, _ done: @escaping @MainActor ([Seen]) -> Void) {
        guard !busy else { return }
        guard enabled, Self.isTrusted else { done([]); return }
        busy = true
        let apps = Self.targets.flatMap { t in
            NSRunningApplication.runningApplications(withBundleIdentifier: t.bundleID).map { (t, $0.processIdentifier, $0.bundleURL?.path) }
        }
        queue.async { [weak self] in
            var seen: [Seen] = []
            for (t, pid, path) in apps { seen += Self.windows(pid: pid, target: t, appPath: path) }
            DispatchQueue.main.async {
                self?.busy = false
                MainActor.assumeIsolated { done(seen) }
            }
        }
    }

    private static func windows(pid: pid_t, target: Target, appPath: String?) -> [Seen] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        // Electron apps (Claude) only build their accessibility tree when asked to.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let appName = appPath.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? ""
        return children(app, kAXWindowsAttribute).compactMap { w in
            let raw = string(w, kAXTitleAttribute) ?? ""
            let title = raw.isEmpty || raw == appName ? target.agent.displayName : raw
            return Seen(key: "chat-\(target.bundleID)-\(stableHash(title))", agent: target.agent,
                        hostKind: target.hostKind, hostApp: appPath, title: title.preview(80),
                        responding: hasStopButton(w))
        }
    }

    /// Breadth-first, bounded: chat windows have deep trees, and every call crosses into the other app.
    private static func hasStopButton(_ window: AXUIElement) -> Bool {
        var queue = [window]
        var visited = 0
        while !queue.isEmpty, visited < 2500 {
            let el = queue.removeFirst()
            visited += 1
            if string(el, kAXRoleAttribute) == kAXButtonRole as String {
                let label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXIdentifierAttribute]
                    .compactMap { string(el, $0) }.joined(separator: " ").lowercased()
                if label.contains("stop"), !["dictation", "recording", "voice", "listening"].contains(where: label.contains) {
                    return true
                }
                continue
            }
            queue += children(el, kAXChildrenAttribute)
        }
        return false
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private static func children(_ el: AXUIElement, _ attr: String) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return [] }
        return (v as? [AXUIElement]) ?? []
    }

    /// FNV-1a, so a window's key survives restarts (Swift's hashValue is seeded per launch).
    private static func stableHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return String(h, radix: 36)
    }

    /// Events that bring chat rows in line with the windows: a row appears the first time a reply streams,
    /// goes idle ("Reply ready") when it stops, and ends when its window closes or after 15 idle minutes.
    @MainActor
    static func reconcile(store: SessionStore, seen: [Seen], now: Date) -> [AgentEvent] {
        var events: [AgentEvent] = []
        var byKey: [String: Seen] = [:]
        for s in seen { byKey[s.key] = byKey[s.key].map { $0.responding ? $0 : s } ?? s }
        for s in byKey.values {
            let existing = store.sessions[SessionStore.key(s.agent, s.key)]
            let wanted: String
            if s.responding {
                if existing?.state == .running { continue }
                wanted = "RolloutRunning"
            } else {
                guard let e = existing, e.state == .running else { continue }
                wanted = "RolloutIdle"
            }
            var e = AgentEvent(ts: now.timeIntervalSince1970, agent: s.agent, event: wanted, sessionId: s.key)
            e.title = s.title
            e.hostKind = s.hostKind
            e.hostApp = s.hostApp
            e.origin = "chat"
            if wanted == "RolloutIdle" { e.message = "Reply ready" }
            events.append(e)
        }
        for s in store.sessions.values where s.isChat && s.state != .ended {
            let open = byKey[s.sessionId] != nil
            if !open || (s.state == .idle && now.timeIntervalSince(s.stateSince) > 15 * 60) {
                var e = AgentEvent(ts: now.timeIntervalSince1970, agent: s.agent, event: "SessionEnd", sessionId: s.sessionId)
                e.origin = "chat"
                events.append(e)
            }
        }
        return events
    }
}
