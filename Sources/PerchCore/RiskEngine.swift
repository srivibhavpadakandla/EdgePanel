import Foundation

/// A risk verdict with a human reason, replacing naive keyword matching.
public struct RiskAssessment: Sendable, Equatable {
    public let level: RiskLevel
    public let reason: String          // short human explanation, e.g. "recursive delete"
    public let alwaysDangerous: Bool   // passive-guardian: prompt even when auto-allowing
}

/// Parses what a tool actually wants to do and assigns risk + a reason.
///
/// Far more accurate than keyword matching: `rm file.txt` is amber, `rm -rf ~`
/// is red; `git push` to a branch is amber, `--force` to `main` is red; `curl
/// localhost` is calm, `curl … | sh` is red. `alwaysDangerous` marks the things
/// passive-guardian mode should *always* surface even while auto-allowing.
public enum RiskEngine {

    public static func assess(toolName: String?, event: HookEvent? = nil,
                              command: String? = nil, filePath: String? = nil,
                              cwd: String? = nil) -> RiskAssessment {
        let name = (toolName ?? "").lowercased()
        // Keep the full action after the server prefix (mcp__server__delete_file →
        // "delete_file"), not just the last underscore segment ("file"), so the
        // verb that drives risk classification isn't dropped.
        let bare = name.hasPrefix("mcp__") ? name.components(separatedBy: "__").dropFirst(2).joined(separator: "_") : name

        if name == "bash" || bare.contains("bash") || bare.contains("shell") {
            return assessCommand(command ?? event?.command ?? "")
        }
        if let path = filePath ?? event?.filePath {
            return assessFile(tool: bare, path: path, cwd: cwd ?? event?.cwd)
        }
        if bare.contains("read") || bare.contains("grep") || bare.contains("glob") || bare.contains("ls") || bare.contains("list") || bare.contains("search") {
            return RiskAssessment(level: .read, reason: "read-only", alwaysDangerous: false)
        }
        if bare.contains("write") || bare.contains("edit") || bare.contains("create") || bare.contains("update") {
            return RiskAssessment(level: .write, reason: "modifies a file", alwaysDangerous: false)
        }
        if bare.contains("fetch") || bare.contains("web") || bare.contains("http") {
            return RiskAssessment(level: .danger, reason: "network access", alwaysDangerous: false)
        }
        if bare.contains("delete") || bare.contains("remove") || bare.contains("deploy") || bare.contains("publish") || bare.contains("kill") {
            return RiskAssessment(level: .danger, reason: "destructive action", alwaysDangerous: true)
        }
        return RiskAssessment(level: .unknown, reason: "needs approval", alwaysDangerous: false)
    }

    // MARK: - Bash command parsing

    /// Transparent prefixes we step THROUGH to find the real command, so a
    /// dangerous command can't hide behind `time`/`env`/`sudo`/etc. or an
    /// env-assignment. (sudo/doas are stepped through AND flagged.)
    private static let wrappers: Set<String> = [
        "time", "nohup", "env", "xargs", "command", "exec", "builtin",
        "nice", "ionice", "stdbuf", "setsid", "timeout", "sudo", "doas",
    ]

    /// The command-position tokens of each `;`/`&`/`|`/newline/subshell segment:
    /// every wrapper it passes through PLUS the first real command. Env-var
    /// assignments (FOO=bar) are skipped. Lets us detect `time rm`, `FOO=1 rm`,
    /// `  rm`, `(rm …)`, `sudo rm` — all the anchored-regex bypasses.
    private static func commandLeaders(_ cmd: String) -> Set<String> {
        var result: Set<String> = []
        for seg in cmd.split(whereSeparator: { ";&|\n`()".contains($0) }) {
            for tok in seg.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) {
                if tok.range(of: #"^\w+=.*"#, options: .regularExpression) != nil { continue }  // env assignment
                result.insert(tok)
                if !wrappers.contains(tok) { break }   // reached the real command
            }
        }
        return result
    }

    /// First quoted payload (for `bash -c "…"` → assess the inner command).
    private static func quotedPayload(_ raw: String) -> String? {
        for q: Character in ["\"", "'"] {
            if let s = raw.firstIndex(of: q),
               let e = raw[raw.index(after: s)...].firstIndex(of: q) {
                return String(raw[raw.index(after: s)..<e])
            }
        }
        return nil
    }

    private static func assessCommand(_ raw: String, depth: Int = 0) -> RiskAssessment {
        let cmd = raw.lowercased()
        let leaders = commandLeaders(cmd)

        // Pipe-to-shell — the classic remote-exec footgun.
        if (cmd.contains("curl ") || cmd.contains("wget ")) && (cmd.contains("| sh") || cmd.contains("|sh") || cmd.contains("| bash") || cmd.contains("|bash")) {
            return red("pipes a download into a shell", always: true)
        }
        // Fork bomb / disk wipe.
        if cmd.contains(":(){") { return red("fork bomb", always: true) }
        if cmd.contains("mkfs") || cmd.range(of: #"\bdd\b.*of="#, options: .regularExpression) != nil {
            return red("writes raw disk", always: true)
        }
        // Privilege escalation (wrapper-aware).
        if !leaders.isDisjoint(with: ["sudo", "doas"]) {
            return red("runs as root (sudo)", always: true)
        }
        // Inline code execution — can do anything, so always surface.
        if !leaders.isDisjoint(with: ["python", "python3", "node", "ruby", "perl", "osascript", "php"]),
           cmd.range(of: #"\s-(c|e)\b"#, options: .regularExpression) != nil {
            return red("runs an inline script", always: true)
        }
        if leaders.contains("eval") { return red("evaluates a dynamic command", always: true) }
        if !leaders.isDisjoint(with: ["nc", "ncat", "socat"]),
           cmd.range(of: #"\s-e\b"#, options: .regularExpression) != nil || cmd.contains(" exec") {
            return red("opens a reverse shell", always: true)
        }
        if leaders.contains("crontab") { return red("edits scheduled jobs", always: true) }
        if leaders.contains("launchctl"), cmd.range(of: #"\b(load|bootstrap|enable|submit)\b"#, options: .regularExpression) != nil {
            return red("loads a launch agent", always: true)
        }
        // Shell -c "<payload>": assess the wrapped command itself.
        if depth < 3, !leaders.isDisjoint(with: ["bash", "sh", "zsh", "dash", "ksh"]),
           cmd.range(of: #"\s-c\b"#, options: .regularExpression) != nil,
           let payload = quotedPayload(raw) {
            return assessCommand(payload, depth: depth + 1)
        }
        // rm — depends on recursion + target breadth.
        if leaders.contains("rm") {
            let recursive = cmd.range(of: #"\brm\b[^;&|]*\s-\w*[rf]"#, options: .regularExpression) != nil
            let broadTarget = cmd.contains(" / ") || cmd.hasSuffix(" /") || cmd.contains(" ~") || cmd.contains("/*") || cmd.contains("$home")
            if recursive && broadTarget { return red("recursive delete of a broad path", always: true) }
            if recursive { return red("recursive delete", always: true) }
            return amber("deletes a file")
        }
        // git push — force to a protected branch is the scary one.
        if cmd.contains("git push") {
            let force = cmd.contains("--force") || cmd.range(of: #"\s-f(\s|$)"#, options: .regularExpression) != nil || cmd.contains("+")
            let protected = cmd.contains("main") || cmd.contains("master") || cmd.contains("prod") || cmd.contains("release")
            if force && protected { return red("force-push to a protected branch", always: true) }
            if force { return red("force-push") }
            return amber("pushes to a remote")
        }
        if cmd.contains("git reset --hard") || cmd.contains("git clean -") { return red("discards uncommitted work") }
        // System paths.
        if cmd.range(of: #">\s*/(etc|usr|bin|sbin|system|library)"#, options: .regularExpression) != nil
            || cmd.range(of: #"\b(chmod|chown)\b.*\s/(etc|usr|bin|sbin|system)"#, options: .regularExpression) != nil {
            return red("touches a system path")
        }
        // Process control / shutdown.
        if cmd.contains("killall") || cmd.contains("pkill") || cmd.range(of: #"(^|\s)kill\s+-9"#, options: .regularExpression) != nil {
            return red("kills processes")
        }
        if cmd.contains("shutdown") || cmd.contains("reboot") { return red("shuts down / reboots", always: true) }
        // Publishing / deploys.
        if cmd.contains("npm publish") || cmd.contains("pod trunk push") || cmd.contains("gh release create") {
            return red("publishes a release", always: true)
        }
        // Network egress (non-piped).
        if cmd.contains("curl ") || cmd.contains("wget ") {
            if cmd.contains("127.0.0.1") || cmd.contains("localhost") {
                return RiskAssessment(level: .read, reason: "local request", alwaysDangerous: false)
            }
            return amber("network request")
        }
        // Package installs — worth a glance, not always-dangerous.
        if cmd.range(of: #"\b(npm|pnpm|yarn|brew|pip|pip3|gem|cargo)\b.*(install|add|uninstall)"#, options: .regularExpression) != nil {
            return amber("installs/removes packages")
        }
        // Mutating git / file moves.
        if cmd.contains("git commit") || cmd.contains("git merge") || cmd.contains("git rebase") || cmd.contains("mv ") || cmd.contains("> ") {
            return amber("modifies files / history")
        }
        return RiskAssessment(level: .read, reason: "safe command", alwaysDangerous: false)
    }

    // MARK: - File tool parsing

    private static func assessFile(tool: String, path: String, cwd: String?) -> RiskAssessment {
        let p = (path as NSString).expandingTildeInPath
        let lower = p.lowercased()
        let inSystem = lower.hasPrefix("/etc") || lower.hasPrefix("/usr") || lower.hasPrefix("/system") || lower.hasPrefix("/library") || lower.hasPrefix("/private/etc")
        let inWorkspace = cwd.map { p.hasPrefix(($0 as NSString).expandingTildeInPath) } ?? false
        let writing = tool.contains("write") || tool.contains("edit") || tool.contains("create")

        if inSystem {
            return RiskAssessment(level: .danger, reason: writing ? "writes a system file" : "reads a system file", alwaysDangerous: writing)
        }
        if writing {
            return RiskAssessment(level: .write, reason: inWorkspace ? "edits a project file" : "writes outside the workspace", alwaysDangerous: false)
        }
        return RiskAssessment(level: .read, reason: inWorkspace ? "reads a project file" : "reads outside the workspace", alwaysDangerous: false)
    }

    private static func red(_ reason: String, always: Bool = false) -> RiskAssessment {
        RiskAssessment(level: .danger, reason: reason, alwaysDangerous: always)
    }
    private static func amber(_ reason: String) -> RiskAssessment {
        RiskAssessment(level: .write, reason: reason, alwaysDangerous: false)
    }
}
