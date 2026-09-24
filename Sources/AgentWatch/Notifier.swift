import AgentWatchCore
import AppKit
import UserNotifications

/// One notification per state change, optional re-reminders, click to focus the session.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let model: AppModel
    private var settings: AppSettings { model.settings }
    private var lastNotified: [String: Date] = [:]
    private var authorized = false
    private let center = UNUserNotificationCenter.current()

    init(model: AppModel) {
        self.model = model
        super.init()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error { NSLog("AgentWatch notification authorization failed: \(error.localizedDescription)") }
            Task { @MainActor in self.authorized = granted }
        }
    }

    func handle(_ t: Transition, _ s: Session) {
        if t.to != .needsInput {
            center.removeDeliveredNotifications(withIdentifiers: ["needs-\(s.id)"])
            lastNotified.removeValue(forKey: s.id)
        }
        switch t.to {
        case .needsInput where settings.notifyNeedsInput:
            notifyNeedsInput(s)
        case .idle where settings.notifyFinished && (t.from == .running || t.from == .needsInput):
            post(id: "done-\(s.id)", session: s, title: "\(s.projectName) finished",
                 body: s.error ?? s.lastMessage ?? "\(s.agent.displayName) is waiting for your next prompt")
        default:
            break
        }
    }

    /// Called every second; re-reminds about sessions still waiting.
    func tick() {
        guard settings.notifyNeedsInput, settings.remindMinutes > 0 else { return }
        let interval = settings.remindMinutes * 60
        for s in model.store.sessions.values where s.state == .needsInput {
            if let last = lastNotified[s.id], Date().timeIntervalSince(last) >= interval {
                notifyNeedsInput(s, reminder: true)
            }
        }
    }

    private func notifyNeedsInput(_ s: Session, reminder: Bool = false) {
        lastNotified[s.id] = Date()
        let p = s.primaryPending
        let body = [p?.reason, p?.detail].compactMap { $0 }.joined(separator: " · ")
        post(id: "needs-\(s.id)", session: s,
             title: "\(s.projectName) needs input" + (reminder ? " (still waiting)" : ""),
             body: body.isEmpty ? "\(s.agent.displayName) is waiting on you" : body)
    }

    private func post(id: String, session s: Session, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = s.agent.displayName
        content.body = body
        content.userInfo = ["session": s.id]
        content.threadIdentifier = s.id
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
        await MainActor.run {
            if let s = model.store.sessions[id] { Focuser.focus(s) }
        }
    }
}
