import Foundation
import PerchCore

/// Writes "always allow" rules into Claude Code's *own* permission allowlist
/// (`~/.claude/settings.json` → `permissions.allow`). Copied from Perch — we
/// integrate with Claude Code's engine, not a parallel one.
enum AllowlistWriter {
    static let settingsPath = ("~/.claude/settings.json" as NSString).expandingTildeInPath
    /// Serializes the read-modify-write so two concurrent "Always" taps can't
    /// clobber each other's rule.
    private static let lock = NSLock()

    static func rule(for event: HookEvent) -> String {
        let tool = event.toolName ?? "Bash"
        if tool == "Bash", let cmd = event.command {
            var tokens = cmd.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            // Skip env-assignments (FOO=bar) so the rule keys off the real command, not
            // the prefix (else "FOO=1 rm" → a nonsense "Bash(FOO=1 *)" grant).
            while let f = tokens.first, f.range(of: #"^\w+=.*"#, options: .regularExpression) != nil { tokens.removeFirst() }
            guard let first = tokens.first, isSafeRuleToken(first) else { return "Bash" }
            // Never mint a wildcard grant for a privilege/wrapper command — "Bash(sudo *)"
            // would auto-allow EVERY sudo command. Fall back to a re-ask ("Bash").
            let wrappers: Set<String> = ["sudo", "doas", "env", "time", "nohup", "xargs", "exec",
                                         "command", "nice", "ionice", "stdbuf", "setsid", "timeout", "eval"]
            if wrappers.contains(first) { return "Bash" }
            let subcommanded = ["git", "npm", "pnpm", "yarn", "brew", "docker", "kubectl", "gh", "cargo", "pip", "pip3"]
            if tokens.count >= 2, subcommanded.contains(first), isSafeRuleToken(tokens[1]) {
                return "Bash(\(first) \(tokens[1]) *)"
            }
            return "Bash(\(first) *)"
        }
        if let path = event.filePath {
            let dir = (path as NSString).deletingLastPathComponent
            if isSafeRuleToken(dir), !dir.isEmpty { return "\(tool)(\(dir)/**)" }
            // No directory (relative/bare path) → scope to THIS file, not the whole tool
            // (a bare "Write" rule would grant writing every file).
            if isSafeRuleToken(path) { return "\(tool)(\(path))" }
            return tool
        }
        return tool
    }

    private static func isSafeRuleToken(_ s: String) -> Bool {
        !s.isEmpty && s.range(of: #"[()\n\r*]"#, options: .regularExpression) == nil
    }

    @discardableResult
    static func add(rule: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let data = FileManager.default.contents(atPath: settingsPath),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            NSLog("EdgePanel always-allow FAILED (no/invalid settings.json) — rule not persisted: \(rule)")
            return false
        }
        var perms = (obj["permissions"] as? [String: Any]) ?? [:]
        var allow = (perms["allow"] as? [String]) ?? []
        if allow.contains(rule) { return true }
        allow.append(rule)
        perms["allow"] = allow
        obj["permissions"] = perms
        guard let out = try? JSONSerialization.data(withJSONObject: obj,
                                                    options: [.prettyPrinted, .withoutEscapingSlashes]) else {
            NSLog("EdgePanel always-allow FAILED (serialize) — rule not persisted: \(rule)")
            return false
        }
        do {
            try out.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
            NSLog("EdgePanel always-allow → added rule: \(rule)")
            return true
        } catch {
            NSLog("EdgePanel always-allow FAILED (write: \(error.localizedDescription)) — rule not persisted: \(rule)")
            return false
        }
    }
}
