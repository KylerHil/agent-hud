import AppKit
import SwiftUI

/// Borderless, non-activating, always-on-top panel that follows you across Spaces and full-screen apps.
final class FloatingPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 60),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController {
    let panel = FloatingPanel()
    private let model: AppModel
    private let hosting: NSHostingView<PanelRootView>
    private static let originKey = "panelTopLeft"
    private static let sizeKey = "panelSize"
    static let defaultSize = CGSize(width: 340, height: 500)
    static let minLargeSize = CGSize(width: 560, height: 420)

    private static func sizeKey(_ m: PanelMode) -> String {
        switch m {
        case .list, .today: "panelSize" // Today opens in the list's place, at its size
        case .dashboard: "dashboardSize"
        case .settings: "settingsSize"
        }
    }

    private static func defaultSize(_ m: PanelMode) -> CGSize {
        switch m {
        case .list, .today: defaultSize
        case .dashboard: CGSize(width: 800, height: 720)
        case .settings: CGSize(width: 580, height: 600)
        }
    }
    static let minSize = CGSize(width: 260, height: 160)

    /// Screen-space anchor of an in-progress window drag.
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    /// Set while a drag moved the window, so the click that ends it doesn't also focus a row.
    private(set) var didDrag = false

    init(model: AppModel) {
        self.model = model
        hosting = NSHostingView(rootView: PanelRootView(model: model))
        hosting.sizingOptions = [] // the window is sized by the user, not by SwiftUI
        panel.contentView = hosting
        panel.isMovableByWindowBackground = false // we move it ourselves so dragging works from any row
        panel.minSize = Self.minSize
        hosting.rootView = PanelRootView(model: model, controller: self)
        applyMode(animate: false)
        restorePosition()
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.savePosition() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: panel,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveSize() }
        }
        applyOpacity(hovering: false)
        observeSettings()
    }

    /// Whether the panel window is on screen (not in the menu bar as the pill, not hidden).
    var isVisible: Bool { panel.isVisible }

    /// Shows the panel, or the menu bar pill when it's collapsed.
    func show() {
        model.settings.panelVisible = true
        if !model.settings.collapsed { panel.orderFrontRegardless() }
    }

    func hide() {
        model.settings.panelVisible = false
        syncWindow()
    }

    func toggle() { model.settings.panelVisible ? hide() : show() }

    /// Collapsed, the panel lives in the menu bar as the pill, so its window stays off screen.
    private func syncWindow() {
        if model.settings.panelVisible && !model.settings.collapsed {
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else if panel.isVisible {
            panel.orderOut(nil)
        }
    }

    /// Shows the panel and takes keystrokes (for search) without activating the app, like Spotlight.
    func showForTyping() {
        show()
        panel.makeKeyAndOrderFront(nil)
    }

    func applyOpacity(hovering: Bool) {
        panel.alphaValue = hovering ? 1 : max(0.2, model.settings.opacity)
    }

    private func observeSettings() {
        withObservationTracking {
            _ = model.settings.collapsed
            _ = model.settings.opacity
            _ = model.mode
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyMode(animate: true)
                self.syncWindow()
                self.applyOpacity(hovering: false)
                self.observeSettings()
            }
        }
    }

    // MARK: - Size

    /// The list, dashboard and settings each remember their own size.
    private var sizeKey: String { Self.sizeKey(model.mode) }
    private var currentMinSize: CGSize { model.mode.isLarge ? Self.minLargeSize : Self.minSize }

    private var savedSize: CGSize {
        let fallback = Self.defaultSize(model.mode)
        guard let a = UserDefaults.standard.array(forKey: sizeKey) as? [Double], a.count == 2 else { return fallback }
        return CGSize(width: max(a[0], currentMinSize.width), height: max(a[1], currentMinSize.height))
    }

    private func saveSize() {
        guard !model.settings.collapsed else { return }
        UserDefaults.standard.set([panel.frame.width, panel.frame.height], forKey: sizeKey)
    }

    /// Where the list sat before a large mode opened, since the bigger panel may have to shift over.
    private var preLargeTopLeft: NSPoint?
    private var wasLarge = false

    /// User-sized and resizable, top-left fixed. Collapsed, the window is off screen and keeps its size.
    private func applyMode(animate: Bool) {
        guard !model.settings.collapsed else { return }
        let large = model.mode.isLarge && !model.settings.collapsed
        if large && !wasLarge { preLargeTopLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY) }
        defer {
            if !large && wasLarge, let p = preLargeTopLeft {
                panel.setFrameTopLeftPoint(p)
                preLargeTopLeft = nil
            }
            wasLarge = large
        }
        panel.styleMask.insert(.resizable)
        panel.minSize = currentMinSize
        setSize(savedSize, animate: animate)
    }

    func setSize(_ size: CGSize, animate: Bool = false) {
        let old = panel.frame
        var new = NSRect(x: old.minX, y: old.maxY - size.height, width: size.width, height: size.height)
        // Growing (the dashboard) must stay on the panel's screen: shift left/down rather than spill off.
        if let screen = (panel.screen ?? NSScreen.main)?.visibleFrame {
            new.size.width = min(new.width, screen.width)
            new.size.height = min(new.height, screen.height)
            if new.maxX > screen.maxX { new.origin.x = screen.maxX - new.width }
            if new.minX < screen.minX { new.origin.x = screen.minX }
            if new.minY < screen.minY { new.origin.y = screen.minY }
        }
        guard new != old else { return }
        panel.setFrame(new, display: true, animate: animate && panel.isVisible)
        panel.invalidateShadow()
    }

    /// Bottom-right grip: resize while keeping the top-left corner fixed.
    func resize(by delta: CGSize, from start: NSRect) {
        let w = max(currentMinSize.width, start.width + delta.width)
        let h = max(currentMinSize.height, start.height - delta.height)
        panel.setFrame(NSRect(x: start.minX, y: start.maxY - h, width: w, height: h), display: true)
    }

    func endResize() {
        saveSize()
        panel.invalidateShadow()
    }

    // MARK: - Dragging from anywhere

    func dragChanged() {
        let mouse = NSEvent.mouseLocation
        guard let start = dragStart else {
            dragStart = (mouse, panel.frame.origin)
            return
        }
        didDrag = true
        panel.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                     y: start.origin.y + mouse.y - start.mouse.y))
    }

    func dragEnded() {
        dragStart = nil
        // Let the tap that fires on this same mouse-up see didDrag, then clear it.
        DispatchQueue.main.async { self.didDrag = false }
    }

    // MARK: - Position

    private func savePosition() {
        let f = panel.frame
        UserDefaults.standard.set([f.minX, f.maxY], forKey: Self.originKey)
    }

    private func restorePosition() {
        let saved = UserDefaults.standard.array(forKey: Self.originKey) as? [Double]
        var topLeft: NSPoint
        if let saved, saved.count == 2 {
            topLeft = NSPoint(x: saved[0], y: saved[1])
        } else {
            let screen = NSScreen.main?.visibleFrame ?? .init(x: 0, y: 0, width: 1440, height: 900)
            topLeft = NSPoint(x: screen.maxX - Self.defaultSize.width - 16, y: screen.maxY - 12)
        }
        // If the saved spot is off every screen (monitor unplugged), come back to the main one.
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.insetBy(dx: -20, dy: -20).contains(topLeft) }
        if !onScreen, let screen = NSScreen.main?.visibleFrame {
            topLeft = NSPoint(x: screen.maxX - Self.defaultSize.width - 16, y: screen.maxY - 12)
        }
        panel.setFrameTopLeftPoint(topLeft)
    }
}

/// Bottom-right corner grip for resizing.
struct ResizeGrip: NSViewRepresentable {
    let controller: PanelController?

    func makeNSView(context: Context) -> GripView { GripView() }
    func updateNSView(_ view: GripView, context: Context) { view.controller = controller }

    final class GripView: NSView {
        weak var controller: PanelController?
        private var startMouse: NSPoint = .zero
        private var startFrame: NSRect = .zero

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

        override func mouseDown(with event: NSEvent) {
            startMouse = NSEvent.mouseLocation
            startFrame = window?.frame ?? .zero
        }

        override func mouseDragged(with event: NSEvent) {
            let m = NSEvent.mouseLocation
            MainActor.assumeIsolated {
                controller?.resize(by: CGSize(width: m.x - startMouse.x, height: m.y - startMouse.y), from: startFrame)
            }
        }

        override func mouseUp(with event: NSEvent) {
            MainActor.assumeIsolated { controller?.endResize() }
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.tertiaryLabelColor.setStroke()
            for i in 1...3 {
                let d = CGFloat(i) * 3.5
                let p = NSBezierPath()
                p.move(to: NSPoint(x: bounds.maxX - d - 2, y: bounds.minY + 2))
                p.line(to: NSPoint(x: bounds.maxX - 2, y: bounds.minY + d + 2))
                p.lineWidth = 1
                p.stroke()
            }
        }
    }
}
