import Foundation
import PerchCore

/// The decision returned for a held `PreToolUse` permission request, copied from
/// Perch. Blocking happens via the verified HTTP-hook contract: `2xx` + JSON.
enum PermissionVerdict: String, Sendable {
    case allow
    case deny
    case ask   // fall back to Claude Code's native flow

    func response(for eventName: String) -> HTTPResponse {
        switch self {
        case .ask:
            return .hookAck()   // empty 200 → native flow proceeds (also the timeout default)
        case .allow, .deny:
            if eventName == "PermissionRequest" {
                return .jsonObject([
                    "hookSpecificOutput": [
                        "hookEventName": "PermissionRequest",
                        "decision": ["behavior": rawValue],
                    ],
                ])
            }
            return .jsonObject([
                "hookSpecificOutput": [
                    "hookEventName": "PreToolUse",
                    "permissionDecision": rawValue,
                    "permissionDecisionReason": self == .allow ? "Allowed from EdgePanel" : "Denied from EdgePanel",
                ],
            ])
        }
    }
}
