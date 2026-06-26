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
        NSLog("EdgePanel APNs (Tier 2): \(APNsPusher.shared.enabled ? "ENABLED — pushes when the app is closed" : "disabled (no ~/.edgepanel/apns.json)")")
        NSLog("EdgePanel ntfy (free closed-app push): \(NtfyPusher.shared.enabled ? "ENABLED" : "disabled (no ~/.edgepanel/ntfy.json)")")
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
            case ("POST", "/question"):
                // Held PreToolUse hook on AskUserQuestion — surface the options to the
                // phone, then answer by returning allow + updatedInput (echoing the
                // questions verbatim with the chosen answers).
                let bodyObj = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
                let questions = (bodyObj?["tool_input"] as? [String: Any])?["questions"] as? [[String: Any]] ?? []
                guard !questions.isEmpty,
                      let qData = try? JSONSerialization.data(withJSONObject: questions) else { return .hookAck() }
                let project = (bodyObj?["cwd"] as? String).map { ($0 as NSString).lastPathComponent }
                let answers = await state.requestQuestionDecision(questionsData: qData, project: project)
                let resp: [String: Any] = ["hookSpecificOutput": [
                    "hookEventName": "PreToolUse", "permissionDecision": "allow",
                    "updatedInput": ["questions": questions, "answers": answers]]]
                let data = (try? JSONSerialization.data(withJSONObject: resp)) ?? Data("{}".utf8)
                return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: data)
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
            // Approve/deny a held permission request from the phone. Body: {id, decision}.
            if request.method == "POST", path == "/permission/decide" {
                guard let obj = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
                      let id = obj["id"] as? String, let decision = obj["decision"] as? String else {
                    return HTTPResponse(status: 400, headers: [:], body: Data("bad request".utf8))
                }
                await MainActor.run { state.resolveRemote(id: id, decision: decision) }
                return .ok("ok")
            }
            // Answer a held AskUserQuestion from the phone. Body: {id, answers:{q:label}}.
            if request.method == "POST", path == "/question/decide" {
                guard let obj = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
                      let id = obj["id"] as? String, let answers = obj["answers"] as? [String: String] else {
                    return HTTPResponse(status: 400, headers: [:], body: Data("bad request".utf8))
                }
                await MainActor.run { state.resolveQuestionRemote(id: id, answers: answers) }
                return .ok("ok")
            }
            // Chat from the phone: run Claude Code headless in a project. Body:
            // {message, cwd?, sessionId?} → {jobId}; poll with {jobId} → the reply.
            if request.method == "POST", path == "/chat" {
                guard let obj = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
                      let msg = obj["message"] as? String, !msg.isEmpty else {
                    return HTTPResponse(status: 400, headers: [:], body: Data("bad request".utf8))
                }
                let cwd = obj["cwd"] as? String ?? ""
                let sid = obj["sessionId"] as? String
                guard let jid = ChatRunner.shared.start(cwd: cwd, sessionId: sid, message: msg) else {
                    return HTTPResponse(status: 503, headers: ["Content-Type": "application/json"],
                                        body: Data("{\"error\":\"claude CLI not found on the Mac\"}".utf8))
                }
                return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"],
                                    body: Data("{\"jobId\":\"\(jid)\"}".utf8))
            }
            // Load a session's real conversation (your prompts + Claude's replies),
            // so the phone shows the actual chat history from your Mac. Body:{sessionId,cwd?}.
            if request.method == "POST", path == "/chat/history" {
                guard let obj = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
                      let sid = obj["sessionId"] as? String else {
                    return HTTPResponse(status: 400, headers: [:], body: Data("bad request".utf8))
                }
                let cwd = obj["cwd"] as? String ?? ""
                let msgs = UsageLoader.sessionMessages(sessionId: sid, cwd: cwd)
                let arr = msgs.map { ["role": $0.role, "text": $0.text] }
                let data = (try? JSONSerialization.data(withJSONObject: ["messages": arr])) ?? Data("{\"messages\":[]}".utf8)
                return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: data)
            }
            if request.method == "POST", path == "/chat/poll" {
                guard let obj = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
                      let jid = obj["jobId"] as? String else {
                    return HTTPResponse(status: 400, headers: [:], body: Data("bad request".utf8))
                }
                let job = ChatRunner.shared.poll(jid) ?? ChatRunner.Job(status: "error", error: "unknown job")
                let data = (try? JSONEncoder().encode(job)) ?? Data("{}".utf8)
                return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: data)
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
        let host = ProcessInfo.processInfo.environment["EDGEPANEL_PAIR_HOST"] ?? "\(Self.lanIP()):\(port)"
        let view = PairingView(host: host, token: pairingToken())
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
