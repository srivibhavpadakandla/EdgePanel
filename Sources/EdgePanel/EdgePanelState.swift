// EdgePanelState — hook-driven activity for the panel. Phase 1 tracks the live
// status line ("Baking…" / running / done) from Claude Code hook events and the
// statusline feed. Phases 2–3 extend it (permission gate, activity feed,
// multi-session) on top of this.

import SwiftUI
import Foundation
import PerchCore

/// One line of a permission preview (a command line, or a diff add/remove).
struct PreviewLine: Identifiable, Equatable {
    enum Kind { case added, removed, context }
    let id = UUID()
    let kind: Kind
    let text: String
}

/// A multiple-choice question (AskUserQuestion) the user can answer from the phone.
struct PendingQuestion: Identifiable, Equatable {
    struct Option: Equatable { let label: String; let description: String? }
    struct Item: Equatable {
        let question: String
        let header: String
        let multiSelect: Bool
        let options: [Option]
    }
    let id: String
    let items: [Item]
    let project: String?
}

/// A permission request the user must approve from the panel.
struct PendingPermission: Identifiable, Equatable {
    let id: String
    let toolName: String
    let summary: String
    let reason: String
    let risk: RiskLevel
    let allowRule: String
    let preview: [PreviewLine]
    let project: String?
    var alwaysDangerous: Bool = false   // the irreversible 1% — still needs a tap even in Autonomous
}

@MainActor
final class EdgePanelState: ObservableObject {
    enum Phase { case idle, running, done, failed }

    @Published var phase: Phase = .idle
    @Published var activity: String?      // e.g. "Editing CapsuleView.swift"
    @Published var projectLabel: String?  // cwd basename of the latest event

    /// Statusline feed (secondary): live context % + session cost, if the
    /// statusline hook is wired. nil until it reports.
    @Published var statuslineContextPct: Double?
    @Published var sessionCostUSD: Double?

    // MARK: Held permission gate (Phase 2)
    @Published var pending: PendingPermission?
    /// Bridges to the window controller: true → lock open + auto-reveal.
    var onApprovalChange: ((Bool) -> Void)?
    /// Autonomous mode (toggled from the phone): auto-allow every permission so a
    /// session runs hands-off. Persisted so it survives a restart.
    @Published var autoApprove = UserDefaults.standard.bool(forKey: "edgepanel.autoApprove")
    func setAutoApprove(_ on: Bool) {
        autoApprove = on
        UserDefaults.standard.set(on, forKey: "edgepanel.autoApprove")
        // Drain EVERY held non-dangerous request (not just the surfaced one) so flipping
        // Autonomous on is truly hands-off — otherwise sibling held requests hang until their
        // 30s timeout. The irreversible 1% (alwaysDangerous) stays held for a tap, preserving
        // the Guardian guarantee. Snapshot the keys: resolve() mutates pendingById mid-loop.
        if on {
            for bid in Array(pendingById.keys) where pendingById[bid]?.alwaysDangerous == false {
                resolve(bid, .allow)
            }
        }
    }

    /// PANIC STOP: kill every running chat turn, turn Autonomous off, deny everything
    /// currently held, and refuse new (non-read) permissions for a short window so a
    /// runaway turn can't slip an approval through in the gap. Returns turns killed.
    @Published var panicArmed = false
    @discardableResult
    func panic() -> Int {
        setAutoApprove(false)
        panicArmed = true
        for bid in Array(resolvers.keys) { resolve(bid, .deny) }   // deny all held permission requests
        for qid in Array(questionResolvers.keys) { resolveQuestion(qid, [:]) }   // dismiss all held questions
        let killed = ChatRunner.shared.cancelAll()
        panicResetTimer?.invalidate()
        panicResetTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.panicArmed = false }
        }
        return killed
    }
    private var panicResetTimer: Timer?

    // MARK: Held AskUserQuestion gate (answer from the phone)
    @Published var pendingQuestion: PendingQuestion?
    private var questionResolvers: [String: CheckedContinuation<[String: String], Never>] = [:]
    private var questionCounter = 0

    private var resolvers: [String: CheckedContinuation<PermissionVerdict, Never>] = [:]
    private var pendingRules: [String: String] = [:]   // id → allow-rule (for "always", survives rotation)
    private var pendingById: [String: PendingPermission] = [:]   // id → request (to re-surface the next one on resolve)
    private var blockingCounter = 0
    private let decisionTimeout: TimeInterval = {
        // Clamp to [0, 3600]: a negative env value would trap on the later UInt64(...) cast,
        // and NaN/inf resolve to 30. Keeps the Task.sleep conversion safe for any input.
        let raw = TimeInterval(ProcessInfo.processInfo.environment["EDGEPANEL_DECISION_TIMEOUT"] ?? "") ?? 30
        return raw.isFinite ? min(max(raw, 0), 3600) : 30
    }()

    private var idleTimer: Timer?

    /// The footer status verb shown next to the asterisk.
    var statusVerb: String {
        switch phase {
        case .idle:    return "idle"
        case .running: return activity ?? "Baking…"
        case .done:    return "done"
        case .failed:  return "failed"
        }
    }
    var isActive: Bool { phase == .running }

    // MARK: - Hook ingestion (read-only /event)

    /// Current Claude Code permission mode (from the hook payload): "default" (Ask before
    /// edits), "acceptEdits" (Edit automatically), "plan", "bypassPermissions". Drives the
    /// mascot animation so the creature visibly reflects how hands-off the session is.
    @Published var permissionMode: String?
    /// Reasoning effort if a statusline ever surfaces it (Claude Code doesn't expose it to
    /// hooks today, so this stays nil unless a custom statusline emits "effort").
    @Published var effort: String?

    func handle(_ event: HookEvent) {
        if let label = event.projectLabel { projectLabel = label }
        if let pm = event.permissionMode, !pm.isEmpty { permissionMode = pm }
        switch event.eventName {
        case "UserPromptSubmit":
            setPhase(.running)
            activity = "Baking…"
        case "PreToolUse", "PostToolUse":
            setPhase(.running)
            activity = describe(event)
        case "Notification":
            setPhase(.running)
        case "Stop":
            setPhase(.done)
            activity = nil
            scheduleIdle()
        case "StopFailure", "SubagentStop":
            if event.eventName == "StopFailure" { setPhase(.failed); scheduleIdle() }
        default:
            break
        }
    }

    /// Statusline JSON forwarded by the statusline command (context %, cost).
    func updateStatusline(data: Data) {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let cw = j["context_window"] as? [String: Any],
           let used = (cw["used_percentage"] as? Double) ?? (cw["used_percentage"] as? NSNumber)?.doubleValue {
            statuslineContextPct = min(max(used / 100, 0), 1)
        }
        if let cost = j["cost"] as? [String: Any],
           let total = (cost["total_cost_usd"] as? Double) ?? (cost["total_cost_usd"] as? NSNumber)?.doubleValue {
            sessionCostUSD = total
        }
        // Reasoning effort, if a custom statusline emits it (stock Claude Code doesn't pass
        // it to hooks/statusline, so this stays nil otherwise — the mascot then leans on mode).
        let model = j["model"] as? [String: Any]
        if let e = (j["reasoning_effort"] as? String) ?? (j["effort"] as? String)
                    ?? (model?["reasoning_effort"] as? String), !e.isEmpty {
            effort = e
        }
    }

    // MARK: - Live mascot animation ------------------------------------------
    //
    // One pixel creature, many postures. We can only show ONE animation at a time,
    // so the axes are prioritised by "what does the human most need to read right
    // now": a waiting permission (its RISK) outranks how the session is running
    // (the permission MODE), which outranks how hard it's thinking (EFFORT), which
    // outranks idle. Each branch picks a visually distinct anim so a glance decodes
    // the session's posture — exactly the modes from Claude Code's picker.

    /// Mode collapsed to a stable key: "ask" | "edit" | "plan" | "auto" | "bypass".
    var normalizedMode: String {
        switch (permissionMode ?? "").lowercased() {
        case "bypasspermissions", "bypass":            return "bypass"
        case "acceptedits", "accept_edits", "edit":    return "edit"
        case "plan":                                   return "plan"
        case "auto":                                   return "auto"
        default:                                       return "ask"   // "default" / unknown
        }
    }

    /// Effort collapsed to: "low" | "medium" | "high" | "ultra" | "" (unknown).
    var normalizedEffort: String {
        let e = (effort ?? "").lowercased()
        if e.contains("ultra") || e.contains("max") { return "ultra" }
        if e.contains("high")  { return "high" }
        if e.contains("med")   { return "medium" }
        if e.contains("low")   { return "low" }
        return ""
    }

    /// The animation reflecting the live state. Drives both the panel mascot and the
    /// menu-bar icon, so the creature visibly changes with mode / risk / effort.
    var mascotAnimName: String {
        // 1. Panic stop armed — frozen alarm, nothing else matters.
        if panicArmed { return "expression_surprise" }
        // 2. A permission is waiting on a human — react to its RISK (low/med/high).
        if let p = pending {
            if p.alwaysDangerous || p.risk == .danger { return "expression_surprise" } // red: alarmed
            if p.risk == .write                       { return "idle_look_around" }     // amber: cautious
            return "idle_blink"                                                         // green: calm wait
        }
        if pendingQuestion != nil { return "idle_look_around" }                          // curious
        // 3. Working — the permission MODE sets the posture (bypass/auto/edit/plan/ask).
        if phase == .running {
            switch normalizedMode {
            case "bypass": return "dance_djmix"     // full send, no gate — most kinetic
            case "auto":   return "dance_sway"      // auto-pilot — smooth, hands-off
            case "edit":   return "work_coding"     // editing automatically — heads-down
            case "plan":   return "work_think"      // planning only — pondering, no edits
            default:       return effortWorkAnim()  // Ask mode → EFFORT decides the intensity
            }
        }
        // 4. Just finished — celebrate, energy scaled to effort.
        if phase == .done {
            switch normalizedEffort {
            case "ultra", "high": return "dance_djmix"
            case "medium":        return "dance_bounce"
            default:              return "dance_sway"
            }
        }
        // 5. Failed — surprised.
        if phase == .failed { return "expression_surprise" }
        // 6. Idle — mode-flavoured rest (or alarmed when the plan is maxed out).
        if (statuslineContextPct ?? 0) >= 0.95 { return "expression_surprise" }
        switch normalizedMode {
        case "bypass": return "dance_sway"          // even at rest it's loose
        case "plan":   return "idle_look_around"    // surveying
        case "auto":   return "idle_breathe"
        default:       return "idle_blink"
        }
    }

    /// Ask mode is the "manual" mode, so let EFFORT pick the working animation — this is
    /// where low / medium / high / ultracode each read as a distinct creature.
    private func effortWorkAnim() -> String {
        switch normalizedEffort {
        case "ultra":  return "dance_bounce"   // ultracode — hyped, all-out
        case "high":   return "work_coding"    // intense focus
        case "medium": return "work_think"     // steady thought
        case "low":    return "idle_breathe"   // light touch
        default:       return "work_coding"    // effort unknown → plain coding
        }
    }

    /// Colour that pairs with the mascot animation — risk first, then mode. Hot for
    /// bypass / danger, amber for editing, cool for plan / ask, so the creature reads
    /// at a glance even before you parse its motion.
    func modeTint(_ t: Theme) -> Color {
        if panicArmed { return t.red }
        if let p = pending {
            if p.alwaysDangerous || p.risk == .danger { return t.red }
            if p.risk == .write { return t.amber }
        }
        switch normalizedMode {
        case "bypass": return t.red
        case "edit":   return t.amber
        case "auto":   return t.accent
        default:       return t.accent2   // plan / ask
        }
    }

    private func describe(_ e: HookEvent) -> String {
        guard let tool = e.toolName else { return "working…" }
        let verb: String
        switch tool {
        case "Edit", "MultiEdit", "Write", "NotebookEdit": verb = "Editing"
        case "Read":   verb = "Reading"
        case "Bash":   verb = "Running"
        case "Grep", "Glob", "Search": verb = "Searching"
        case "WebFetch", "WebSearch":  verb = "Fetching"
        default: verb = tool
        }
        if let file = e.filePath { return "\(verb) \((file as NSString).lastPathComponent)" }
        if let cmd = e.command { return String("\(verb) \(cmd)".prefix(42)) }
        return "\(verb)…"
    }

    // MARK: - Held permission decision (Phase 2)

    /// Blocks the `/permission` hook until the user taps Allow / Deny / Always,
    /// or until the timeout falls back to the native flow. Low-risk reads are
    /// auto-allowed so the panel only interrupts for writes and dangerous actions.
    func requestDecision(for event: HookEvent) async -> PermissionVerdict {
        // A held permission hook may be the freshest signal of the session's mode — keep
        // the mascot / ModeCard current even when no separate PreToolUse /event preceded it.
        if let pm = event.permissionMode, !pm.isEmpty { permissionMode = pm }
        let assessment = RiskEngine.assess(toolName: event.toolName, event: event, cwd: event.cwd)
        // Panic Stop window → refuse EVERYTHING, reads included: the user hit Panic because
        // damage is in progress. The native flow re-asks once the 10s window clears, so benign
        // reads are only briefly frozen. (Consulted BEFORE the read short-circuit on purpose.)
        if panicArmed { return .deny }
        // Don't interrupt for plainly read-only actions (outside a panic).
        if assessment.level == .read { return .allow }
        // Autonomous mode → auto-allow hands-off, EXCEPT the irreversible 1% (rm -rf,
        // force-push to a protected branch, curl|sh, publish, disk writes…) which still
        // surfaces for one tap even when auto-approving. (Guardian Auto-Approve.)
        if autoApprove && !assessment.alwaysDangerous { return .allow }

        blockingCounter += 1
        let bid = "b\(blockingCounter)"
        let request = PendingPermission(
            id: bid,
            toolName: event.toolName ?? "tool",
            summary: event.toolInputSummary ?? "",
            reason: assessment.reason,
            risk: assessment.level,
            allowRule: AllowlistWriter.rule(for: event),
            preview: Self.buildPreview(event),
            project: event.projectLabel,
            alwaysDangerous: assessment.alwaysDangerous
        )
        return await withCheckedContinuation { continuation in
            resolvers[bid] = continuation
            pendingRules[bid] = request.allowRule
            pendingById[bid] = request
            // Don't clobber a card the user is mid-decision on: a newly-arrived request is
            // enqueued in pendingById and resolve() surfaces the next-oldest one when the
            // displayed request resolves. Only take the slot if it's empty, so a click in
            // flight always lands on the request the user is actually looking at.
            if pending == nil { pending = request }
            onApprovalChange?(true)           // lock open + auto-reveal
            pushPermissionAlert(request)      // Tier 2: ping the phone (no-op unless APNs configured)
            idleTimer?.invalidate(); idleTimer = nil
            Task { [weak self, decisionTimeout, bid] in
                try? await Task.sleep(nanoseconds: UInt64(decisionTimeout * 1_000_000_000))
                self?.resolve(bid, .ask)        // timeout → fall through to native
            }
        }
    }

    func resolveCurrent(_ verdict: PermissionVerdict) {
        guard let bid = pending?.id else { return }
        resolve(bid, verdict)
    }

    /// Resolve a held permission from the phone. decision ∈ allow | deny | always.
    /// "always" also writes the allow-rule into Claude Code's allowlist.
    func resolveRemote(id: String, decision: String) {
        switch decision.lowercased() {
        case "always":
            // Look the rule up by id — not the current `pending` slot, which may have
            // rotated to a newer request, silently dropping the allowlist write (#15).
            if let rule = pendingRules[id] ?? (pending?.id == id ? pending?.allowRule : nil) {
                AllowlistWriter.add(rule: rule)
            }
            resolve(id, .allow)
        case "allow":
            resolve(id, .allow)
        case "deny":
            resolve(id, .deny)
        default:
            // Fail SAFE: never auto-approve a garbled/unknown decision — fall through to
            // Claude Code's native prompt (matches the timeout path), don't allow.
            resolve(id, .ask)
        }
    }

    /// Allow + write a rule into Claude Code's allowlist so it never re-asks.
    func allowAlwaysCurrent() {
        guard let p = pending else { return }
        AllowlistWriter.add(rule: p.allowRule)
        resolve(p.id, .allow)
    }

    private func resolve(_ bid: String, _ verdict: PermissionVerdict) {
        guard let continuation = resolvers.removeValue(forKey: bid) else { return }   // also guards double-resolve
        pendingRules[bid] = nil; pendingById[bid] = nil
        continuation.resume(returning: verdict)
        if pending?.id == bid {
            // Surface the next still-outstanding request instead of orphaning it, and only
            // release the lock-open when none remain (was: cleared the gate unconditionally).
            // Pick the OLDEST (lowest "b<n>" counter) so requests resolve in arrival order
            // rather than in arbitrary dictionary order.
            let nextId = pendingById.keys.min { (Int($0.dropFirst()) ?? 0) < (Int($1.dropFirst()) ?? 0) }
            pending = nextId.flatMap { pendingById[$0] }
            // Keep the panel pinned open while EITHER gate is still outstanding (a held
            // question must not be hidden just because the last permission resolved).
            onApprovalChange?(pending != nil || pendingQuestion != nil)
        }
    }

    // MARK: - Held AskUserQuestion (answer from the phone)

    /// Holds the AskUserQuestion PreToolUse hook open and surfaces the questions to
    /// the phone. Returns the answer map {questionText: selectedLabel(s)} the caller
    /// echoes back in `updatedInput`. Times out (empty) so the desktop UI can take
    /// over if nobody answers.
    func requestQuestionDecision(questionsData: Data, project: String?) async -> [String: String] {
        let raw = (try? JSONSerialization.jsonObject(with: questionsData)) as? [[String: Any]] ?? []
        let items: [PendingQuestion.Item] = raw.map { q in
            let opts = (q["options"] as? [[String: Any]] ?? []).map {
                PendingQuestion.Option(label: $0["label"] as? String ?? "", description: $0["description"] as? String)
            }
            return PendingQuestion.Item(question: q["question"] as? String ?? "",
                                        header: q["header"] as? String ?? "",
                                        multiSelect: (q["multiSelect"] as? Bool) ?? false, options: opts)
        }
        guard !items.isEmpty else { return [:] }
        if panicArmed { return [:] }   // Panic window → don't hold the turn open on a question
        questionCounter += 1
        let qid = "q\(questionCounter)"
        let request = PendingQuestion(id: qid, items: items, project: project)
        return await withCheckedContinuation { continuation in
            questionResolvers[qid] = continuation
            pendingQuestion = request
            onApprovalChange?(true)
            pushQuestionAlert(request)
            idleTimer?.invalidate(); idleTimer = nil
            // Clean up just UNDER the hook's own timeout (120s) so the gate releases and
            // the desktop UI takes over at the timeout, instead of lingering ~30s
            // locked-open after the hook already gave up. We resolve empty (no answer).
            Task { [weak self, qid] in
                try? await Task.sleep(nanoseconds: 115 * 1_000_000_000)
                self?.resolveQuestion(qid, [:])
            }
        }
    }

    /// Resolve a held question from the phone. answers = {questionText: "label" or
    /// "labelA,labelB" for multi-select}.
    func resolveQuestionRemote(id: String, answers: [String: String]) { resolveQuestion(id, answers) }

    private func resolveQuestion(_ qid: String, _ answers: [String: String]) {
        guard let continuation = questionResolvers.removeValue(forKey: qid) else { return }
        continuation.resume(returning: answers)
        if pendingQuestion?.id == qid { pendingQuestion = nil }
        // Don't drop the panel while a permission is still held on the gate.
        onApprovalChange?(pending != nil || pendingQuestion != nil)
    }

    private func pushQuestionAlert(_ q: PendingQuestion) {
        let first = q.items.first
        // Redact like the permission path — don't ship a secret in the question text through APNs/ntfy.
        let body = Self.redactSecrets(first.map { $0.header.isEmpty ? $0.question : $0.header } ?? "Tap to choose an answer")
        if APNsPusher.shared.enabled, let dt = devicePushToken {
            APNsPusher.shared.pushAlert(deviceToken: dt, title: "Claude is asking you", body: body, questionId: q.id)
        }
        NtfyPusher.shared.pushQuestion(title: "Claude is asking you", body: body)
    }

    /// Mask common secret patterns so a token/key in a command or diff doesn't get
    /// shown in the approval card or shipped through APNs/ntfy in the push body.
    static func redactSecrets(_ s: String) -> String {
        var out = s
        let rules: [(String, String)] = [
            (#"(?i)\b(authorization|bearer|api[_-]?key|secret|token|password|passwd|access[_-]?key)\b(\s*[:=]\s*)\S+"#, "$1$2«redacted»"),
            (#"sk-[A-Za-z0-9_\-]{16,}"#, "«redacted»"),
            (#"(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}"#, "«redacted»"),
            (#"github_pat_[A-Za-z0-9_]{20,}"#, "«redacted»"),
            (#"AKIA[0-9A-Z]{16}"#, "«redacted»"),
            (#"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{6,}"#, "«redacted»"),
        ]
        for (pat, rep) in rules { out = out.replacingOccurrences(of: pat, with: rep, options: .regularExpression) }
        return out
    }

    static func buildPreview(_ event: HookEvent) -> [PreviewLine] {
        let maxLines = 6
        if let old = event.oldString.map(redactSecrets), let new = event.newString.map(redactSecrets) {
            var lines: [PreviewLine] = []
            for l in old.split(separator: "\n", omittingEmptySubsequences: false).prefix(maxLines / 2) {
                lines.append(PreviewLine(kind: .removed, text: String(l)))
            }
            for l in new.split(separator: "\n", omittingEmptySubsequences: false).prefix(maxLines / 2) {
                lines.append(PreviewLine(kind: .added, text: String(l)))
            }
            return lines
        }
        if let content = event.content.map(redactSecrets) {
            return content.split(separator: "\n", omittingEmptySubsequences: false).prefix(maxLines)
                .map { PreviewLine(kind: .added, text: String($0)) }
        }
        if let cmd = event.command.map(redactSecrets) {
            return cmd.split(separator: "\n", omittingEmptySubsequences: false).prefix(maxLines)
                .map { PreviewLine(kind: .context, text: String($0)) }
        }
        if let path = event.filePath { return [PreviewLine(kind: .context, text: path)] }
        return []
    }

    /// Open a file the agent touched, in the user's default app / editor.
    func openFile(_ path: String) {
        guard path.hasPrefix("/") else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [path]
        try? p.run()
    }

    // MARK: - APNs (Tier 2) push tokens + Mac-driven pushes

    private var activityPushTokens: [String: String] = [:]   // sessionId → Live Activity token
    private var devicePushToken: String?
    private var lastFinishedDetail: String?   // "1m 36s · 18.4K tokens" — used as the Island's done detail
    private var endsThisScan = 0              // non-editor sessions that ended in the current detectEnded scan
    private var pendingEndTask: Task<Void, Never>?   // deferred Live Activity "end" (cancellable if work resumes)

    private var pushToStartToken: String?     // iOS 17.2+ push-to-start (pop the Island up while closed)
    private var startPushPending = false

    /// Load persisted push tokens so a Mac restart doesn't drop them (which left the
    /// Island unable to receive its "end" and stuck on a frozen timer).
    func loadPushTokens() {
        let d = UserDefaults.standard
        if let m = d.dictionary(forKey: "edgepanel.activityTokens") as? [String: String] { activityPushTokens = m }
        pushToStartToken = d.string(forKey: "edgepanel.startToken")
        devicePushToken = d.string(forKey: "edgepanel.deviceToken")
        // When APNs reports a Live Activity / push-to-start token as permanently dead
        // (410 — the Island ended or the app was reinstalled), drop it so we stop hammering
        // it every ~10s and a fresh token (sent when the app next runs) drives the next Island.
        APNsPusher.shared.onInvalidToken = { [weak self] token, _ in
            Task { @MainActor in
                guard let self else { return }
                for (k, v) in self.activityPushTokens where v == token { self.activityPushTokens[k] = nil }
                if self.pushToStartToken == token { self.pushToStartToken = nil }
                if self.devicePushToken == token { self.devicePushToken = nil }   // dead device token → stop targeting it
                self.lastPushedWorkingIds = []     // re-push/start cleanly when a token next arrives
                self.savePushTokens()
            }
        }
    }
    private func savePushTokens() {
        let d = UserDefaults.standard
        d.set(activityPushTokens, forKey: "edgepanel.activityTokens")
        d.set(pushToStartToken, forKey: "edgepanel.startToken")
        d.set(devicePushToken, forKey: "edgepanel.deviceToken")
    }

    func setPushToken(kind: String, sessionId: String?, token: String) {
        switch kind {
        case "activity":  if let sid = sessionId { activityPushTokens[sid] = token }
        case "device":    devicePushToken = token
        case "starttoken": pushToStartToken = token
        default:          break
        }
        savePushTokens()
        NSLog("EdgePanel push token received: kind=\(kind) sid=\(sessionId ?? "-") token=\(token.prefix(12))…")
    }

    private var lastPushedWorkingIds: Set<String> = []
    private var lastAggregatePush = Date.distantPast

    /// Push the aggregate Live Activity state to the phone via APNs so the Dynamic
    /// Island ends/updates seamlessly even when the app is suspended or fully closed.
    /// Push on membership change, AND every ~12s while running so the token counts
    /// refresh on the Lock Screen (tokens don't self-tick like the timer does).
    func pushAggregate(working rawWorking: [LiveSession]) {
        endsThisScan = 0   // this scan's ends are already baked into lastFinishedDetail; clear for the next scan
        guard APNsPusher.shared.enabled else { return }
        // Drive the Island from ALL working sessions, including the editor session you're
        // watching at the Mac — the user wants to see their work on the phone. It still ends
        // correctly: a session leaves `working` the instant its turn completes (turnComplete),
        // so the Island flips to done + tears down via the empty-tick debounce below.
        let working = rawWorking
        let ids = Set(working.map { $0.id })
        let membershipChanged = ids != lastPushedWorkingIds

        // A brand-new prompt after being idle → re-arm push-to-start so the Island pops
        // up again. (Otherwise startPushPending could stay set from the previous turn and
        // the next prompt never re-popped the Island while the app was closed.)
        if lastPushedWorkingIds.isEmpty && !working.isEmpty { startPushPending = false }

        // Work ended with no live activity to push to → reset so a fresh start fires next time.
        if working.isEmpty && activityPushTokens["edgepanel"] == nil {
            lastPushedWorkingIds = []; startPushPending = false; return
        }

        // No per-activity token (app not running) but work just began → PUSH-TO-START
        // so the Island pops up on its own. Once per work session (until the app sends
        // a real activity token or work ends).
        if !working.isEmpty, activityPushTokens["edgepanel"] == nil, let st = pushToStartToken, !startPushPending {
            startPushPending = true
            lastPushedWorkingIds = ids; lastAggregatePush = Date()
            APNsPusher.shared.pushStart(token: st, contentState: aggregateState(working), attributes: ["id": "edgepanel"])
            return
        }

        guard let token = activityPushTokens["edgepanel"] else { lastPushedWorkingIds = ids; return }
        startPushPending = false                       // the app has a live activity now
        // A new turn started → cancel any pending "end" so we don't tear down the Island
        // that's now live again (the deferred end below could otherwise fire mid-turn).
        if !working.isEmpty { pendingEndTask?.cancel(); pendingEndTask = nil }
        guard membershipChanged || (!working.isEmpty && Date().timeIntervalSince(lastAggregatePush) > 12) else { return }
        lastPushedWorkingIds = ids
        lastAggregatePush = Date()
        if working.isEmpty {
            // Two-step "complete" so the Island/Lock Screen visibly flips to DONE before
            // it dismisses. The Island is torn down on `end` regardless of dismissal-date,
            // so the done state MUST be shown via a prior `update` (verified vs ActivityKit
            // docs). update(done) → hold → end(done)+dismissal, then release the token.
            let detail = lastFinishedDetail ?? "finished"
            let doneState: [String: Any] = ["sessions": [[String: Any]](), "done": true, "doneDetail": detail]
            APNsPusher.shared.pushActivity(token: token, event: "update", contentState: doneState)
            pendingEndTask?.cancel()
            pendingEndTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)   // hold "✓ Complete" visibly on the Island
                guard let self, !Task.isCancelled,
                      self.lastPushedWorkingIds.isEmpty,            // work is STILL idle…
                      self.activityPushTokens["edgepanel"] == token // …and the same activity
                else { return }
                APNsPusher.shared.pushActivity(token: token, event: "end", contentState: doneState)
                self.activityPushTokens["edgepanel"] = nil   // ended → allow a fresh push-to-start next time
                self.savePushTokens()
            }
            return
        }
        APNsPusher.shared.pushActivity(token: token, event: "update", contentState: aggregateState(working))
    }

    /// The aggregate Live Activity content-state (mirrors iOS WorkingAttributes.ContentState).
    private func aggregateState(_ working: [LiveSession]) -> [String: Any] {
        let freezeAt = Date().addingTimeInterval(90).timeIntervalSince1970
        let sessions: [[String: Any]] = working.map { sn in
            ["id": sn.id, "project": sn.project,
             "prompt": sn.promptText.map { String($0.prefix(80)) } ?? "working…",
             "startEpoch": sn.promptAt?.timeIntervalSince1970 ?? Date().timeIntervalSince1970,
             "tokens": sn.turnTokens, "agents": sn.runningAgents, "queued": sn.queuedPrompts,
             "freezeAt": freezeAt]
        }
        return ["sessions": sessions, "done": false]
    }

    /// Alert the phone that a permission is waiting — so you can Allow/Deny even with
    /// the app fully closed. Two independent paths: APNs (Tier 2, paid) and ntfy
    /// (free, with Allow/Deny action buttons). No-op if neither is configured.
    private func pushPermissionAlert(_ p: PendingPermission) {
        let body = Self.redactSecrets(p.summary.isEmpty ? p.reason : p.summary)   // don't ship a secret through APNs/ntfy
        if APNsPusher.shared.enabled, let dt = devicePushToken {
            APNsPusher.shared.pushPermission(deviceToken: dt, id: p.id,
                title: "\(p.toolName) needs approval", body: body)
        }
        NtfyPusher.shared.pushPermission(id: p.id, tool: p.toolName, summary: body, risk: p.risk.rawValue)
    }

    /// Push an "end" Live Activity update + alert when a session finishes — so the
    /// phone updates even if the app is closed. No-op unless APNs is configured.
    func pushSessionEnded(_ s: LiveSession) {
        // Editor sessions (claude-vscode/desktop) now ALSO send a "finished" push so you get
        // notified on the phone when a turn you started at the Mac completes. The phone
        // suppresses the banner while its app is foreground (willPresent), so you're only
        // pinged when you're actually away from / not looking at the phone.
        let elapsed = s.promptAt.map { max(Date().timeIntervalSince($0), 0) } ?? 0
        let m = Int(elapsed) / 60, sec = Int(elapsed) % 60
        let elapsedStr = m > 0 ? "\(m)m \(sec)s" : "\(sec)s"
        let baseDetail = "\(elapsedStr) · \(fmtTokens(s.turnTokens)) tokens"
        // When several non-editor chats finish in one scan, show an aggregate count instead of
        // just the last one's detail. endsThisScan is reset by pushAggregate (the scan-closing call).
        endsThisScan += 1
        lastFinishedDetail = endsThisScan > 1 ? "\(endsThisScan) chats finished" : baseDetail
        let project = s.project, cwd = s.cwd, dt = devicePushToken
        // Outcome Card: enrich the "done" alert with WHAT changed (git working-tree diff),
        // computed off-main so the git call never blocks the UI.
        DispatchQueue.global(qos: .utility).async {
            let outcome = Self.gitOutcome(cwd: cwd)               // " · 2 files +40−5: ChatRunner.swift, …"
            let body = baseDetail + outcome
            DispatchQueue.main.async {
                if APNsPusher.shared.enabled, let dt {
                    APNsPusher.shared.pushAlert(deviceToken: dt, title: "✓ \(project) finished", body: body)
                }
                if elapsed >= 15 { NtfyPusher.shared.pushDone(title: "✓ \(project) finished", detail: body) }
            }
        }
    }

    nonisolated private static let gitPath: String? = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// What Claude changed in `cwd`'s working tree — files + ±lines — for the done card.
    /// Empty string if not a git repo / nothing changed / git unavailable.
    nonisolated static func gitOutcome(cwd: String) -> String {
        guard !cwd.isEmpty, gitPath != nil else { return "" }
        let dir = (cwd as NSString).expandingTildeInPath
        guard runGit(dir, ["rev-parse", "--is-inside-work-tree"]) == "true" else { return "" }
        // `diff HEAD` covers tracked changes (staged + unstaged). Brand-new files are
        // UNTRACKED — invisible to diff — so a scaffolding turn would read as "nothing
        // changed"; fold those in via `ls-files --others` so new work shows up too.
        let tracked = (runGit(dir, ["diff", "--name-only", "HEAD"]) ?? "")
            .split(separator: "\n").map(String.init)
        let untracked = (runGit(dir, ["ls-files", "--others", "--exclude-standard"]) ?? "")
            .split(separator: "\n").map(String.init)
        var seen = Set<String>()
        let names = (tracked + untracked).filter { seen.insert($0).inserted }
        guard !names.isEmpty else { return "" }
        let shortstat = runGit(dir, ["diff", "--shortstat", "HEAD"]) ?? ""
        func num(_ kw: String) -> Int {
            guard let r = shortstat.range(of: #"(\d+) "# + kw, options: .regularExpression) else { return 0 }
            return Int(shortstat[r].prefix(while: { $0.isNumber })) ?? 0
        }
        let plus = num("insertion"), minus = num("deletion")
        let lines = (plus > 0 || minus > 0) ? " +\(plus)−\(minus)" : ""
        let shown = names.prefix(2).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        let more = names.count > 2 ? " +\(names.count - 2)" : ""
        return " · \(names.count) file\(names.count == 1 ? "" : "s")\(lines): \(shown)\(more)"
    }

    nonisolated private static func runGit(_ dir: String, _ args: [String]) -> String? {
        guard let git = gitPath else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = ["-C", dir] + args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return nil }
        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Take me there": open the chat's project in VS Code (or Cursor) — where
    /// the Claude Code extension lives — rather than a separate Terminal.
    func openChat(cwd: String?, id: String) {
        guard let cwd, !cwd.isEmpty else { return }
        let editors = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
                       "com.vscodium.codium", "com.todesktop.230313mzl4w4u92" /* Cursor */]
        let ws = NSWorkspace.shared
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if let bid = editors.first(where: { ws.urlForApplication(withBundleIdentifier: $0) != nil }) {
            p.arguments = ["-b", bid, cwd]
        } else {
            p.arguments = [cwd]   // fall back to Finder
        }
        try? p.run()
    }

    private func setPhase(_ p: Phase) {
        idleTimer?.invalidate(); idleTimer = nil
        phase = p
    }

    /// After a done/failed, settle back to idle so the panel doesn't sit on a
    /// stale "done" forever.
    private func scheduleIdle() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.phase = .idle }
        }
    }
}
