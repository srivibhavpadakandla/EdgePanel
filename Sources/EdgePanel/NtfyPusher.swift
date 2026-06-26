// NtfyPusher — free "push even when EdgePanel is fully closed", without Apple's
// paid APNs. The Mac (always running) POSTs to an ntfy topic; the ntfy app on the
// phone shows the notification — a "done" alert, or a permission alert with real
// Allow / Deny / Always buttons that POST back to this Mac's /permission/decide.
//
// GATED behind ~/.edgepanel/ntfy.json — absent ⇒ disabled:
//   { "server": "https://ntfy.sh", "topic": "edgepanel-7f3k9q",
//     "macHost": "100.98.159.7:8788", "token": "<pairing token>" }
// server defaults to https://ntfy.sh. macHost + token let the action buttons reach
// this Mac (use the Tailscale IP so it works off your LAN). The topic name is the
// only access control on the public server — keep it unguessable or self-host.

import Foundation

struct NtfyConfig {
    let server: String
    let topic: String
    let macHost: String?
    let token: String?

    static func load() -> NtfyConfig? {
        let path = ("~/.edgepanel/ntfy.json" as NSString).expandingTildeInPath
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
    private let config = NtfyConfig.load()
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
        if let host = config?.macHost, let token = config?.token, !host.isEmpty, !token.isEmpty {
            let url = "http://\(host)/permission/decide"
            func action(_ label: String, _ decision: String) -> [String: Any] {
                ["action": "http", "label": label, "url": url, "method": "POST",
                 "headers": ["X-EdgePanel-Token": token],
                 "body": "{\"id\":\"\(id)\",\"decision\":\"\(decision)\"}", "clear": true]
            }
            payload["actions"] = [action("Allow", "allow"), action("Deny", "deny"), action("Always", "always")]
        }
        publish(payload)
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
