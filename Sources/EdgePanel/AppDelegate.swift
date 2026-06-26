import AppKit
import SwiftUI
import PerchCore
import Darwin

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var controller: EdgePanelController?
    private var signalSource: DispatchSourceSignal?

    private let store = UsageStore()
    private let state = EdgePanelState()
    private var server: HTTPServer?
    private var lanServer: HTTPServer?

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
        // Tier 2: when a session finishes, push a "done" update to the phone.
        store.onSessionEnded = { [weak self] s in self?.state.pushSessionEnded(s) }

        startServer()
        startLANServer()
        setupDebugToggle()
        if ProcessInfo.processInfo.environment["EDGEPANEL_SHOW_PAIRING"] == "1" { showPairing() }
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

    // MARK: - LAN bridge for the iPhone companion (token-protected)

    private func pairingToken() -> String {
        let key = "edgepanel.pairingToken"
        if let t = UserDefaults.standard.string(forKey: key), !t.isEmpty { return t }
        let t = UUID().uuidString
        UserDefaults.standard.set(t, forKey: key)
        return t
    }

    private func startLANServer() {
        let token = pairingToken()
        let port = UInt16(ProcessInfo.processInfo.environment["EDGEPANEL_LAN_PORT"] ?? "") ?? 8788
        let store = self.store, state = self.state
        let server = HTTPServer(port: port, loopbackOnly: false) { request in
            let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
            if request.method == "GET", path == "/health" { return .ok("edgepanel-lan ok") }
            // Auth: X-EdgePanel-Token header, or ?token= query.
            let headerTok = request.headers["x-edgepanel-token"]
            let queryTok = request.path.contains("token=")
                ? request.path.components(separatedBy: "token=").last?.components(separatedBy: "&").first : nil
            guard (headerTok ?? queryTok) == token else {
                return HTTPResponse(status: 401, headers: ["Content-Type": "application/json"],
                                    body: Data("{\"error\":\"unauthorized\"}".utf8))
            }
            if request.method == "GET", path == "/snapshot" {
                let data = await MainActor.run { () -> Data in
                    let snap = EdgeSnapshot.build(store: store, state: state)
                    let enc = JSONEncoder()
                    return (try? enc.encode(snap)) ?? Data("{}".utf8)
                }
                return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: data)
            }
            // Resume a chat on the Mac, triggered from the phone. Body: {id, cwd}.
            if request.method == "POST", path == "/open" {
                guard let obj = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
                      let id = obj["id"] as? String else {
                    return HTTPResponse(status: 400, headers: [:], body: Data("bad request".utf8))
                }
                let cwd = obj["cwd"] as? String
                await MainActor.run { state.openChat(cwd: cwd, id: id) }
                return .ok("opening")
            }
            // Register an APNs push token (Tier 2). Body: {kind, token, sessionId?}.
            if request.method == "POST", path == "/pushtoken" {
                guard let obj = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
                      let kind = obj["kind"] as? String, let tok = obj["token"] as? String else {
                    return HTTPResponse(status: 400, headers: [:], body: Data("bad request".utf8))
                }
                let sid = obj["sessionId"] as? String
                await MainActor.run { state.setPushToken(kind: kind, sessionId: sid, token: tok) }
                return .ok("ok")
            }
            return .notFound()
        }
        do {
            try server.start()
            NSLog("EdgePanel LAN bridge → http://\(Self.lanIP()):\(port)/snapshot  (token: \(token))")
        } catch {
            NSLog("EdgePanel LAN bridge failed on :\(port): \(error.localizedDescription)")
        }
        self.lanServer = server
    }

    /// Best-effort primary LAN IPv4 (en0/en1), for the pairing log.
    private static func lanIP() -> String {
        var result = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return result }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            let flags = Int32(cur.pointee.ifa_flags)
            if let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
               (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING) {
                let name = String(cString: cur.pointee.ifa_name)
                if name == "en0" || name == "en1" {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        result = String(cString: host)
                    }
                }
            }
            ptr = cur.pointee.ifa_next
        }
        freeifaddrs(ifaddr)
        return result
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
            let pair = NSMenuItem(title: "Pair iPhone…", action: #selector(showPairing), keyEquivalent: "")
            let quit = NSMenuItem(title: "Quit EdgePanel", action: #selector(quit), keyEquivalent: "q")
            for it in [toggle, pair, quit] { it.target = self }
            menu.addItem(toggle); menu.addItem(pair); menu.addItem(.separator()); menu.addItem(quit)
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
        } else {
            togglePanel()
        }
    }

    @objc private func togglePanel() { controller?.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }

    private var pairingWindow: NSWindow?
    @objc private func showPairing() {
        let port = UInt16(ProcessInfo.processInfo.environment["EDGEPANEL_LAN_PORT"] ?? "") ?? 8788
        let view = PairingView(host: "\(Self.lanIP()):\(port)", token: pairingToken())
        if pairingWindow == nil {
            let win = NSWindow(contentViewController: NSHostingController(rootView: view))
            win.title = "Pair iPhone"
            win.styleMask = [.titled, .closable]
            win.isReleasedWhenClosed = false
            pairingWindow = win
        } else {
            (pairingWindow?.contentViewController as? NSHostingController<PairingView>)?.rootView = view
        }
        NSApp.activate(ignoringOtherApps: true)
        pairingWindow?.center()
        pairingWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Debug toggle (headless verification)

    private func setupDebugToggle() {
        signal(SIGUSR1, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        src.setEventHandler { [weak self] in self?.controller?.toggle() }
        src.resume()
        signalSource = src
    }
}
