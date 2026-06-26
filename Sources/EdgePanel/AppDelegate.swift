import AppKit
import SwiftUI
import PerchCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var controller: EdgePanelController?
    private var signalSource: DispatchSourceSignal?

    private let store = UsageStore()
    private let state = EdgePanelState()
    private var server: HTTPServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        store.start()
        let view = EdgeUsageView(store: store, state: state)
        let controller = EdgePanelController(rootView: view)
        controller.startMonitoring()
        self.controller = controller

        // A pending permission locks the panel open and auto-reveals it.
        state.onApprovalChange = { [weak controller] pending in
            controller?.approvalPending = pending
        }

        startServer()
        setupDebugToggle()
        NSLog("EdgePanel launched — Phase 1 (live Usage + hook pipe). Right-edge to reveal · kill -USR1 \(ProcessInfo.processInfo.processIdentifier)")
    }

    // MARK: - HTTP hook pipe (reuses PerchCore.HTTPServer + the verified contract)

    private func startServer() {
        let port = UInt16(ProcessInfo.processInfo.environment["EDGEPANEL_PORT"] ?? ProcessInfo.processInfo.environment["PERCH_PORT"] ?? "") ?? 8787
        let state = self.state
        let server = HTTPServer(port: port) { request in
            guard request.remoteIsLoopback else {
                return HTTPResponse(status: 403, headers: [:], body: Data("loopback only".utf8))
            }
            switch (request.method, request.path) {
            case ("POST", "/event"):
                let event = HookEvent(data: request.body, endpoint: request.path)
                await MainActor.run { state.handle(event) }
                return .hookAck()
            case ("POST", "/statusline"):
                let body = request.body
                await MainActor.run { state.updateStatusline(data: body) }
                return .hookAck()
            case ("POST", "/permission"):
                // Held open until the user taps Allow/Deny/Always in the panel,
                // or the decision times out and falls through to the native prompt.
                let event = HookEvent(data: request.body, endpoint: request.path)
                let verdict = await state.requestDecision(for: event)
                return verdict.response(for: event.eventName ?? "PreToolUse")
            case ("GET", "/health"):
                return .ok("edgepanel ok")
            case ("POST", "/debug/decide"):
                // Test-only (EDGEPANEL_DEBUG=1): resolve the current pending request.
                guard ProcessInfo.processInfo.environment["EDGEPANEL_DEBUG"] == "1" else { return .notFound() }
                let v = PermissionVerdict(rawValue: request.bodyString.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .ask
                await MainActor.run { state.resolveCurrent(v) }
                return .ok("resolved \(v.rawValue)")
            default:
                return .notFound()
            }
        }
        server.onLog = { msg in NSLog("EdgePanel server: \(msg)") }
        do {
            try server.start()
        } catch {
            NSLog("EdgePanel server FAILED on port \(port): \(error.localizedDescription) (hooks will be non-blocking)")
        }
        self.server = server
    }

    // MARK: - Menu bar (its only job: toggle the panel)

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "EdgePanel")
        item.button?.image?.isTemplate = true
        item.button?.target = self
        item.button?.action = #selector(statusClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let toggle = NSMenuItem(title: "Toggle Panel", action: #selector(togglePanel), keyEquivalent: "")
            let quit = NSMenuItem(title: "Quit EdgePanel", action: #selector(quit), keyEquivalent: "q")
            for it in [toggle, quit] { it.target = self }
            menu.addItem(toggle); menu.addItem(.separator()); menu.addItem(quit)
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
        } else {
            togglePanel()
        }
    }

    @objc private func togglePanel() { controller?.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Debug toggle (headless verification)

    private func setupDebugToggle() {
        signal(SIGUSR1, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        src.setEventHandler { [weak self] in self?.controller?.toggle() }
        src.resume()
        signalSource = src
    }
}
