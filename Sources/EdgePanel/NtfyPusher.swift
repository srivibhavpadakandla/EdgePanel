// NtfyPusher — free "push even when EdgePanel is fully closed", without Apple's
// paid APNs. The Mac (always running) POSTs to an ntfy topic; the ntfy app on the
// phone shows the notification — a "done" alert, or a permission alert with real
// Allow / Deny / Always buttons that POST back to this Mac's /permission/decide.
//
// GATED behind ~/.edgepanel/ntfy.json — absent ⇒ disabled:
//   { "server": "https://ntfy.sh", "topic": "edgepanel-7f3k9q",
//     "macHost": "https://your-mac.your-tailnet.ts.net" }
// server defaults to https://ntfy.sh. macHost lets the action buttons reach this Mac
// (use the HTTPS Tailscale Serve URL) — each button carries only a
// scoped, single-permission action token (EdgePanelAuth.actionToken), never the raw
// pairing token, since ntfy.sh is a public third-party relay. The topic name is the
// only access control on the public server — keep it unguessable or self-host.
// "token" is accepted for backward compat but no longer used or required.

import Foundation

struct NtfyConfig {
    let server: String
    let topic: String
    let macHost: String?
    let token: String?
    static let path = ("~/.edgepanel/ntfy.json" as NSString).expandingTildeInPath

    static func load() -> NtfyConfig? {
        guard let data = FileManager.default.contents(atPath: path),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let topic = (j["topic"] as? String), !topic.isEmpty else { return nil }
        var server = (j["server"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "https://ntfy.sh"
        if server.hasSuffix("/") { server.removeLast() }
        return NtfyConfig(server: server, topic: topic,
                          macHost: j["macHost"] as? String, token: j["token"] as? String)
    }
}

final class NtfyPusher: @unchecked Sendable {
    static let shared = NtfyPusher()
    // Re-checked (cheap stat, not a re-parse) on every push rather than loaded once at singleton
    // init — see TelegramPusher's identical pattern for why: editing ntfy.json without a relaunch
    // must not leave the channel silently stale.
    private let lock = NSLock()
    private var cached: NtfyConfig?
    private var cachedModDate: Date?
    private var config: NtfyConfig? {
        lock.lock(); defer { lock.unlock() }
        let modDate = (try? FileManager.default.attributesOfItem(atPath: NtfyConfig.path)[.modificationDate] as? Date) ?? nil
        if modDate != cachedModDate {
            cached = NtfyConfig.load()
            cachedModDate = modDate
        }
        return cached
    }
    var enabled: Bool { config != nil }

    /// "✓ project finished · 2m 14s · 26K tokens"
    func pushDone(title: String, detail: String) {
        publish(["title": title, "message": detail, "tags": ["white_check_mark"], "priority": 3])
    }

    /// A permission alert carrying Allow / Deny / Always buttons that POST the
    /// decision back to this Mac (when macHost + token are configured).
    func pushPermission(id: String, tool: String, summary: String, risk: String) {
        var payload: [String: Any] = [
            "title": "\(tool) needs approval",
            "message": summary.isEmpty ? "Tap Allow or Deny" : summary,
            "tags": [risk == "danger" ? "rotating_light" : "lock"],
            "priority": 5]
        if let host = config?.macHost, !host.isEmpty {
            let base = host.hasSuffix("/") ? String(host.dropLast()) : host
            guard base.lowercased().hasPrefix("https://") else {
                NSLog("ntfy permission actions disabled: macHost must be an HTTPS URL")
                publish(payload); return
            }
            let url = "\(base)/permission/decide"
            // A scoped per-action token (see EdgePanelAuth), NOT the raw pairing token — ntfy.sh
            // is a public third-party relay by default, and the raw token would grant whoever
            // reads that topic full LAN control instead of just this one permission decision.
            func action(_ label: String, _ decision: String) -> [String: Any] {
                ["action": "http", "label": label, "url": url, "method": "POST",
                 "headers": ["X-EdgePanel-Action-Token": EdgePanelAuth.actionToken(id: id, decision: decision)],
                 "body": "{\"id\":\"\(id)\",\"decision\":\"\(decision)\"}", "clear": true]
            }
            payload["actions"] = [action("Allow", "allow"), action("Deny", "deny"), action("Always", "always")]
        }
        publish(payload)
    }

    /// "Claude is asking you" — tap to answer in the EdgePanel app (the options are
    /// shown there; questions can be multi-select / multi-question so we don't try
    /// to cram them into notification buttons).
    func pushQuestion(title: String, body: String) {
        publish(["title": title, "message": body, "tags": ["question"], "priority": 4])
    }

    private func publish(_ fields: [String: Any]) {
        guard let config else { return }
        var body = fields
        body["topic"] = config.topic
        guard let url = URL(string: config.server),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = data
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            if let code = (resp as? HTTPURLResponse)?.statusCode, code >= 300 {
                NSLog("ntfy publish failed: HTTP \(code)")
            }
        }.resume()
    }
}
