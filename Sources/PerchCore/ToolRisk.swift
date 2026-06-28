import Foundation

/// Risk classification for a tool the agent wants to run, driving the capsule's
/// color. Read = calm (green), write = amber, anything that runs code, hits the
/// network, or destroys/pushes = red.
public enum RiskLevel: String, Sendable {
    case read     // green — read/grep/glob/list
    case write    // amber — write/edit/create
    case danger   // red — Bash, network, rm, git push, deploy, …
    case unknown  // neutral — unrecognized tool

    /// Severity ordering, so multi-statement commands can take the most severe.
    public var rank: Int {
        switch self { case .read: return 0; case .unknown: return 1; case .write: return 2; case .danger: return 3 }
    }
}

public enum ToolRisk {
    /// Known first-party Claude Code tools, classified exactly.
    private static let known: [String: RiskLevel] = [
        "read": .read, "glob": .read, "grep": .read, "ls": .read,
        "notebookread": .read, "todoread": .read, "todowrite": .read,
        "write": .write, "edit": .write, "multiedit": .write, "notebookedit": .write,
        "bash": .danger, "webfetch": .danger, "websearch": .danger,
        "killshell": .danger, "bashoutput": .read,
    ]

    /// Classify by tool name plus an optional `detail` (e.g. a Bash command line),
    /// which can escalate an otherwise-tame tool to `.danger`.
    public static func classify(toolName: String?, detail: String?) -> RiskLevel {
        let name = (toolName ?? "").lowercased()
        let detail = (detail ?? "").lowercased()

        // mcp__server__delete_file  ->  "delete_file" (keep the action verb).
        let bare: String = name.hasPrefix("mcp__")
            ? name.components(separatedBy: "__").dropFirst(2).joined(separator: "_")
            : name

        // A dangerous command line trumps the tool's nominal category.
        if isDangerousCommand(detail) { return .danger }

        if let exact = known[bare] { return exact }

        // Keyword fallback for custom / MCP tools.
        if containsAny(bare, ["bash", "shell", "terminal", "exec", "spawn", "kill",
                              "deploy", "publish", "delete", "destroy", "remove", "drop",
                              "payment", "transfer", "fetch", "http", "network", "push"]) {
            return .danger
        }
        if containsAny(bare, ["write", "edit", "create", "update", "insert", "modify",
                              "move", "rename", "patch", "apply", "store", "save", "upload"]) {
            return .write
        }
        if containsAny(bare, ["read", "grep", "glob", "list", "search", "get",
                              "view", "find", "status", "query", "fetch"]) {
            return .read
        }
        return .unknown
    }

    /// True when a command line is risky enough to be worth approving
    /// (destructive, network egress, privilege, force-push, etc.). Safe
    /// commands (ls, cat, echo, git status, builds, …) return false.
    public static func isDangerousCommand(_ command: String) -> Bool {
        let detail = command.lowercased()
        let needles = ["rm ", "rm -", "git push", "git reset --hard", "sudo ", "curl ",
                       "wget ", "mkfs", "dd ", ":(){", "chmod ", "chown ", "killall",
                       "shutdown", "reboot", "npm publish", "--force", "-f ", "> /",
                       "rimraf", "--hard", "git clean", "brew uninstall", "kill ", "pkill"]
        return needles.contains { detail.contains($0) }
    }

    private static func containsAny(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack == $0 || haystack.contains($0) }
    }
}
