import AppKit
import SwiftUI
import HearthstoneCore

/// Owns the two game-overlay panels: borderless, transparent, always-on-top and
/// interactive by default — draggable by the title grip (system window drag),
/// scrollable inside, hover-able for card previews. A menu toggle can bring
/// back full mouse pass-through for players who want zero interference.
@MainActor
final class OverlayWindowManager {
    static let shared = OverlayWindowManager()

    private enum PanelID: String {
        case opponent
        case player
    }

    private static let panelSize = NSSize(width: 300, height: 540)

    private var opponentPanel: NSPanel?
    private var playerPanel: NSPanel?
    private weak var store: MatchStore?
    /// Bumps on every show/hide so a hide animation cannot order out a panel
    /// that has since been shown again.
    private var panelEpoch: [PanelID: Int] = [:]
    /// What we last asked AppKit to do. Match-end hides use this so a panel
    /// we opened is closed even if `isVisible` has not caught up yet.
    private var panelWanted: [PanelID: Bool] = [:]
    /// True while a hide animation is waiting to orderOut. A repeat hide must
    /// not bump the epoch, or that orderOut would be dropped.
    private var panelHiding: [PanelID: Bool] = [:]

    func install(store: MatchStore) {
        guard self.store == nil else { return }
        self.store = store

        opponentPanel = makePanel(
            id: .opponent,
            content: OpponentOverlayPanel(store: store)
        )
        playerPanel = makePanel(
            id: .player,
            content: PlayerOverlayPanel(store: store)
        )
        observeStore()
        syncPanels()
    }

    /// Called when pipeline status changes, including from the log callback,
    /// so a match-end hide does not wait on the next observation turn.
    func syncFromStore() {
        syncPanels()
    }

    // MARK: - Panel lifecycle

    private func makePanel(id: PanelID, content: some View) -> NSPanel {
        let frame = storedFrame(
            for: id,
            default: defaultFrame(for: id)
        )
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier(id.rawValue)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let hostingView = NSHostingView(rootView: content)
        // the panel is freely resizable via its corner grip; the hosted SwiftUI
        // view must follow the window instead of pinning its preferred size
        hostingView.frame = NSRect(x: 0, y: 0, width: frame.width, height: frame.height)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        observeGeometry(of: panel, id: id)
        return panel
    }

    private func defaultFrame(for id: PanelID) -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(x: 120, y: 240, width: Self.panelSize.width, height: Self.panelSize.height)
        }
        let visible = screen.visibleFrame
        let margin: CGFloat = 24
        let x: CGFloat = id == .opponent
            ? visible.minX + margin
            : visible.maxX - Self.panelSize.width - margin
        let y = visible.midY - Self.panelSize.height / 2
        return NSRect(
            x: x, y: y,
            width: Self.panelSize.width,
            height: Self.panelSize.height
        )
    }

    private func storedFrame(for id: PanelID, default fallback: NSRect) -> NSRect {
        let key = "overlay-frame-\(id.rawValue)"
        if
            let data = UserDefaults.standard.data(forKey: key),
            let value = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSValue.self, from: data)
        {
            return value.rectValue
        }
        return fallback
    }

    private func persistFrame(of panel: NSPanel, id: PanelID) {
        let key = "overlay-frame-\(id.rawValue)"
        if let data = try? NSKeyedArchiver.archivedData(
            withRootObject: NSValue(rect: panel.frame),
            requiringSecureCoding: true
        ) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func observeGeometry(of panel: NSPanel, id: PanelID) {
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            center.addObserver(
                forName: name,
                object: panel,
                queue: .main
            ) { [weak self] notification in
                guard let window = notification.object as? NSPanel else { return }
                Task { @MainActor in
                    self?.persistFrame(of: window, id: id)
                }
            }
        }
    }

    // MARK: - Store observation

    private func observeStore() {
        guard let store else { return }
        withObservationTracking {
            _ = store.status
            _ = store.isOverlayPassthrough
            _ = store.isOpponentOverlayVisible
            _ = store.isPlayerOverlayVisible
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.syncPanels()
                self?.observeStore()
            }
        }
    }

    private func syncPanels() {
        guard let store else { return }

        // Only .live keeps the floaters up. .finished, .loggedIn (等待对局),
        // .notRunning, and .missingLogConfig all hide both panels. Visibility
        // prefs are left as the user set them, so the next .live shows them
        // again without another click.
        let matchActive = overlaysAllowed(store.status)

        setPanel(opponentPanel, visible: matchActive && store.isOpponentOverlayVisible, id: .opponent)
        setPanel(playerPanel, visible: matchActive && store.isPlayerOverlayVisible, id: .player)

        // pass-through is opt-in via the menu; interactive is the default
        opponentPanel?.ignoresMouseEvents = store.isOverlayPassthrough
        playerPanel?.ignoresMouseEvents = store.isOverlayPassthrough
    }

    /// In-match only. Every other pipeline state is the main, out-of-match UI.
    private func overlaysAllowed(_ status: LogPipelineStatus) -> Bool {
        switch status {
        case .live:
            return true
        case .missingLogConfig, .notRunning, .loggedIn, .finished:
            return false
        }
    }

    func applyLayoutPreset(_ raw: Int) {
        let preset = OverlayLayoutPreset(rawValue: raw) ?? .standard
        let width: CGFloat = preset == .narrow ? 248 : preset == .wide ? 420 : 300
        let height: CGFloat = 540
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let margin: CGFloat = 24
        let y = visible.midY - height / 2
        let left = NSRect(x: visible.minX + margin, y: y, width: width, height: height)
        let right = NSRect(x: visible.maxX - width - margin, y: y, width: width, height: height)
        let opponentOnLeft = preset != .swapped
        opponentPanel?.setFrame(opponentOnLeft ? left : right, display: true)
        playerPanel?.setFrame(opponentOnLeft ? right : left, display: true)
        if let opponentPanel {
            persistFrame(of: opponentPanel, id: .opponent)
        }
        if let playerPanel {
            persistFrame(of: playerPanel, id: .player)
        }
    }

    private func setPanel(_ panel: NSPanel?, visible: Bool, id: PanelID) {
        guard let panel else { return }
        let wanted = panelWanted[id] ?? false
        if visible {
            // Already on screen. Don't bump the epoch: a new show animation
            // on every log tick would cancel the hide that runs when the
            // match ends.
            if wanted, panel.isVisible, panelHiding[id] != true {
                // Log ticks used to restart the alpha animation, which also
                // flushed this non-key panel's hosting view. Keep the flush
                // without starting another fade, so opponent rows are not
                // left on the last composited frame.
                panel.contentView?.needsLayout = true
                panel.contentView?.needsDisplay = true
                panel.contentView?.layoutSubtreeIfNeeded()
                return
            }
            panelHiding[id] = false
            panelWanted[id] = true
            let epoch = (panelEpoch[id] ?? 0) + 1
            panelEpoch[id] = epoch
            if !panel.isVisible {
                panel.setFrame(storedFrame(for: id, default: panel.frame), display: false)
                panel.alphaValue = 0
                panel.orderFrontRegardless()
            }
            NSAnimationContext.runAnimationGroup({ context in
                // Explicit alpha only. Implicit animation also fades SwiftUI
                // insertions inside the hosting view, which leaves new
                // opponent rows at opacity 0 for the rest of the match.
                context.allowsImplicitAnimation = false
                context.duration = 0.35
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.05)
                panel.animator().alphaValue = 1
            }, completionHandler: {
                Task { @MainActor in
                    guard self.panelEpoch[id] == epoch else { return }
                    panel.alphaValue = 1
                }
            })
        } else {
            // A hide is already in flight. Leave its epoch so it can orderOut,
            // unless a later show has taken a newer epoch.
            if panelHiding[id] == true {
                panelWanted[id] = false
                return
            }
            guard wanted || panel.isVisible else { return }
            panelWanted[id] = false
            guard panel.isVisible else { return }
            panelHiding[id] = true
            let epoch = (panelEpoch[id] ?? 0) + 1
            panelEpoch[id] = epoch
            NSAnimationContext.runAnimationGroup({ context in
                context.allowsImplicitAnimation = false
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor in
                    guard self.panelEpoch[id] == epoch else { return }
                    self.panelHiding[id] = false
                    panel.orderOut(nil)
                    panel.alphaValue = 1
                }
            })
        }
    }
}

/// A title-bar drag grip: clicking and moving performs the standard system
/// window drag, so the panel moves exactly like a regular macOS window while
/// its scroll content keeps receiving wheel events.
struct OverlayDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> GripView {
        GripView()
    }

    func updateNSView(_ nsView: GripView, context: Context) {}

    final class GripView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}

/// A corner grip that resizes the borderless panel; the top-left corner stays
/// anchored while dragging.
struct OverlayResizeGrip: NSViewRepresentable {
    func makeNSView(context: Context) -> GripView {
        GripView()
    }

    func updateNSView(_ nsView: GripView, context: Context) {}

    final class GripView: NSView {
        private var startFrame: NSRect = .zero
        private var startPoint: NSPoint = .zero

        override func mouseDown(with event: NSEvent) {
            startFrame = window?.frame ?? .zero
            startPoint = NSEvent.mouseLocation
        }

        override func mouseDragged(with event: NSEvent) {
            let now = NSEvent.mouseLocation
            var frame = startFrame
            frame.size.width = min(max(frame.size.width + now.x - startPoint.x, 240), 520)
            frame.size.height = min(max(frame.size.height + now.y - startPoint.y, 320), 800)
            // anchor the top-left corner in screen coordinates (Y grows upward)
            frame.origin.y = startFrame.maxY - frame.size.height
            window?.setFrame(frame, display: true)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }
}
