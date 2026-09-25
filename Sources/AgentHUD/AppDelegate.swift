import AgentHUDCore
import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()
    lazy var model = AppModel(settings: settings)
    var panel: PanelController!
    var statusItem: NSStatusItem!
    var notifier: Notifier!

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = PanelController(model: model)
        notifier = Notifier(model: model)
        model.onTransition = { [unowned self] t, s in notifier.handle(t, s) }
        model.onTick = { [unowned self] in notifier.tick() }
        model.actions = PanelActions(openDashboard: { [unowned self] in openDashboard() },
                                     focusPanel: { [unowned self] in panel.showForTyping() })
        setUpStatusItem()
        model.start()
        model.updater.canAutoInstall = { [unowned self] in model.counts.attention == 0 }
        model.updater.start()
        if settings.panelVisible { panel.show() }
        applyHotKeys()
    }

    /// Find a session (default ⌃⌥Space) and show/hide the panel (default ⌃⌥A); both set in Settings.
    private func applyHotKeys() {
        HotKeys.shared.unregisterAll()
        if settings.hotkeysEnabled && !model.recordingShortcut {
            let find = settings.findShortcut, show = settings.panelShortcut
            HotKeys.shared.register(id: 1, keyCode: find.keyCode, modifiers: find.modifiers) { [weak self] in self?.toggleSearch() }
            HotKeys.shared.register(id: 2, keyCode: show.keyCode, modifiers: show.modifiers) { [weak self] in self?.panel.toggle() }
        }
        withObservationTracking {
            _ = settings.hotkeysEnabled
            _ = settings.findShortcut
            _ = settings.panelShortcut
            _ = model.recordingShortcut
        } onChange: { [weak self] in
            Task { @MainActor in self?.applyHotKeys() }
        }
    }

    /// ⌃⌥Space: the panel comes forward with its search field focused; again closes the search.
    private func toggleSearch() {
        if model.searching && panel.isVisible {
            model.endSearch()
        } else {
            model.beginSearch()
            panel.showForTyping()
        }
    }

    /// Opening the app again (Finder, Spotlight) while it runs brings the panel back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.show()
        return false
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusItem()
        observeCounts()
    }

    private var lastDots: [SessionState]?

    private func observeCounts() {
        withObservationTracking { _ = model.menuBarStates } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateStatusItem()
                self?.observeCounts()
            }
        }
    }

    /// The eye, always, followed by one colored dot per live session in panel order.
    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let states = model.menuBarStates
        guard states != lastDots else { return }
        lastDots = states
        button.title = ""
        if states.isEmpty {
            let eye = NSImage(systemSymbolName: "eye", accessibilityDescription: "Agent HUD")
            eye?.isTemplate = true // plain template: the system tints it exactly like other menu bar icons
            button.image = eye
        } else {
            button.image = Self.dotsImage(states, withEye: true)
        }
        let c = model.counts
        button.toolTip = "Agent HUD: \(c.attention) need input · \(c.running) running · \(c.idle) idle"
    }

    static let maxDots = 10

    static func dotsImage(_ states: [SessionState], withEye: Bool = false) -> NSImage {
        let shown = Array(states.prefix(maxDots))
        let overflow = states.count - shown.count
        let d: CGFloat = 8, gap: CGFloat = 3, height: CGFloat = 18
        let eye = withEye ? NSImage(systemSymbolName: "eye", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) : nil
        let lead = eye.map { $0.size.width + 6 } ?? 0
        let more = overflow > 0 ? NSAttributedString(string: "+\(overflow)", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.labelColor,
        ]) : nil
        let dotsWidth = CGFloat(shown.count) * d + CGFloat(max(0, shown.count - 1)) * gap
        let width = lead + dotsWidth + (more.map { $0.size().width + gap + 1 } ?? 0)
        // Drawn lazily, so dynamic colors (eye, idle gray, "+N") resolve against the menu bar's appearance.
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            if let eye {
                // The image has colored dots, so it can't be a template; tint the eye by hand instead.
                let r = NSRect(x: 0, y: (height - eye.size.height) / 2, width: eye.size.width, height: eye.size.height)
                eye.draw(in: r)
                NSColor.labelColor.set()
                r.fill(using: .sourceAtop)
            }
            for (i, state) in shown.enumerated() {
                let rect = NSRect(x: lead + CGFloat(i) * (d + gap), y: (height - d) / 2, width: d, height: d)
                state.nsColor.setFill()
                NSBezierPath(ovalIn: rect).fill()
                if state == .needsInput { // a ring makes "needs you" readable even for colorblind eyes
                    NSColor.systemOrange.withAlphaComponent(0.45).setStroke()
                    let ring = NSBezierPath(ovalIn: rect.insetBy(dx: -1.5, dy: -1.5))
                    ring.lineWidth = 1.2
                    ring.stroke()
                }
            }
            if let more {
                more.draw(at: NSPoint(x: lead + dotsWidth + gap + 1, y: (height - more.size().height) / 2))
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Agent HUD: " + states.map(\.verb).joined(separator: ", ")
        return image
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let c = model.counts
        let summary = NSMenuItem(title: "\(c.attention) need input · \(c.running) running · \(c.idle) idle",
                                 action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)

        // Every live session, grouped like the panel; click to jump to it.
        let sessions = model.menuBarSessions
        let groups: [(String, (SessionState) -> Bool)] = [
            ("Needs You", { $0 == .needsInput }),
            ("Working", { $0 == .running || $0 == .stale }),
            ("Idle", { ![.needsInput, .running, .stale].contains($0) }),
        ]
        for (title, match) in groups {
            let members = sessions.filter { match(model.displayState($0)) }
            guard !members.isEmpty else { continue }
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: title))
            for s in members { menu.addItem(sessionItem(s)) }
        }
        menu.addItem(.separator())
        let next = add(menu, "Jump to Next Waiting", #selector(focusNextWaiting), "")
        next.isEnabled = model.nextWaiting != nil
        hotkey(add(menu, "Find Session…", #selector(openSwitcher), ""), settings.findShortcut)
        hotkey(add(menu, panel.isVisible ? "Hide Panel" : "Show Panel", #selector(togglePanel), ""), settings.panelShortcut)
        add(menu, settings.collapsed ? "Expand Panel" : "Collapse to Pill", #selector(toggleCollapsed), "")
        add(menu, "Show Idle Sessions", #selector(toggleShowIdle), "").state = settings.showIdle ? .on : .off
        menu.addItem(pauseItem())
        add(menu, "Dashboard…", #selector(openDashboard), "")
        if model.canSyncDotOrder {
            add(menu, "Sync Dot Order with AeroSpace", #selector(syncDotOrder), "")
            if !settings.dotOrder.isEmpty { add(menu, "Reset Dot Order", #selector(resetDotOrder), "") }
        }
        menu.addItem(.separator())
        add(menu, "Settings…", #selector(openSettings), ",")
        if let r = model.updater.available {
            add(menu, "Update to \(r.version)…", #selector(installUpdate), "")
        } else {
            add(menu, "Check for Updates…", #selector(checkForUpdates), "")
        }
        add(menu, "Open Event Log", #selector(openLog), "")
        menu.addItem(.separator())
        add(menu, "Quit Agent HUD", #selector(quit), "q")
    }

    /// "web-app  Permission · Bash  · 42s", with the state dot.
    private func sessionItem(_ s: Session) -> NSMenuItem {
        let state = model.displayState(s)
        let age = shortDuration(model.now.timeIntervalSince(model.since(s)))
        let item = NSMenuItem(title: s.projectName, action: #selector(focusSession(_:)), keyEquivalent: "")
        let detail: String
        switch state {
        case .needsInput: detail = s.primaryPending?.reason ?? "needs input"
        case .running: detail = [s.hostLabel, s.currentDetail?.components(separatedBy: " · ").first].compactMap { $0 }
            .joined(separator: " · ")
        case .stale: detail = "quiet"
        default: detail = s.isChat ? "reply ready" : (s.hostLabel ?? s.agent.displayName)
        }
        let title = NSMutableAttributedString(string: s.projectName,
                                              attributes: [.font: NSFont.menuFont(ofSize: 0).bold])
        if let sub = s.subpath {
            title.append(NSAttributedString(string: " › " + sub, attributes: [.font: NSFont.menuFont(ofSize: 0)]))
        }
        title.append(NSAttributedString(string: "   " + [detail, age].filter { !$0.isEmpty }.joined(separator: " · "), attributes: [
            .font: NSFont.menuFont(ofSize: 12),
            .foregroundColor: state == .needsInput ? NSColor.systemOrange : NSColor.secondaryLabelColor,
        ]))
        item.attributedTitle = title
        item.target = self
        item.representedObject = s.id
        item.image = Self.dotsImage([state])
        if state == .needsInput, let p = s.primaryPending {
            item.toolTip = [p.reason, p.detail].compactMap { $0 }.joined(separator: " · ")
        }
        return item
    }

    private func pauseItem() -> NSMenuItem {
        let paused = settings.notificationsPaused
        let item = NSMenuItem(title: paused ? "Notifications Paused Until "
            + Date(timeIntervalSince1970: settings.pausedUntil).formatted(date: .omitted, time: .shortened)
            : "Pause Notifications", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        if paused {
            let resume = NSMenuItem(title: "Resume Now", action: #selector(pauseNotifications(_:)), keyEquivalent: "")
            resume.target = self
            resume.tag = 0
            sub.addItem(resume)
            sub.addItem(.separator())
        }
        for (title, minutes) in [("For 15 Minutes", 15), ("For 1 Hour", 60), ("For 3 Hours", 180), ("Until Tomorrow", -1)] {
            let i = NSMenuItem(title: title, action: #selector(pauseNotifications(_:)), keyEquivalent: "")
            i.target = self
            i.tag = minutes
            sub.addItem(i)
        }
        item.submenu = sub
        return item
    }

    /// Shows the global shortcut next to the menu item.
    private func hotkey(_ item: NSMenuItem, _ s: Shortcut) {
        guard settings.hotkeysEnabled, let (key, flags) = s.menuEquivalent else { return }
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = flags
    }

    @discardableResult
    func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc func focusSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let s = model.store.sessions[id] else { return }
        Focuser.focus(s)
    }

    @objc func pauseNotifications(_ sender: NSMenuItem) {
        switch sender.tag {
        case 0: settings.pausedUntil = 0
        case -1:
            let tomorrow = Calendar.current.startOfDay(for: Date().addingTimeInterval(86400))
            settings.pausedUntil = tomorrow.addingTimeInterval(8 * 3600).timeIntervalSince1970
        default: settings.pausedUntil = Date().addingTimeInterval(Double(sender.tag) * 60).timeIntervalSince1970
        }
    }

    @objc func focusNextWaiting() { if let s = model.nextWaiting { Focuser.focus(s) } }
    @objc func openSwitcher() { toggleSearch() }
    @objc func openDashboard() {
        model.openDashboard()
        panel.show()
    }
    @objc func togglePanel() { panel.toggle() }
    @objc func syncDotOrder() { model.syncDotOrder() }
    @objc func resetDotOrder() { settings.dotOrder = [] }
    @objc func toggleCollapsed() { settings.collapsed.toggle(); panel.show() }
    @objc func toggleShowIdle() { settings.showIdle.toggle() }
    @objc func checkForUpdates() {
        model.updater.check()
        model.openSettings(.general)
        panel.show()
    }

    @objc func installUpdate() { model.updater.install() }

    @objc func openSettings() {
        model.openSettings()
        panel.show()
    }
    @objc func openLog() { NSWorkspace.shared.activateFileViewerSelecting([Paths.eventsFile]) }
    @objc func quit() { NSApp.terminate(nil) }
}

private extension NSFont {
    var bold: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask) }
}
