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
    var watchClaudeDesktop: Bool { didSet { defaults.set(watchClaudeDesktop, forKey: "watchClaudeDesktop") } }
    var watchChatGPT: Bool { didSet { defaults.set(watchChatGPT, forKey: "watchChatGPT") } }
    /// Experimental: ordinary chats in Claude and ChatGPT, through Accessibility.
    var watchChats: Bool { didSet { defaults.set(watchChats, forKey: "watchChats") } }
    var hotkeysEnabled: Bool { didSet { defaults.set(hotkeysEnabled, forKey: "hotkeysEnabled") } }
    /// One row per project instead of one per session.
    var groupByProject: Bool { didSet { defaults.set(groupByProject, forKey: "groupByProject") } }
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
    /// Finish notifications only for turns at least this long (0 = every turn).
    var finishedMinMinutes: Double { didSet { defaults.set(finishedMinMinutes, forKey: "finishedMinMinutes") } }
    var showContextGauge: Bool { didSet { defaults.set(showContextGauge, forKey: "showContextGauge") } }
    /// Claude's context window in tokens; 0 = work it out (200K, or 1M once a session has used more than 200K).
    var claudeContextWindow: Int { didSet { defaults.set(claudeContextWindow, forKey: "claudeContextWindow") } }
    /// Where the palette starts new sessions (`Launcher.Host`).
    var launchHost: String { didSet { defaults.set(launchHost, forKey: "launchHost") } }
    /// The list's Simple / Detailed switch: Detailed adds each session's agent, app and latest line.
    var homeDetailed: Bool { didSet { defaults.set(homeDetailed, forKey: "homeDetailed") } }
    /// Which kinds of session the panel, menu bar and notifications show.
    var showTerminalSessions: Bool { didSet { defaults.set(showTerminalSessions, forKey: "showTerminalSessions") } }
    var showTmuxSessions: Bool { didSet { defaults.set(showTmuxSessions, forKey: "showTmuxSessions") } }
    var showEditorSessions: Bool { didSet { defaults.set(showEditorSessions, forKey: "showEditorSessions") } }
    var showAppSessions: Bool { didSet { defaults.set(showAppSessions, forKey: "showAppSessions") } }
    /// Allowlist suggestions you turned down ("<root>|<rule>").
    var dismissedSuggestions: Set<String> {
        didSet { defaults.set(Array(dismissedSuggestions).sorted(), forKey: "dismissedSuggestions") }
    }
    /// Editor window folder names in AeroSpace's tree order, from the last "Sync Dot Order". Empty: urgency order.
    var dotOrder: [String] { didSet { defaults.set(dotOrder, forKey: "dotOrder") } }

    init() {
        defaults.register(defaults: [
            "opacity": 0.95, "collapsed": false, "panelVisible": true, "showIdle": true, "pulse": true,
            "staleMinutes": 15.0, "endedRetentionMinutes": 3.0,
            "notifyNeedsInput": true, "notifyFinished": false, "playSound": true, "remindMinutes": 0.0,
            "trackProcesses": true, "watchClaudeDesktop": true, "watchChatGPT": true,
            "watchChats": false, "hotkeysEnabled": true, "pausedUntil": 0.0, "idleGapMinutes": 10.0,
            "dashboardRange": "today", "checkForUpdates": true, "groupByProject": false, "installUpdatesAutomatically": true,
            "lastUpdateCheck": 0.0, "finishedMinMinutes": 2.0, "showContextGauge": true, "claudeContextWindow": 0,
            "launchHost": "automatic", "showTerminalSessions": true, "showTmuxSessions": true,
            "showEditorSessions": true, "showAppSessions": true, "homeDetailed": false,
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
        watchClaudeDesktop = defaults.bool(forKey: "watchClaudeDesktop")
        watchChatGPT = defaults.bool(forKey: "watchChatGPT")
        watchChats = defaults.bool(forKey: "watchChats")
        hotkeysEnabled = defaults.bool(forKey: "hotkeysEnabled")
        groupByProject = defaults.bool(forKey: "groupByProject")
        checkForUpdates = defaults.bool(forKey: "checkForUpdates")
        installUpdatesAutomatically = defaults.bool(forKey: "installUpdatesAutomatically")
        lastUpdateCheck = defaults.double(forKey: "lastUpdateCheck")
        findShortcut = Self.load(defaults, "findShortcut") ?? .findDefault
        panelShortcut = Self.load(defaults, "panelShortcut") ?? .panelDefault
        pausedUntil = defaults.double(forKey: "pausedUntil")
        idleGapMinutes = defaults.double(forKey: "idleGapMinutes")
        dashboardRange = defaults.string(forKey: "dashboardRange") ?? "today"
        finishedMinMinutes = defaults.double(forKey: "finishedMinMinutes")
        showContextGauge = defaults.bool(forKey: "showContextGauge")
        claudeContextWindow = defaults.integer(forKey: "claudeContextWindow")
        launchHost = defaults.string(forKey: "launchHost") ?? "automatic"
        homeDetailed = defaults.bool(forKey: "homeDetailed")
        showTerminalSessions = defaults.bool(forKey: "showTerminalSessions")
        showTmuxSessions = defaults.bool(forKey: "showTmuxSessions")
        showEditorSessions = defaults.bool(forKey: "showEditorSessions")
        showAppSessions = defaults.bool(forKey: "showAppSessions")
        dismissedSuggestions = Set(defaults.stringArray(forKey: "dismissedSuggestions") ?? [])
        dotOrder = defaults.stringArray(forKey: "dotOrder") ?? []
    }

    var staleAfter: TimeInterval { staleMinutes * 60 }
    var endedRetention: TimeInterval { endedRetentionMinutes * 60 }
    private func save(_ s: Shortcut, _ key: String) { defaults.set(try? JSONEncoder().encode(s), forKey: key) }

    private static func load(_ d: UserDefaults, _ key: String) -> Shortcut? {
        d.data(forKey: key).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
    }

    var notificationsPaused: Bool { pausedUntil > Date().timeIntervalSince1970 }
}
