import AppIntents
import Foundation

/// Interactive Live Activity button action: Allow / Deny / Always for a held permission.
///
/// Rendered as `Button(intent:)` in the Lock Screen + Dynamic Island permission UI. As a
/// `LiveActivityIntent` it runs WITHOUT bringing the app to the foreground, so it reads the Mac
/// host + pairing token from the shared App Group (mirrored there by the app) and POSTs the
/// decision straight to the Mac's `/permission/decide`. The user approves without opening the app.
@available(iOS 17.0, *)
struct PermissionDecisionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Decide Permission"
    static var isDiscoverable: Bool = false   // not a user-facing Shortcuts action

    @Parameter(title: "Permission ID") var permId: String
    @Parameter(title: "Decision") var decision: String   // "allow" | "deny" | "always"

    init() {}
    init(permId: String, decision: String) {
        self.permId = permId
        self.decision = decision
    }

    func perform() async throws -> some IntentResult {
        await PermissionDecider.send(permId: permId, decision: decision)
        return .result()
    }
}

/// Fire-and-forget POST of a permission decision to the Mac, authenticated with the App Group
/// pairing token. Isolated from the app's `EdgeClient` so it works in the extension/intent process.
enum PermissionDecider {
    static func send(permId: String, decision: String) async {
        guard !permId.isEmpty,
              let conn = UsageShared.readConn(),
              let url = endpoint(host: conn.host, path: "permission/decide") else { return }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue(conn.token, forHTTPHeaderField: "X-EdgePanel-Token")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["id": permId, "decision": decision])
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Mirror of `EdgeClient.endpoint`: plain HTTP is accepted only on loopback or Tailscale's
    /// address ranges (already inside the WireGuard tunnel); everything else must be HTTPS. A
    /// scheme-less host is upgraded to HTTPS. Kept in sync so the intent never leaks the token
    /// over cleartext to a public host.
    private static func endpoint(host rawHost: String, path: String) -> URL? {
        let raw = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let normalized = raw.contains("://") ? raw : "https://\(raw)"
        guard let base = URL(string: normalized), let scheme = base.scheme?.lowercased() else { return nil }
        let loopback = base.host == "127.0.0.1" || base.host == "localhost" || base.host == "::1"
        let tailnet: Bool = {
            guard let h = base.host?.lowercased() else { return false }
            let parts = h.split(separator: ".")
            if parts.count == 4 {
                let octets = parts.compactMap { UInt8($0) }
                if octets.count == 4, octets[0] == 100, (64...127).contains(octets[1]) { return true }
            }
            return h.hasPrefix("fd7a:115c:a1e0:")
        }()
        guard scheme == "https" || (scheme == "http" && (loopback || tailnet)) else { return nil }
        return base.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
}
