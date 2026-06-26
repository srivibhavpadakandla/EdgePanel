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

    private var resolvers: [String: CheckedContinuation<PermissionVerdict, Never>] = [:]
    private var blockingCounter = 0
    private let decisionTimeout: TimeInterval =
        TimeInterval(ProcessInfo.processInfo.environment["EDGEPANEL_DECISION_TIMEOUT"] ?? "") ?? 20

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

    func handle(_ event: HookEvent) {
        if let label = event.projectLabel { projectLabel = label }
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
        let assessment = RiskEngine.assess(toolName: event.toolName, event: event, cwd: event.cwd)
        // Don't interrupt for plainly read-only actions.
        if assessment.level == .read { return .allow }

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
            project: event.projectLabel
        )
        return await withCheckedContinuation { continuation in
            resolvers[bid] = continuation
            pending = request
            onApprovalChange?(true)           // lock open + auto-reveal
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

    /// Allow + write a rule into Claude Code's allowlist so it never re-asks.
    func allowAlwaysCurrent() {
        guard let p = pending else { return }
        AllowlistWriter.add(rule: p.allowRule)
        resolve(p.id, .allow)
    }

    private func resolve(_ bid: String, _ verdict: PermissionVerdict) {
        guard let continuation = resolvers.removeValue(forKey: bid) else { return }
        continuation.resume(returning: verdict)
        if pending?.id == bid { pending = nil }
        onApprovalChange?(false)              // release the lock-open
    }

    static func buildPreview(_ event: HookEvent) -> [PreviewLine] {
        let maxLines = 6
        if let old = event.oldString, let new = event.newString {
            var lines: [PreviewLine] = []
            for l in old.split(separator: "\n", omittingEmptySubsequences: false).prefix(maxLines / 2) {
                lines.append(PreviewLine(kind: .removed, text: String(l)))
            }
            for l in new.split(separator: "\n", omittingEmptySubsequences: false).prefix(maxLines / 2) {
                lines.append(PreviewLine(kind: .added, text: String(l)))
            }
            return lines
        }
        if let content = event.content {
            return content.split(separator: "\n", omittingEmptySubsequences: false).prefix(maxLines)
                .map { PreviewLine(kind: .added, text: String($0)) }
        }
        if let cmd = event.command {
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
