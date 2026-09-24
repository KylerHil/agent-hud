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

    init() {
        defaults.register(defaults: [
            "opacity": 0.95, "collapsed": false, "panelVisible": true, "showIdle": true, "pulse": true,
            "staleMinutes": 15.0, "endedRetentionMinutes": 3.0,
            "notifyNeedsInput": true, "notifyFinished": false, "playSound": true, "remindMinutes": 0.0,
            "trackProcesses": true,
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
    }

    var staleAfter: TimeInterval { staleMinutes * 60 }
    var endedRetention: TimeInterval { endedRetentionMinutes * 60 }
}
