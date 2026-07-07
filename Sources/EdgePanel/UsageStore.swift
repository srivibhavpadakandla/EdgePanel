// UsageStore — live data for the Usage view. Ported & trimmed from ClaudeUsage:
//   • local token/cost aggregation from ~/.claude/projects (every 120s)
//   • live plan % from Claude Code's OAuth usage endpoint (every 90s)
//   • 5-hour utilization history + burn-rate projection
//   • the three Phase-1 "cheap wins": context-window %, wall-clock limit time,
//     per-model spend split.

import SwiftUI
import Foundation

// Not @MainActor: the OAuth fetch reads a couple of bookkeeping ints off a
// background queue (as ClaudeUsage does). All @Published writes hop to main.
final class UsageStore: ObservableObject {
    @Published var summary = Summary()
    @Published var plan: PlanUsage?
    @Published var burn: BurnInfo?
    @Published var samples: [(t: Date, util: Double)] = []
    @Published var loading = true
    @Published var planFetchFailing = false
    @Published var lastPlanSuccess: Date?
    @Published var tokenMissing = false      // no Claude Code OAuth token in keychain

    // Live "which chats are working" list.
    @Published var sessions: [LiveSession] = []
    /// The DEBOUNCED working set (a session is carried for 1 missing scan before being
    /// declared finished) — the snapshot publishes THIS, not the raw per-scan filter, so
    /// the phone never sees a single-scan isWorking() blip flicker the Dynamic Island.
    @Published var workingDebounced: [LiveSession] = []
    // Fires when a working session finishes (was generating, now done) — used to
    // push a "done" Live Activity update + notification to the phone (Tier 2).
    var onSessionEnded: ((LiveSession) -> Void)?
    // The interactive editor/CLI session you're watching ON this Mac — its "finished"
    // phone alert is suppressed (you don't need a ping for the chat on your screen).
    // Cached so detectEnded() doesn't re-scan the filesystem every 2s.
    private var cachedInteractiveId: String?
    private var interactiveIdAt = Date.distantPast
    private func currentInteractiveId() -> String? {
        if Date().timeIntervalSince(interactiveIdAt) > 30 {
            cachedInteractiveId = UsageLoader.mostRecentInteractiveSessionId()
            interactiveIdAt = Date()
        }
        return cachedInteractiveId
    }
    /// Fires whenever the set of working sessions changes — drives the APNs push that
    /// ends/updates the phone's Live Activity seamlessly.
    var onWorkingChanged: (([LiveSession]) -> Void)?
    private var prevWorking: [String: LiveSession] = [:]
    private var endMisses: [String: Int] = [:]   // id → consecutive scans seen not-working (debounce)
    private var sessionScanGen = 0               // assigned per dispatched session scan (ordering)
    private var appliedSessionGen = 0            // highest scan gen whose result we've applied
    private func nextSessionGen() -> Int { sessionScanGen += 1; return sessionScanGen }

    // Recent Claude Code chats (sessions), newest first.
    @Published var recentChats: [RecentChat] = []
    // Recent human-typed prompts across chats, newest first — the phone's Prompt History.
    @Published var promptHistory: [PromptHistoryEntry] = []
    // sessionID → short summary of its (long) prompt, from the claude CLI.
    @Published var promptSummaries: [String: String] = [:]
    // sessionID → the exact prompt text its cached summary was made for, so a NEW
    // prompt in the same session drops the stale label instead of showing it.
    private var summarizedPrompt: [String: String] = [:]

    private let q = DispatchQueue(label: "edgepanel.load", qos: .userInitiated)
    private let planQ = DispatchQueue(label: "edgepanel.plan", qos: .userInitiated)
    private let ioQ = DispatchQueue(label: "edgepanel.io", qos: .utility)
    private var timer: Timer?
    private var planTimer: Timer?
    private var resetTimer: Timer?
    private var sessionTimer: Timer?
    private let sessionQ = DispatchQueue(label: "edgepanel.sessions", qos: .utility)
    private var lastPlanFetch = Date.distantPast
    private var planFetchInFlight = false
    private var planFetchStartedAt = Date.distantPast
    private var planFetchGen = 0
    private var planRetryDelay = 8.0
    private var history: [(t: Date, util: Double)] = []

    var fiveHourExpired: Bool {
        guard let r = plan?.fiveHourReset else { return false }
        return r <= Date()
    }
    var displayFiveHourPct: Double? {
        guard let p = plan else { return nil }
        if let r = p.fiveHourReset, r <= Date() { return 0 }
        return p.fiveHourPct
    }

    /// Wall-clock time the 5-hour window hits 100% at the current pace, or nil if
    /// it won't before reset. Cheap win #2.
    var limitClock: Date? {
        guard let b = burn, let tt = b.timeToLimit, b.willHitBeforeReset else { return nil }
        return Date().addingTimeInterval(tt)
    }

    func start() {
        loadHistory()
        loadStoredPlan()
        load()
        loadPlan()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in self?.load() }
        planTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in self?.loadPlan() }
        // Keep the working sessions + tokens fresh (cheap: tail-reads recent files).
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshSessions() }
    }

    /// Fires when the live permission mode (read from the active transcript) changes,
    /// so the state/mascot/ModeCard reflect the mode you actually set in Claude Code.
    var onModeChanged: ((String) -> Void)?
    private var lastMode: String?
    /// Fires when the reasoning-effort level (read from settings.json) changes, so the mascot
    /// flashes that effort's signature animation and the meter reflects the real level.
    var onEffortChanged: ((String?) -> Void)?
    private var lastEffort: String = "\u{0}"   // sentinel so the first read always applies

    // The live editor session — the one you're working in at the Mac (most-recent
    // interactive transcript). The phone's "Editor" chat targets this and types into it.
    @Published var editorSessionId: String?
    @Published var editorCwd: String = ""
    @Published var editorProject: String = ""

    func refreshSessions() {
        let gen = nextSessionGen()
        sessionQ.async {
            let sessions = UsageLoader.activeSessions()
            let mode = UsageLoader.currentPermissionMode()
            let eff = UsageLoader.currentEffort()
            DispatchQueue.main.async {
                if let mode, mode != self.lastMode { self.lastMode = mode; self.onModeChanged?(mode) }
                if (eff ?? "") != self.lastEffort { self.lastEffort = eff ?? ""; self.onEffortChanged?(eff) }
                // Track the live editor session (cheap: id cached 30s; cwd resolved only on change).
                let eid = self.currentInteractiveId()
                if eid != self.editorSessionId {
                    self.editorSessionId = eid
                    if let eid, let url = UsageLoader.sessionFileURL(sessionId: eid) {
                        let c = UsageLoader.headCwd(url) ?? ""
                        self.editorCwd = c
                        self.editorProject = c.isEmpty ? "Editor" : (c as NSString).lastPathComponent
                    } else { self.editorCwd = ""; self.editorProject = "" }
                }
                guard gen > self.appliedSessionGen else { return }   // a fresher scan already applied — drop this stale one
                self.appliedSessionGen = gen
                self.sessions = sessions
                self.updateSummaries(sessions)
                self.detectEnded()
            }
        }
    }

    /// Fire onSessionEnded for sessions that were generating and now aren't — but only
    /// after they've been absent for 2 consecutive scans (~4s), so a transient blip
    /// (the gap between two turns, or a mid-write transcript) doesn't spam a false
    /// "finished" notification.
    private func detectEnded() {
        // Merging init (not uniqueKeysWithValues:) so a duplicate session id — same transcript
        // uuid surfacing under two project dirs — can't trap. Mirrors byId below.
        let workingNow = Dictionary(sessions.filter { $0.isWorking() }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Index ALL current sessions (incl. just-finished) so the done notification's
        // token count reflects the turn's final message, not a stale 0.
        let byId = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let interactiveId = currentInteractiveId()
        var carried = workingNow
        for (id, prev) in prevWorking where workingNow[id] == nil {
            let misses = (endMisses[id] ?? 0) + 1
            if misses >= 2 {                       // gone for 2 scans → really finished
                // Fire the "finished" phone push ONLY for a session you're NOT sitting in front of —
                // i.e. a remote/phone-initiated turn. The session open in your editor (interactiveId)
                // is one you're already watching on screen (+ the Dynamic Island), so pinging your
                // phone for every one of its turns was a per-reply spam that iOS throttles into
                // silence — which is why "done" notifications stopped arriving at all.
                let ended = byId[id] ?? prev
                if id != interactiveId { onSessionEnded?(ended) }
                endMisses[id] = nil
            } else {                               // first miss → keep tracking, don't fire yet
                endMisses[id] = misses
                // Carry the FRESHEST parsed snapshot (tokens/agents/queued) if the session is
                // still present-but-not-working, falling back to the previous scan only when it
                // genuinely vanished — so the debounce window doesn't freeze stale values.
                carried[id] = byId[id] ?? prev
            }
        }
        for id in workingNow.keys { endMisses[id] = nil }   // working again → reset its counter
        prevWorking = carried
        workingDebounced = Array(carried.values)            // the smoothed set the snapshot publishes
        onWorkingChanged?(Array(carried.values))
    }

    /// Summarize long, title-less chat names (the claude CLI), keyed by chat id.
    private func updateChatSummaries(_ chats: [RecentChat]) {
        for c in chats where c.needsSummary {
            guard let p = c.firstPrompt else { continue }
            if let cached = PromptSummarizer.shared.shortLabel(for: p, onReady: { [weak self] summary in
                self?.promptSummaries[c.id] = summary
            }) {
                promptSummaries[c.id] = cached
            }
        }
    }

    /// Summarize long prompts (via the claude CLI) for the WORKING NOW rows.
    /// Keeps `promptSummaries[id]` in lock-step with the session's CURRENT prompt:
    /// a short or changed prompt drops the stale summary (the row falls back to the
    /// raw text) instead of showing a label from a prompt you sent a while back.
    private func updateSummaries(_ sessions: [LiveSession]) {
        let liveIDs = Set(sessions.map { $0.id })
        promptSummaries = promptSummaries.filter { liveIDs.contains($0.key) }
        summarizedPrompt = summarizedPrompt.filter { liveIDs.contains($0.key) }
        for s in sessions {
            // No prompt, or short enough to show verbatim → clear any stale summary.
            guard let pt = s.promptText, pt.count > PromptSummarizer.threshold else {
                promptSummaries[s.id] = nil; summarizedPrompt[s.id] = nil; continue
            }
            // Prompt changed since we last summarized this session → drop the stale
            // label now; the new one swaps in via onReady when it's ready.
            if summarizedPrompt[s.id] != pt { promptSummaries[s.id] = nil }
            summarizedPrompt[s.id] = pt
            if let cached = PromptSummarizer.shared.shortLabel(for: pt, onReady: { [weak self] summary in
                guard let self, self.summarizedPrompt[s.id] == pt else { return }  // a superseded prompt's late summary — ignore
                self.promptSummaries[s.id] = summary
            }) {
                promptSummaries[s.id] = cached
            }
        }
    }

    // MARK: - Local usage + context

    func load() {
        loadPlan()
        loading = true
        let gen = nextSessionGen()
        q.async {
            let s = UsageLoader.computeSummary()
            let sessions = UsageLoader.activeSessions()
            let chats = UsageLoader.recentChats()
            let history = UsageLoader.promptHistory()
            DispatchQueue.main.async {
                self.summary = s
                self.loading = false
                self.recentChats = chats
                self.promptHistory = history
                self.updateChatSummaries(chats)
                // Only apply the session/ended detection if this is the freshest scan —
                // otherwise a slow stale scan overwrites a newer one and fires a spurious
                // "finished" (audit #11).
                guard gen > self.appliedSessionGen else { return }
                self.appliedSessionGen = gen
                self.sessions = sessions
                self.updateSummaries(sessions)
                self.detectEnded()
            }
        }
    }

    func refresh() {
        planFetchGen += 1
        planFetchInFlight = false
        planFetchStartedAt = .distantPast
        lastPlanFetch = .distantPast
        planRetryDelay = 8.0
        load()
    }

    // MARK: - 5-hour history (persisted)

    private func historyURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("ClaudeUsage/history.json")
    }
    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyURL()),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Double]] else { return }
        let now = Date()
        history = arr.compactMap { d -> (t: Date, util: Double)? in
            guard let t = d["t"], let u = d["u"] else { return nil }
            return (Date(timeIntervalSince1970: t), u)
        }.filter { now.timeIntervalSince($0.t) <= 21600 }
        samples = history
    }
    private func saveHistory() {
        let url = historyURL()
        let arr = history.map { ["t": $0.t.timeIntervalSince1970, "u": $0.util] }
        guard let data = try? JSONSerialization.data(withJSONObject: arr) else { return }
        ioQ.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }

    // MARK: - Live plan (OAuth)

    func loadPlan() {
        let now = Date()
        let minGap = fiveHourExpired ? 8.0 : 10.0
        if now.timeIntervalSince(lastPlanFetch) < minGap { return }
        if planFetchInFlight && now.timeIntervalSince(planFetchStartedAt) < 25 { return }
        planFetchGen += 1
        let gen = planFetchGen
        planFetchInFlight = true
        planFetchStartedAt = now
        lastPlanFetch = now
        planQ.async {
            func current() -> Bool { gen == self.planFetchGen }
            if let token = readClaudeOAuthToken() {
                DispatchQueue.main.async { if current() { self.tokenMissing = false } }
                fetchPlanUsage(token) { r in
                    DispatchQueue.main.async { if current() { self.handlePlanResult(r) } }
                }
            } else {
                DispatchQueue.main.async {
                    guard current() else { return }
                    self.tokenMissing = true
                    if self.plan == nil { self.burn = nil }
                    self.planFetchInFlight = false
                }
            }
        }
    }

    private func handlePlanResult(_ r: PlanResult) {
        switch r {
        case .ok(let p): applyPlan(p)
        case .unauthorized:
            tokenMissing = true
            planFetchFailing = false
            planFetchInFlight = false
        case .rateLimited, .transient: applyPlanFailure()
        }
    }

    private func planFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("ClaudeUsage/plan.json")
    }
    private func loadStoredPlan() {
        guard let data = try? Data(contentsOf: planFileURL()),
              let p = try? JSONDecoder().decode(PlanUsage.self, from: data) else { return }
        if let reset = p.fiveHourReset, reset > Date() { plan = p }
    }
    private func savePlan(_ p: PlanUsage) {
        let url = planFileURL()
        guard let data = try? JSONEncoder().encode(p) else { return }
        ioQ.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }

    private func applyPlan(_ p: PlanUsage) {
        let prevReset = plan?.fiveHourReset
        plan = p
        savePlan(p)
        let now = Date()
        planFetchFailing = false
        lastPlanSuccess = now
        planRetryDelay = 8.0
        if let newReset = p.fiveHourReset, let prev = prevReset, newReset != prev { history.removeAll() }
        if let newReset = p.fiveHourReset {
            let windowStart = newReset.addingTimeInterval(-18000)
            history.removeAll { $0.t < windowStart }
        }
        history.append((now, p.fiveHourPct))
        history.removeAll { now.timeIntervalSince($0.t) > 21600 }
        samples = history
        saveHistory()
        burn = computeBurn(p, now)
        scheduleResetRefresh(p.fiveHourReset)
        planFetchInFlight = false
        checkUsageAlert(p)
    }

    /// Usage guardrail — fires the 80%/90% + "on track to hit the cap" alerts from the
    /// ALWAYS-ON Mac (so they reach the phone even when the app is closed), instead of the
    /// app's poll loop (which only runs while the app is open). Re-arms on a window reset.
    var onUsageAlert: ((String, String) -> Void)?
    // PERSISTED across launches so a Mac restart at ≥80% doesn't re-fire the push (the threshold
    // was already alerted this window); re-arms only when the window actually resets.
    private var usageAlerted: Set<Int> = Set(UserDefaults.standard.array(forKey: "edgepanel.usageAlerted") as? [Int] ?? [])
    private var usageLastPct = 0.0
    private var usageForecastAlerted = false
    private var lastUsageReset: Date? = UserDefaults.standard.object(forKey: "edgepanel.usageReset") as? Date
    private func checkUsageAlert(_ p: PlanUsage) {
        let pct = p.fiveHourPct
        guard pct.isFinite else { return }   // non-finite (corrupted plan.json) → would trap Int(inf)
        // Re-arm when the 5-hour window resets (new reset time) OR on a clear pct drop — so the
        // 80/90 alerts fire again next window even if usage was still low at the reset moment.
        if p.fiveHourReset != lastUsageReset || pct < usageLastPct - 5 {
            usageAlerted.removeAll(); usageForecastAlerted = false
            UserDefaults.standard.set([Int](), forKey: "edgepanel.usageAlerted")
        }
        lastUsageReset = p.fiveHourReset
        usageLastPct = pct
        UserDefaults.standard.set(p.fiveHourReset, forKey: "edgepanel.usageReset")
        for thr in [80, 90] where pct >= Double(thr) && !usageAlerted.contains(thr) {
            usageAlerted.insert(thr)
            UserDefaults.standard.set(Array(usageAlerted), forKey: "edgepanel.usageAlerted")
            onUsageAlert?("⚠︎ \(thr)% of your 5-hour limit",
                          "Now at \(Int(pct.rounded()))% — ease off or you'll hit the cap.")
        }
        if let hit = limitClock {
            let mins = hit.timeIntervalSinceNow / 60
            if mins > 0, mins <= 45, pct >= 50, !usageForecastAlerted {
                usageForecastAlerted = true
                let t = DateFormatter.localizedString(from: hit, dateStyle: .none, timeStyle: .short)
                onUsageAlert?("⏳ On track to hit your 5-hour cap",
                              "At this pace, around \(t). Ease off or pause autonomous tasks.")
            }
            if mins > 60 || mins <= 0 { usageForecastAlerted = false }
        } else { usageForecastAlerted = false }
    }

    private func applyPlanFailure() {
        if plan == nil { burn = nil }
        planFetchFailing = true
        planFetchInFlight = false
        let retry = min(planRetryDelay, 300.0)
        planRetryDelay = min(planRetryDelay * 2, 300.0)
        lastPlanFetch = .distantPast
        DispatchQueue.main.asyncAfter(deadline: .now() + retry) { [weak self] in self?.loadPlan() }
    }

    private func scheduleResetRefresh(_ reset: Date?) {
        resetTimer?.invalidate(); resetTimer = nil
        guard let reset = reset else { return }
        let delay = reset.timeIntervalSinceNow + 3
        guard delay > 0 else { return }
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.objectWillChange.send()
            self.loadPlan()
        }
        resetTimer = t
        RunLoop.main.add(t, forMode: .common)
    }

    private func computeBurn(_ p: PlanUsage, _ now: Date) -> BurnInfo? {
        let recent = history.filter { now.timeIntervalSince($0.t) <= 1800 }
        if let first = recent.first, let last = recent.last, recent.count >= 3 {
            let dt = last.t.timeIntervalSince(first.t)
            if dt >= 300 {
                let rate = (last.util - first.util) / dt * 3600
                guard rate > 0.5 else {
                    return BurnInfo(ratePerHour: max(rate, 0), timeToLimit: nil, willHitBeforeReset: false)
                }
                let secsToLimit = max(100 - p.fiveHourPct, 0) / (rate / 3600)
                let toReset = p.fiveHourReset.map { $0.timeIntervalSince(now) } ?? .infinity
                return BurnInfo(ratePerHour: rate, timeToLimit: secsToLimit, willHitBeforeReset: secsToLimit < toReset)
            }
        }
        if let reset = p.fiveHourReset {
            let hrs = now.timeIntervalSince(reset.addingTimeInterval(-18000)) / 3600
            if hrs > 0.05 {
                return BurnInfo(ratePerHour: max(p.fiveHourPct / hrs, 0), timeToLimit: nil, willHitBeforeReset: false)
            }
        }
        return nil
    }
}
