import AgentWatchCore
import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()
    lazy var model = AppModel(settings: settings)
    var panel: PanelController!
    var statusItem: NSStatusItem!
    var notifier: Notifier!
    lazy var settingsWindow = SettingsWindowController { [unowned self] in
        AnyView(SettingsView(settings: settings, hooks: HooksPane()))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = PanelController(model: model)
        notifier = Notifier(model: model)
        model.onTransition = { [unowned self] t, s in notifier.handle(t, s) }
        model.onTick = { [unowned self] in notifier.tick() }
        setUpStatusItem()
        model.start()
        if settings.panelVisible { panel.show() }
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
            let eye = NSImage(systemSymbolName: "eye", accessibilityDescription: "AgentWatch")
            eye?.isTemplate = true // plain template: the system tints it exactly like other menu bar icons
            button.image = eye
        } else {
            button.image = Self.dotsImage(states, withEye: true)
        }
        let c = model.counts
        button.toolTip = "AgentWatch: \(c.attention) need input · \(c.running) running · \(c.idle) idle"
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
        image.accessibilityDescription = "AgentWatch: " + states.map(\.verb).joined(separator: ", ")
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

        // Every live session, same order and colors as the dots; click to jump to it.
        for s in model.menuBarSessions {
            let state = model.displayState(s)
            let age = shortDuration(model.now.timeIntervalSince(model.since(s)))
            let item = NSMenuItem(title: "\(s.projectName)  ·  \(s.agent.displayName)  ·  \(state.verb) \(age)",
                                  action: #selector(focusSession(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = s.id
            item.image = Self.dotsImage([state])
            if state == .needsInput, let p = s.primaryPending {
                item.toolTip = [p.reason, p.detail].compactMap { $0 }.joined(separator: " · ")
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        add(menu, panel.isVisible ? "Hide Panel" : "Show Panel", #selector(togglePanel), "p")
        add(menu, settings.collapsed ? "Expand Panel" : "Collapse to Pill", #selector(toggleCollapsed), "")
        add(menu, "Show Idle Sessions", #selector(toggleShowIdle), "").state = settings.showIdle ? .on : .off
        menu.addItem(.separator())
        add(menu, "Settings…", #selector(openSettings), ",")
        add(menu, "Open Event Log", #selector(openLog), "")
        menu.addItem(.separator())
        add(menu, "Quit AgentWatch", #selector(quit), "q")
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

    @objc func togglePanel() { panel.toggle() }
    @objc func toggleCollapsed() { settings.collapsed.toggle(); panel.show() }
    @objc func toggleShowIdle() { settings.showIdle.toggle() }
    @objc func openSettings() { settingsWindow.show() }
    @objc func openLog() { NSWorkspace.shared.activateFileViewerSelecting([Paths.eventsFile]) }
    @objc func quit() { NSApp.terminate(nil) }
}
