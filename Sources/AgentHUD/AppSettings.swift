import Foundation
import Observation

/// User preferences, persisted in UserDefaults.
@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    var opacity: Double { didSet { defaults.set(opacity, forKey: "opacity") } }
    var collapsed: Bool { didSet { defaults.set(collapsed, forKey: "collapsed") } }
    var panelVisible: Bool { didSet { defaults.set(panelVisible, forKey: "panelVisible") } }
    var showIdle: Bool { didSet { defaults.set(showIdle, forKey: "showIdle") } }
    var pulse: Bool { didSet { defaults.set(pulse, forKey: "pulse") } }
    var staleMinutes: Double { didSet { defaults.set(staleMinutes, forKey: "staleMinutes") } }
    var endedRetentionMinutes: Double { didSet { defaults.set(endedRetentionMinutes, forKey: "endedRetentionMinutes") } }
    var notifyNeedsInput: Bool { didSet { defaults.set(notifyNeedsInput, forKey: "notifyNeedsInput") } }
    var notifyFinished: Bool { didSet { defaults.set(notifyFinished, forKey: "notifyFinished") } }
    var playSound: Bool { didSet { defaults.set(playSound, forKey: "playSound") } }
    /// 0 = never re-remind.
    var remindMinutes: Double { didSet { defaults.set(remindMinutes, forKey: "remindMinutes") } }
    var trackProcesses: Bool { didSet { defaults.set(trackProcesses, forKey: "trackProcesses") } }
    /// Panel filter tab: all, needs, working, idle.
    var panelFilter: String { didSet { defaults.set(panelFilter, forKey: "panelFilter") } }
    var watchClaudeDesktop: Bool { didSet { defaults.set(watchClaudeDesktop, forKey: "watchClaudeDesktop") } }
    var watchChatGPT: Bool { didSet { defaults.set(watchChatGPT, forKey: "watchChatGPT") } }
    /// Experimental: ordinary chats in Claude and ChatGPT, through Accessibility.
    var watchChats: Bool { didSet { defaults.set(watchChats, forKey: "watchChats") } }
    var hotkeysEnabled: Bool { didSet { defaults.set(hotkeysEnabled, forKey: "hotkeysEnabled") } }
    var checkForUpdates: Bool { didSet { defaults.set(checkForUpdates, forKey: "checkForUpdates") } }
    var installUpdatesAutomatically: Bool {
        didSet { defaults.set(installUpdatesAutomatically, forKey: "installUpdatesAutomatically") }
    }
    var lastUpdateCheck: Double { didSet { defaults.set(lastUpdateCheck, forKey: "lastUpdateCheck") } }
    var findShortcut: Shortcut { didSet { save(findShortcut, "findShortcut") } }
    var panelShortcut: Shortcut { didSet { save(panelShortcut, "panelShortcut") } }
    /// Notifications are paused until this time (seconds since 1970; 0 = not paused).
    var pausedUntil: Double { didSet { defaults.set(pausedUntil, forKey: "pausedUntil") } }
    /// History: silences longer than this between transcript events don't count as active time.
    var idleGapMinutes: Double { didSet { defaults.set(idleGapMinutes, forKey: "idleGapMinutes") } }
    var dashboardRange: String { didSet { defaults.set(dashboardRange, forKey: "dashboardRange") } }

    init() {
        defaults.register(defaults: [
            "opacity": 0.95, "collapsed": false, "panelVisible": true, "showIdle": true, "pulse": true,
            "staleMinutes": 15.0, "endedRetentionMinutes": 3.0,
            "notifyNeedsInput": true, "notifyFinished": false, "playSound": true, "remindMinutes": 0.0,
            "trackProcesses": true, "panelFilter": "all", "watchClaudeDesktop": true, "watchChatGPT": true,
            "watchChats": false, "hotkeysEnabled": true, "pausedUntil": 0.0, "idleGapMinutes": 10.0,
            "dashboardRange": "today", "checkForUpdates": true, "installUpdatesAutomatically": true,
            "lastUpdateCheck": 0.0,
        ])
        opacity = defaults.double(forKey: "opacity")
        collapsed = defaults.bool(forKey: "collapsed")
        panelVisible = defaults.bool(forKey: "panelVisible")
        showIdle = defaults.bool(forKey: "showIdle")
        pulse = defaults.bool(forKey: "pulse")
        staleMinutes = defaults.double(forKey: "staleMinutes")
        endedRetentionMinutes = defaults.double(forKey: "endedRetentionMinutes")
        notifyNeedsInput = defaults.bool(forKey: "notifyNeedsInput")
        notifyFinished = defaults.bool(forKey: "notifyFinished")
        playSound = defaults.bool(forKey: "playSound")
        remindMinutes = defaults.double(forKey: "remindMinutes")
        trackProcesses = defaults.bool(forKey: "trackProcesses")
        panelFilter = defaults.string(forKey: "panelFilter") ?? "all"
        watchClaudeDesktop = defaults.bool(forKey: "watchClaudeDesktop")
        watchChatGPT = defaults.bool(forKey: "watchChatGPT")
        watchChats = defaults.bool(forKey: "watchChats")
        hotkeysEnabled = defaults.bool(forKey: "hotkeysEnabled")
        checkForUpdates = defaults.bool(forKey: "checkForUpdates")
        installUpdatesAutomatically = defaults.bool(forKey: "installUpdatesAutomatically")
        lastUpdateCheck = defaults.double(forKey: "lastUpdateCheck")
        findShortcut = Self.load(defaults, "findShortcut") ?? .findDefault
        panelShortcut = Self.load(defaults, "panelShortcut") ?? .panelDefault
        pausedUntil = defaults.double(forKey: "pausedUntil")
        idleGapMinutes = defaults.double(forKey: "idleGapMinutes")
        dashboardRange = defaults.string(forKey: "dashboardRange") ?? "today"
    }

    var staleAfter: TimeInterval { staleMinutes * 60 }
    var endedRetention: TimeInterval { endedRetentionMinutes * 60 }
    private func save(_ s: Shortcut, _ key: String) { defaults.set(try? JSONEncoder().encode(s), forKey: key) }

    private static func load(_ d: UserDefaults, _ key: String) -> Shortcut? {
        d.data(forKey: key).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
    }

    var notificationsPaused: Bool { pausedUntil > Date().timeIntervalSince1970 }
}
