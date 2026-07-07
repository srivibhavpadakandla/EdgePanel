import AppKit
import SwiftUI
import PerchCore
import Darwin
import CryptoKit

/// Shared auth helpers so NtfyPusher (a separate class) can mint a scoped action token without
/// needing a reference to AppDelegate or the raw pairing token.
enum EdgePanelAuth {
    static func pairingToken() -> String {
        let key = "edgepanel.pairingToken"
        if let t = UserDefaults.standard.string(forKey: key), !t.isEmpty { return t }
        let t = UUID().uuidString
        UserDefaults.standard.set(t, forKey: key)
        return t
    }

    /// A scoped, single-permission action token: proves possession of the pairing token without
    /// ever transmitting it. ntfy.sh is a public third-party relay by default (the topic name is
    /// the only access control), so an action button embedding the RAW pairing token would hand
    /// anyone who reads that topic full LAN control (/chat, /open, /pushtoken, every route) —
    /// this token can only ever resolve the ONE permission id + decision it was minted for.
    static func actionToken(id: String, decision: String) -> String {
        let key = SymmetricKey(data: Data(pairingToken().utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data("\(id)|\(decision)".utf8), using: key)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }
}

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

        // Restore push tokens persisted from before a restart, so the Mac can still push
        // the Island's "end" (otherwise it'd stay frozen on a stuck timer after a relaunch).
        state.loadPushTokens()
        store.start()
        let view = EdgeUsageView(store: store, state: state)
        let controller = EdgePanelController(rootView: view)
        controller.hoverEnabled = (UserDefaults.standard.object(forKey: "edgepanel.hoverEnabled") as? Bool) ?? true
        controller.startMonitoring()
        self.controller = controller

        // A pending permission locks the panel open and auto-reveals it.
        state.onApprovalChange = { [weak controller] pending in
            controller?.approvalPending = pending
        }
        // The panel's Close (✕) button slides it away (and keeps it away until you go back to the edge).
        state.onDismissRequest = { [weak controller] in controller?.dismiss() }
        // Tier 2: when a session finishes, push a "done" update to the phone.
        store.onSessionEnded = { [weak self] s in self?.state.pushSessionEnded(s) }
        // Seamless Dynamic Island: push the aggregate state (end/update) when the set
        // of working chats changes, so the Island stops the instant a turn finishes.
        store.onWorkingChanged = { [weak self] w in self?.state.pushAggregate(working: w) }
        store.onModeChanged = { [weak self] m in self?.state.permissionMode = m }
        // 5-hour limit alerts come from the always-on Mac → reach the phone even when closed.
        store.onUsageAlert = { [weak self] title, body in self?.state.pushUsageAlert(title: title, body: body) }
        store.onEffortChanged = { [weak self] e in self?.state.setEffort(e) }

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
        let state = self.state, store = self.store
        let server = HTTPServer(port: port) { request in
            guard request.remoteIsLoopback else {
                return HTTPResponse(status: 403, headers: [:], body: Data("loopback only".utf8))
            }
            let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
            switch (request.method, path) {
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
            case ("GET", "/debug/inject-probe"):
                // Test-only (EDGEPANEL_DEBUG=1): focus the editor chat input + report what
                // Accessibility sees — validates the focus path WITHOUT typing into the chat.
                guard ProcessInfo.processInfo.environment["EDGEPANEL_DEBUG"] == "1" else { return .notFound() }
                let info = EditorInjector.shared.probeFocus()
                let data = (try? JSONSerialization.data(withJSONObject: info)) ?? Data("{}".utf8)
                return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: data)
            case ("GET", "/debug/snapshot"):
                // Test-only (EDGEPANEL_DEBUG=1): the panel snapshot over loopback, no token,
                // so the mode/effort/mascot selector can be verified end-to-end.
                guard ProcessInfo.processInfo.environment["EDGEPANEL_DEBUG"] == "1" else { return .notFound() }
                let data = await MainActor.run { () -> Data in
                    let snap = EdgeSnapshot.build(store: store, state: state)
                    return (try? JSONEncoder().encode(snap)) ?? Data("{}".utf8)
                }
                return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: data)
            case ("GET", "/debug/testnotif"):
                // Test-only (EDGEPANEL_DEBUG=1): fire ONE real notification (APNs alert + ntfy) to the
                // paired phone, to confirm the closed-app delivery path end-to-end.
                guard ProcessInfo.processInfo.environment["EDGEPANEL_DEBUG"] == "1" else { return .notFound() }
                await MainActor.run {
                    state.pushUsageAlert(title: "EdgePanel test 🔔", body: "If you see this, notifications work.")
                }
                return .ok("test notification sent")
            case ("GET", "/debug/render"):
                // Test-only (EDGEPANEL_DEBUG=1): render the live panel to a PNG at ?out=,
                // so the mascot + ModeCard can be eyeballed even with the display asleep.
                guard ProcessInfo.processInfo.environment["EDGEPANEL_DEBUG"] == "1" else { return .notFound() }
                let out: String = {
                    guard let q = request.path.split(separator: "?", maxSplits: 1).dropFirst().first else { return "" }
                    for pair in q.split(separator: "&") {
                        let kv = pair.split(separator: "=", maxSplits: 1)
                        if kv.first == "out", kv.count == 2 {
                            return String(kv[1]).removingPercentEncoding ?? String(kv[1])
                        }
                    }
                    return ""
                }()
                let ok = await MainActor.run { () -> Bool in
                    let renderer = ImageRenderer(content: ModePreview(state: state))
                    renderer.scale = 2
                    guard !out.isEmpty, let img = renderer.nsImage,
                          let tiff = img.tiffRepresentation,
                          let rep = NSBitmapImageRep(data: tiff),
                          let png = rep.representation(using: .png, properties: [:]) else { return false }
                    return (try? png.write(to: URL(fileURLWithPath: out))) != nil
                }
                return ok ? .ok("rendered \(out)") : HTTPResponse(status: 500, headers: [:], body: Data("render failed".utf8))
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

    private func pairingToken() -> String { EdgePanelAuth.pairingToken() }

    private func startLANServer() {
        let token = pairingToken()
        let port = UInt16(ProcessInfo.processInfo.environment["EDGEPANEL_LAN_PORT"] ?? "") ?? 8788
        let store = self.store, state = self.state
        let server = HTTPServer(port: port, loopbackOnly: false) { request in
            let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
            if request.method == "GET", path == "/health" { return .ok("edgepanel-lan ok") }
            // Auth: X-EdgePanel-Token header, or ?token= query.
            let headerTok = request.headers["x-edgepanel-token"]
            // Parse the FIRST token= from the query string only (not .last over the
            // whole path, which let ?token=known&token=evil pick the attacker's value).
            let queryTok: String? = {
                guard let q = request.path.split(separator: "?", maxSplits: 1).dropFirst().first else { return nil }
                for pair in q.split(separator: "&") {
                    let kv = pair.split(separator: "=", maxSplits: 1)
                    if kv.first == "token", kv.count == 2 { return String(kv[1]) }
                }
                return nil
            }()
            if !Self.constantTimeEqual(headerTok ?? queryTok, token) {
                // The full pairing token didn't match. The ONE exception: /permission/decide may
                // instead authenticate with a scoped per-action token (see EdgePanelAuth) — this
                // is how ntfy action buttons resolve a permission, since ntfy.sh is a public
                // third-party relay by default and must never carry the raw, full-control token.
                guard request.method == "POST", path == "/permission/decide",
                      let obj = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
                      let id = obj["id"] as? String, let decision = obj["decision"] as? String,
                      let actionTok = request.headers["x-edgepanel-action-token"],
                      Self.constantTimeEqual(actionTok, EdgePanelAuth.actionToken(id: id, decision: decision))
                else {
                    return HTTPResponse(status: 401, headers: ["Content-Type": "application/json"],
                                        body: Data("{\"error\":\"unauthorized\"}".utf8))
                }
                await MainActor.run { state.resolveRemote(id: id, decision: decision) }
                return .ok("ok")
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
            // Register an APNs push token (Tier 2). Body: {kind, token, sessionId?, gen?}.
            if request.method == "POST", path == "/pushtoken" {
                guard let obj = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
                      let kind = obj["kind"] as? String, let tok = obj["token"] as? String else {
                    return HTTPResponse(status: 400, headers: [:], body: Data("bad request".utf8))
                }
                let sid = obj["sessionId"] as? String
                let gen = obj["gen"] as? Int   // the push-to-start generation this token was vended for, if the phone reported one
                await MainActor.run { state.setPushToken(kind: kind, sessionId: sid, token: tok, gen: gen) }
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
                // If the target is the session you're LIVE in (open in VS Code / Cursor), type
                // the message straight into that chat so the conversation continues in your
                // editor — instead of forking a separate `claude -p` that can't see it. The
                // reply is watched out of the session transcript and streamed back the same way.
                // Any other session (idle/away, or a new task) → reliable headless streaming.
                let liveInject = (sid?.isEmpty == false)
                    && sid == UsageLoader.mostRecentInteractiveSessionId()
                    && EditorInjector.shared.available
                let result = liveInject
                    ? ChatRunner.shared.startInject(cwd: cwd, sessionId: sid!, message: msg)
                    : ChatRunner.shared.start(cwd: cwd, sessionId: sid, message: msg)
                switch result {
                case .started(let jid):
                    return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"],
                                        body: Data("{\"jobId\":\"\(jid)\"}".utf8))
                case .busy:
                    return HTTPResponse(status: 409, headers: ["Content-Type": "application/json"],
                                        body: Data("{\"error\":\"a turn is already running for this chat\"}".utf8))
                case .unavailable:
                    return HTTPResponse(status: 503, headers: ["Content-Type": "application/json"],
                                        body: Data("{\"error\":\"claude CLI not found on the Mac\"}".utf8))
                }
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
                // "gone" (not "error") for an unknown job — the Mac may have restarted or
                // evicted the finished job; the phone treats this as "recover the reply from
                // the session transcript" rather than surfacing a scary error.
                let job = ChatRunner.shared.poll(jid) ?? ChatRunner.Job(status: "gone")
                let data = (try? JSONEncoder().encode(job)) ?? Data("{}".utf8)
                return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: data)
            }
            // Recent projects to start a NEW autonomous task in (project picker on the phone).
            if request.method == "GET", path == "/projects" {
                let projs = UsageLoader.recentProjects()
                let arr = projs.map { ["name": $0.name, "cwd": $0.cwd] }
                let data = (try? JSONSerialization.data(withJSONObject: ["projects": arr])) ?? Data("{\"projects\":[]}".utf8)
                return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: data)
            }
            // Stop a running chat turn from the phone. Body: {jobId}.
            if request.method == "POST", path == "/chat/cancel" {
                guard let obj = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
                      let jid = obj["jobId"] as? String else {
                    return HTTPResponse(status: 400, headers: [:], body: Data("bad request".utf8))
                }
                let ok = ChatRunner.shared.cancel(jid)
                return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"],
                                    body: Data("{\"stopped\":\(ok)}".utf8))
            }
            // PANIC STOP: kill all running turns + Autonomous off + deny held/incoming.
            if request.method == "POST", path == "/panic" {
                let killed = await MainActor.run { state.panic() }
                return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"],
                                    body: Data("{\"killed\":\(killed)}".utf8))
            }
            // Toggle Autonomous (auto-approve) mode. Body: {on: bool}.
            if request.method == "POST", path == "/automode" {
                guard let obj = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
                      let on = obj["on"] as? Bool else {
                    return HTTPResponse(status: 400, headers: [:], body: Data("bad request".utf8))
                }
                await MainActor.run { state.setAutoApprove(on) }
                return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"],
                                    body: Data("{\"autoApprove\":\(on)}".utf8))
            }
            return .notFound()
        }
        do {
            try server.start()
            NSLog("EdgePanel LAN bridge → http://\(Self.lanIP()):\(port)/snapshot  (token: \(Self.redact(token)))")
        } catch {
            NSLog("EdgePanel LAN bridge failed on :\(port): \(error.localizedDescription)")
        }
        self.lanServer = server
    }

    /// Compare the presented token to the secret without an early-out, so response
    /// time doesn't leak how many leading characters matched (timing side channel).
    nonisolated private static func constantTimeEqual(_ a: String?, _ b: String) -> Bool {
        guard let a else { return false }
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = x.count ^ y.count
        for i in 0..<max(x.count, y.count) {
            diff |= Int(i < x.count ? x[i] : 0) ^ Int(i < y.count ? y[i] : 0)
        }
        return diff == 0
    }

    /// Redact a secret for logging — show only a short prefix.
    nonisolated private static func redact(_ s: String) -> String { s.isEmpty ? "—" : "\(s.prefix(8))…" }

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
            // Pause the edge-hover so the panel stops popping up on its own; ✓ when reveal is on.
            let hover = NSMenuItem(title: "Reveal on Edge Hover", action: #selector(toggleHover), keyEquivalent: "")
            hover.state = (controller?.hoverEnabled ?? true) ? .on : .off
            let pair = NSMenuItem(title: "Pair iPhone…", action: #selector(showPairing), keyEquivalent: "")
            let quit = NSMenuItem(title: "Quit EdgePanel", action: #selector(quit), keyEquivalent: "q")
            for it in [toggle, hover, pair, quit] { it.target = self }
            menu.addItem(toggle); menu.addItem(hover); menu.addItem(pair); menu.addItem(.separator()); menu.addItem(quit)
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
        } else {
            togglePanel()
        }
    }

    @objc private func togglePanel() { controller?.toggle() }
    /// Turn edge-hover reveal on/off. When off, the panel only opens from the menu/hotkey
    /// (or a permission request) — so it can't pop up on its own. Persisted across restarts.
    @objc private func toggleHover() {
        guard let c = controller else { return }
        c.hoverEnabled.toggle()
        UserDefaults.standard.set(c.hoverEnabled, forKey: "edgepanel.hoverEnabled")
        if !c.hoverEnabled { c.dismiss() }   // pausing hides it right away
    }
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
