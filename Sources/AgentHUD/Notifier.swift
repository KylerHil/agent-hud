import AgentHUDCore
import AppKit
import UserNotifications

/// One notification per state change, optional re-reminders, click to focus the session.
/// Banners carry Show / Snooze / Mute; answering the agent itself always happens in the agent.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let model: AppModel
    private var settings: AppSettings { model.settings }
    private var lastNotified: [String: Date] = [:]
    private var reminders: [String: Int] = [:]
    /// No re-reminders for these sessions until the date passes.
    private var snoozed: [String: Date] = [:]
    private var authorized = false
    private let center = UNUserNotificationCenter.current()

    static let needsCategory = "needs-input"
    static let doneCategory = "finished"
    static let snoozeMinutes = 10.0

    init(model: AppModel) {
        self.model = model
        super.init()
        center.delegate = self
        let show = UNNotificationAction(identifier: "show", title: "Show", options: [.foreground])
        let snooze = UNNotificationAction(identifier: "snooze", title: "Snooze \(Int(Self.snoozeMinutes)) min")
        let mute = UNNotificationAction(identifier: "mute", title: "Mute Session")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.needsCategory, actions: [show, snooze, mute], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.doneCategory, actions: [show, mute], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error { NSLog("Agent HUD notification authorization failed: \(error.localizedDescription)") }
            Task { @MainActor in self.authorized = granted }
        }
    }

    private func quiet(_ s: Session) -> Bool { settings.notificationsPaused || model.isMuted(s) }

    func handle(_ t: Transition, _ s: Session) {
        if t.to != .needsInput {
            center.removeDeliveredNotifications(withIdentifiers: ["needs-\(s.id)"])
            lastNotified.removeValue(forKey: s.id)
            reminders.removeValue(forKey: s.id)
            snoozed.removeValue(forKey: s.id)
        }
        guard !quiet(s) else { return }
        switch t.to {
        case .needsInput where settings.notifyNeedsInput:
            notifyNeedsInput(s)
        case .idle where settings.notifyFinished && (t.from == .running || t.from == .needsInput):
            post(id: "done-\(s.id)", session: s, category: Self.doneCategory,
                 title: s.error != nil ? "\(s.projectName) failed" : "\(s.projectName) finished",
                 body: finishedBody(s))
        default:
            break
        }
    }

    /// "Done in 12m 4s · 3 files changed", then what the agent said last.
    private func finishedBody(_ s: Session) -> String {
        if let e = s.error { return e }
        if s.isChat { return "Reply ready" }
        var facts: [String] = []
        if let d = s.lastTurnDuration, d >= 1 { facts.append("Done in \(longDuration(d))") }
        if !s.filesChanged.isEmpty {
            facts.append("\(s.filesChanged.count) file\(s.filesChanged.count == 1 ? "" : "s") changed")
        }
        let head = facts.joined(separator: " · ")
        let tail = s.lastMessage ?? "\(s.agent.displayName) is waiting for your next prompt"
        return head.isEmpty ? tail : head + "\n" + tail
    }

    /// Called every second; re-reminds about sessions still waiting.
    func tick() {
        guard settings.notifyNeedsInput, !settings.notificationsPaused else { return }
        let interval = settings.remindMinutes * 60
        let now = Date()
        for s in model.store.sessions.values where s.state == .needsInput && model.isShown(s) && !model.isMuted(s) {
            // A snooze is a one-shot reminder, even with repeat reminders off.
            if let until = snoozed[s.id] {
                if until > now { continue }
                snoozed.removeValue(forKey: s.id)
                notifyNeedsInput(s, reminder: true)
                continue
            }
            if interval > 0, let last = lastNotified[s.id], now.timeIntervalSince(last) >= interval {
                notifyNeedsInput(s, reminder: true)
            }
        }
    }

    private func notifyNeedsInput(_ s: Session, reminder: Bool = false) {
        lastNotified[s.id] = Date()
        let p = s.primaryPending
        var body = [p?.reason, p?.detail].compactMap { $0 }.joined(separator: " · ")
        if body.isEmpty { body = "\(s.agent.displayName) is waiting on you" }
        if let host = s.hostLabel { body += "\nAnswer it in \(host)." }
        var title = "\(s.projectName) needs input"
        if reminder {
            let n = (reminders[s.id] ?? 0) + 1
            reminders[s.id] = n
            let waited = shortDuration(Date().timeIntervalSince(p?.since ?? s.stateSince))
            title = "\(s.projectName) is still waiting · \(waited)"
        }
        post(id: "needs-\(s.id)", session: s, category: Self.needsCategory, title: title, body: body)
    }

    private func post(id: String, session s: Session, category: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = [s.agent.displayName, s.hostLabel].compactMap { $0 }.joined(separator: " · ")
        content.body = body
        content.userInfo = ["session": s.id]
        content.threadIdentifier = s.id
        content.categoryIdentifier = category
        if settings.playSound { content.sound = .default }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        // Notifications denied in System Settings: still honor the sound preference.
        if !authorized && settings.playSound { NSSound(named: "Glass")?.play() }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification)
        async -> UNNotificationPresentationOptions { [.banner, .list, .sound] }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["session"] as? String else { return }
        let action = response.actionIdentifier
        let requestID = response.notification.request.identifier
        await MainActor.run {
            guard let s = model.store.sessions[id] else { return }
            switch action {
            case "snooze":
                snoozed[id] = Date().addingTimeInterval(Self.snoozeMinutes * 60)
                lastNotified[id] = Date()
                center.removeDeliveredNotifications(withIdentifiers: [requestID])
            case "mute":
                if !model.isMuted(s) { model.toggleMute(s) }
                center.removeDeliveredNotifications(withIdentifiers: [requestID])
            case UNNotificationDismissActionIdentifier:
                break
            default:
                Focuser.focus(s)
            }
        }
    }
}
