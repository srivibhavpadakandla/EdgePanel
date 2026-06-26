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
    // Recent Claude Code chats (sessions), newest first.
    @Published var recentChats: [RecentChat] = []
    // sessionID → short summary of its (long) prompt, from the claude CLI.
    @Published var promptSummaries: [String: String] = [:]

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
        // Keep the "working chats" list fresh (cheap: only reads recently-touched files).
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in self?.refreshSessions() }
    }

    func refreshSessions() {
        sessionQ.async {
            let sessions = UsageLoader.activeSessions()
            DispatchQueue.main.async {
                self.sessions = sessions
                self.updateSummaries(sessions)
            }
        }
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
    private func updateSummaries(_ sessions: [LiveSession]) {
        for s in sessions {
            guard let pt = s.promptText, pt.count > PromptSummarizer.threshold else { continue }
            if let cached = PromptSummarizer.shared.shortLabel(for: pt, onReady: { [weak self] summary in
                self?.promptSummaries[s.id] = summary
            }) {
                promptSummaries[s.id] = cached
            }
        }
    }

    // MARK: - Local usage + context

    func load() {
        loadPlan()
        loading = true
        q.async {
            let s = UsageLoader.computeSummary()
            let sessions = UsageLoader.activeSessions()
            let chats = UsageLoader.recentChats()
            DispatchQueue.main.async {
                self.summary = s
                self.loading = false
                self.sessions = sessions
                self.recentChats = chats
                self.updateSummaries(sessions)
                self.updateChatSummaries(chats)
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
