// APNsPusher — Tier 2: pushes Live Activity updates / alerts to the iPhone via
// Apple Push Notification service, so "done" and "permission needed" land even
// when the companion app is fully closed or off the home network.
//
// GATED behind ~/.edgepanel/apns.json — absent ⇒ disabled (Tier 1 local only):
//   { "teamId": "ABCDE12345", "keyId": "KEY1234567",
//     "keyPath": "~/.edgepanel/AuthKey_KEY1234567.p8",
//     "bundleId": "com.srivibhav.edgepanel.mobile" }
//
// You create the .p8 (APNs Auth Key) + IDs in your paid Apple Developer account.
// UNTESTED here — it needs that key + a real device to exercise. Code follows
// Apple's token-based APNs + Live Activity push contract.

import Foundation
import CryptoKit

struct APNsConfig {
    let teamId, keyId, bundleId, host: String
    let key: P256.Signing.PrivateKey

    static func load() -> APNsConfig? {
        let url = (("~/.edgepanel/apns.json" as NSString).expandingTildeInPath as String)
        guard let data = FileManager.default.contents(atPath: url),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let team = j["teamId"] as? String, let kid = j["keyId"] as? String,
              let bundle = j["bundleId"] as? String, let keyPath = j["keyPath"] as? String else { return nil }
        let pemPath = (keyPath as NSString).expandingTildeInPath
        guard let pem = try? String(contentsOfFile: pemPath, encoding: .utf8),
              let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) else { return nil }
        // Dev/sideloaded builds (aps-environment:development) get SANDBOX tokens, which
        // must be pushed via the sandbox host. Set "env":"production" for App Store builds.
        let env = (j["env"] as? String)?.lowercased() ?? "sandbox"
        let host = env == "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com"
        return APNsConfig(teamId: team, keyId: kid, bundleId: bundle, host: host, key: key)
    }
}

final class APNsPusher: @unchecked Sendable {
    static let shared = APNsPusher()
    private let config = APNsConfig.load()
    private var cachedJWT: (token: String, at: Date)?
    private let lock = NSLock()

    var enabled: Bool { config != nil }

    /// Push a Live Activity event ("update" or "end") to a per-activity token.
    func pushActivity(token: String, event: String, contentState: [String: Any], alert: [String: Any]? = nil) {
        guard let config else { return }
        var aps: [String: Any] = ["timestamp": Int(Date().timeIntervalSince1970),
                                  "event": event, "content-state": contentState]
        // Keep an `update` fresh (not coalesced away as redundant) through the brief
        // window before the matching `end` lands.
        if event == "update" { aps["stale-date"] = Int(Date().addingTimeInterval(600).timeIntervalSince1970) }
        // Show the "done" screen briefly, then auto-dismiss.
        if event == "end" { aps["dismissal-date"] = Int(Date().addingTimeInterval(6).timeIntervalSince1970) }
        if let alert { aps["alert"] = alert }
        // Apple throttles frequent priority-10 content updates — routine "update" pushes
        // go at priority 5; "end" (and the one-off alert it carries) stay at 10.
        send(token: token, payload: ["aps": aps],
             topic: "\(config.bundleId).push-type.liveactivity", pushType: "liveactivity",
             priority: event == "update" ? 5 : 10)
    }

    /// Push-to-start (iOS 17.2+): create the Live Activity even when the app isn't
    /// running, so the Dynamic Island pops up on its own when work begins.
    func pushStart(token: String, contentState: [String: Any], attributes: [String: Any]) {
        guard let config else { return }
        let aps: [String: Any] = [
            "timestamp": Int(Date().timeIntervalSince1970),
            "event": "start",
            "content-state": contentState,
            "attributes-type": "WorkingAttributes",
            "attributes": attributes,
            "alert": ["title": "Claude is working", "body": "tap to watch it live"]
        ]
        send(token: token, payload: ["aps": aps],
             topic: "\(config.bundleId).push-type.liveactivity", pushType: "liveactivity")
    }

    /// Push a plain alert notification to the device token (usage / done fallback).
    func pushAlert(deviceToken: String, title: String, body: String) {
        guard let config else { return }
        let payload: [String: Any] = ["aps": ["alert": ["title": title, "body": body], "sound": "default"]]
        send(token: deviceToken, payload: payload, topic: config.bundleId, pushType: "alert")
    }

    /// Push an actionable "permission needed" alert (category PERMISSION → Allow/Deny
    /// buttons on the Lock Screen). Carries the request id so the tap resolves it.
    func pushPermission(deviceToken: String, id: String, title: String, body: String) {
        guard let config else { return }
        let payload: [String: Any] = [
            "aps": ["alert": ["title": title, "body": body], "sound": "default",
                    "category": "PERMISSION", "mutable-content": 1],
            "permId": id]
        send(token: deviceToken, payload: payload, topic: config.bundleId, pushType: "alert")
    }

    private func send(token: String, payload: [String: Any], topic: String, pushType: String, priority: Int = 10) {
        let host = config?.host ?? "api.sandbox.push.apple.com"
        guard let url = URL(string: "https://\(host)/3/device/\(token)"),
              let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("bearer \(jwt())", forHTTPHeaderField: "authorization")
        req.setValue(topic, forHTTPHeaderField: "apns-topic")
        req.setValue(pushType, forHTTPHeaderField: "apns-push-type")
        req.setValue("\(priority)", forHTTPHeaderField: "apns-priority")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if code == 200 {
                NSLog("APNs \(pushType) push OK")
            } else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? err?.localizedDescription ?? ""
                NSLog("APNs \(pushType) push FAILED: HTTP \(code) \(body)")   // e.g. BadDeviceToken / TopicDisallowed / ExpiredProviderToken
            }
        }.resume()
    }

    /// Token-based APNs JWT (ES256), cached ~50 min.
    private func jwt() -> String {
        lock.lock(); defer { lock.unlock() }
        if let c = cachedJWT, Date().timeIntervalSince(c.at) < 3000 { return c.token }
        guard let config else { return "" }
        let header = b64(["alg": "ES256", "kid": config.keyId])
        let claims = b64(["iss": config.teamId, "iat": Int(Date().timeIntervalSince1970)])
        let signingInput = "\(header).\(claims)"
        guard let sig = try? config.key.signature(for: Data(signingInput.utf8)) else { return "" }
        let token = "\(signingInput).\(b64url(sig.rawRepresentation))"
        cachedJWT = (token, Date())
        return token
    }

    private func b64(_ obj: [String: Any]) -> String {
        b64url((try? JSONSerialization.data(withJSONObject: obj)) ?? Data())
    }
    private func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
