import AppKit
import SwiftUI
import QuartzCore

/// A non-activating floating panel, adapted from Perch's `NotchPanel`.
///
/// `.nonactivatingPanel` is the load-bearing flag: clicks land without making
/// EdgePanel the active app, so the editor keeps its caret. `becomesKeyOnlyIfNeeded`
/// lets controls (the Allow/Deny buttons in Phase 2) take key focus on demand
/// without ever pulling main-window status away from the editor.
final class EdgePanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false            // the SwiftUI card draws its own shadow
        level = .statusBar           // above normal windows, just under the menu bar layer
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false    // stay put when another app becomes key
        isMovableByWindowBackground = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// `NSHostingView` that accepts the first click without activating the app —
/// so a click on the freshly-revealed panel registers immediately instead of
/// just bringing it forward. Reports its SwiftUI content's fitting size on each
/// layout, so the panel can size to content (deterministic, unlike a SwiftUI
/// GeometryReader under `.fixedSize()`).
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    var onResize: ((CGSize) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func layout() {
        super.layout()
        onResize?(fittingSize)
    }
}

/// Owns the edge-docked panel: its geometry, the slide animation, and the
/// edge-stick hover-reveal mechanic (with hysteresis + a dismiss delay).
@MainActor
final class EdgePanelController {
    private let panel: EdgePanel
    private let hosting: FirstMouseHostingView<AnyView>

    // MARK: Geometry / tuning
    private var panelWidth: CGFloat
    private var panelHeight: CGFloat
    /// Gap between the panel's right edge and the screen edge when shown.
    private let edgeGap: CGFloat = 8
    /// Reveal trigger: the cursor must be within this many px of the literal edge.
    private let revealHotZone: CGFloat = 2
    /// Hide trigger: the cursor must move this far *past* the panel's inner edge.
    /// Reveal-at-edge + this slack is the hysteresis that kills boundary flicker.
    private let hideSlack: CGFloat = 30
    /// How long after the cursor leaves before we slide out. Cancelled on return.
    private let dismissDelay: TimeInterval = 0.4
    /// How long the cursor must REST at the edge before we reveal — kills accidental pops from
    /// flicking the cursor to the right edge (scrollbars, close buttons, hot corners).
    private let revealDwell: TimeInterval = 0.22

    // MARK: State
    private(set) var isShown = false
    /// Phase 2 lock-open: while true the panel never auto-hides, regardless of
    /// cursor position. Setting it true also force-reveals (a permission gate
    /// must surface even if the cursor is nowhere near the edge).
    var approvalPending = false {
        didSet {
            guard approvalPending != oldValue else { return }
            // A genuinely NEW permission/question must surface even right after a manual dismiss.
            if approvalPending { revealSuppressed = false; cancelHideTimer(); reveal() }
        }
    }
    /// Menu toggle: when false, the cursor never auto-reveals the panel. A held permission
    /// still surfaces (safety), and the menu / hotkey toggle still opens it on demand.
    var hoverEnabled = true
    /// Set by the Close (✕) button — blocks hover-reveal until the cursor leaves the edge zone
    /// once, so dismissing doesn't instantly bounce the panel back while the cursor is still there.
    private var revealSuppressed = false

    private var hideTimer: Timer?
    private var dwellTimer: Timer?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    /// Resize the panel to the SwiftUI content (reported via the view's onSize),
    /// keeping it docked. Width is content-driven too (card + shadow gutter).
    func setContentSize(_ size: CGSize) {
        let w = max(120, size.width.rounded(.up))
        let screenH = targetScreen()?.frame.height ?? 1000
        let h = min(max(120, size.height.rounded(.up)), screenH - 24)   // never taller than the screen
        guard abs(w - panelWidth) >= 1 || abs(h - panelHeight) >= 1 else { return }
        panelWidth = w; panelHeight = h
        panel.setFrame(isShown ? shownFrame() : hiddenFrame(), display: true)
    }

    init(rootView: some View, width: CGFloat = 408, height: CGFloat = 640) {
        panelWidth = width
        panelHeight = height
        panel = EdgePanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height))
        hosting = FirstMouseHostingView(rootView: AnyView(rootView))
        if #available(macOS 13.0, *) { hosting.sizingOptions = [.intrinsicContentSize] }
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        hosting.onResize = { [weak self] size in self?.setContentSize(size) }
        panel.setFrame(hiddenFrame(), display: false)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    // MARK: - Screen + frames

    /// The screen that owns the right physical edge of the desktop = the
    /// rightmost screen by `frame.maxX`.
    private func targetScreen() -> NSScreen? {
        NSScreen.screens.max(by: { $0.frame.maxX < $1.frame.maxX }) ?? NSScreen.main
    }

    /// Visible position: docked against the right edge with a small gap,
    /// vertically centred on the target screen.
    private func shownFrame() -> NSRect {
        guard let f = targetScreen()?.frame else { return panel.frame }
        let x = (f.maxX - panelWidth - edgeGap).rounded()
        let y = (f.midY - panelHeight / 2).rounded()
        return NSRect(x: x, y: y, width: panelWidth, height: panelHeight)
    }

    /// Hidden position: fully past the right edge (left edge at `f.maxX`).
    private func hiddenFrame() -> NSRect {
        guard let f = targetScreen()?.frame else { return panel.frame }
        let y = (f.midY - panelHeight / 2).rounded()
        return NSRect(x: f.maxX, y: y, width: panelWidth, height: panelHeight)
    }

    /// X of the panel's inner (left) edge when shown — the hysteresis reference.
    private func innerEdgeX() -> CGFloat {
        guard let f = targetScreen()?.frame else { return 0 }
        return f.maxX - panelWidth - edgeGap
    }

    // MARK: - Hover-reveal

    func startMonitoring() {
        // Global monitor: fires while another app (incl. a fullscreen one) is
        // frontmost. Mouse-moved global monitors need NO accessibility permission.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluateCursor() }
        }
        // Local monitor: covers moves delivered to our own panel.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            MainActor.assumeIsolated { self?.evaluateCursor() }
            return event
        }
    }

    /// The whole hover state machine. Idempotent — safe to call on every move.
    private func evaluateCursor() {
        guard let f = targetScreen()?.frame else { return }
        let p = NSEvent.mouseLocation   // global coords, bottom-left origin (matches NSScreen.frame)

        let onTargetVertically = p.y >= f.minY && p.y <= f.maxY
        let atEdge = onTargetVertically && p.x >= f.maxX - revealHotZone
        let wellClear = p.x < innerEdgeX() - hideSlack

        // Cursor left the reveal zone → re-arm (a Close-button dismiss only holds until you move away).
        if !atEdge { revealSuppressed = false; cancelDwell() }

        if atEdge && hoverEnabled && !revealSuppressed {
            cancelHideTimer()
            scheduleReveal()          // dwell first, so an incidental graze doesn't pop it open
        } else if isShown {
            // Between the edge and `inner - slack` is the dead band: keep open.
            if wellClear { scheduleHide() } else { cancelHideTimer() }
        }
    }

    // MARK: - Show / hide (animated frame slide)

    func reveal() {
        cancelHideTimer()
        if isShown { return }
        isShown = true
        if !panel.isVisible { panel.setFrame(hiddenFrame(), display: false) }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(shownFrame(), display: true)
        }
    }

    /// `force` (the Close button) hides even when a permission has it pinned open.
    func hide(force: Bool = false) {
        if !isShown || (approvalPending && !force) { return }
        isShown = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(hiddenFrame(), display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {           // completion fires on the main thread
                guard let self, !self.isShown else { return }  // a reveal raced in — keep it up
                self.panel.orderOut(nil)
            }
        })
    }

    func toggle() { isShown ? hide(force: true) : reveal() }

    /// The Close (✕) button: hide now — even if a permission has it pinned — and don't
    /// hover-reveal again until the cursor has left the edge, so it actually goes away.
    func dismiss() {
        revealSuppressed = true
        cancelHideTimer()
        cancelDwell()
        hide(force: true)
    }

    /// Reveal only after the cursor RESTS at the edge for `revealDwell` — an incidental graze
    /// (flicking to a scrollbar / close button / hot corner) never pops the panel.
    private func scheduleReveal() {
        if isShown || dwellTimer != nil { return }
        dwellTimer = Timer.scheduledTimer(withTimeInterval: revealDwell, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dwellTimer = nil
                guard let f = self.targetScreen()?.frame else { return }
                let p = NSEvent.mouseLocation
                let stillAtEdge = p.y >= f.minY && p.y <= f.maxY && p.x >= f.maxX - self.revealHotZone
                if stillAtEdge && self.hoverEnabled && !self.revealSuppressed { self.reveal() }
            }
        }
    }
    private func cancelDwell() { dwellTimer?.invalidate(); dwellTimer = nil }

    private func scheduleHide() {
        guard hideTimer == nil, !approvalPending else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: dismissDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hideTimer = nil
                self.hide()
            }
        }
    }

    private func cancelHideTimer() {
        hideTimer?.invalidate()
        hideTimer = nil
    }

    @objc private func screenChanged() {
        // Re-dock correctly after a display change (resolution / arrangement).
        panel.setFrame(isShown ? shownFrame() : hiddenFrame(), display: true)
    }

    deinit {
        if let g = globalMonitor { NSEvent.removeMonitor(g) }
        if let l = localMonitor { NSEvent.removeMonitor(l) }
        NotificationCenter.default.removeObserver(self)
    }
}
