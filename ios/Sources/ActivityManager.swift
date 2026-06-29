import ActivityKit
import UserNotifications
import UIKit
import Foundation

/// Drives ONE aggregate Live Activity (Dynamic Island) from the working-now
/// state — every running prompt appears in it, so concurrent prompts show
/// together — and fires local notifications when a prompt finishes or usage
/// crosses a threshold.
@MainActor
final class ActivityManager {
    static let shared = ActivityManager()

    private var aggregate: Activity<WorkingAttributes>?
    private var last: [String: EdgeSnapshot.Working] = [:]   // last-seen working set (for done detail)
    private var lastPlanPct: Double = 0
    private var alertedAt: Set<Int> = []   // thresholds already alerted this window
    private var lastPermId: String?        // permission request already surfaced
    private var lastQuestionId: String?    // question already surfaced
    var surfacedPermId: String? { lastPermId }       // for willPresent dedup
    var surfacedQuestionId: String? { lastQuestionId }
    private var pushTokenTask: Task<Void, Never>?
    private var endTask: Task<Void, Never>?   // deferred "done→end" (cancellable if a new turn arrives)
    private var emptyTicks = 0                 // consecutive syncs with no working sessions (done debounce)
    private var pendingDoneDetail: String?     // captured on the first empty tick, used when we finally end

    /// Set by EdgeClient to forward APNs tokens to the Mac (Tier 2). (kind, sessionId?, hexToken)
    var onPushToken: ((String, String?, String) -> Void)?

    func requestNotifications() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            // Register for remote notifications so iOS hands us an APNs DEVICE token —
            // without this the Mac never gets a device token and can't push the
            // "done"/"permission" alert while the app is closed (they only showed up
            // when you opened the app and it polled locally).
            guard granted else { return }
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
        // Allow / Deny buttons right on the permission notification.
        let allow = UNNotificationAction(identifier: "ALLOW", title: "Allow", options: [.authenticationRequired])
        let deny  = UNNotificationAction(identifier: "DENY",  title: "Deny",  options: [.destructive, .authenticationRequired])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "PERMISSION", actions: [allow, deny],
                                   intentIdentifiers: [], options: [])
        ])
        observePushToStart()
    }

    /// Forward the push-to-start token (iOS 17.2+) to the Mac, so it can pop the
    /// Dynamic Island up even when the app is fully closed.
    private func observePushToStart() {
        guard #available(iOS 17.2, *) else { return }
        Task {
            for await tokenData in Activity<WorkingAttributes>.pushToStartTokenUpdates {
                let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                onPushToken?("starttoken", nil, hex)
            }
        }
    }

    /// Surface a NEW permission request as an actionable local notification (works
    /// while the app is foreground / recently backgrounded; APNs covers fully-closed).
    func syncPermission(_ pending: EdgeSnapshot.Pending?) {
        guard let p = pending else { lastPermId = nil; return }
        guard p.id != lastPermId else { return }
        lastPermId = p.id
        let c = UNMutableNotificationContent()
        c.title = "\(p.tool) needs approval"
        c.body = p.summary.isEmpty ? p.reason : p.summary
        c.sound = .default
        c.categoryIdentifier = "PERMISSION"
        c.userInfo = ["permId": p.id]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "perm-\(p.id)", content: c, trigger: nil))
    }

    /// Notify when Claude asks a question (the options are answered in-app).
    func syncQuestion(_ question: EdgeSnapshot.Question?) {
        guard let q = question else { lastQuestionId = nil; return }
        guard q.id != lastQuestionId else { return }
        lastQuestionId = q.id
        let c = UNMutableNotificationContent()
        c.title = "Claude is asking you"
        c.body = q.items.first.map { $0.header.isEmpty ? $0.question : $0.header } ?? "Tap to open and answer"
        c.subtitle = "Tap to answer in the app — it'll wait for you"
        c.sound = .default
        c.interruptionLevel = .timeSensitive   // more prominent + lingers (banner still auto-hides, the card persists)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "q-\(q.id)", content: c, trigger: nil))
    }

    /// Reconcile the aggregate Live Activity with the current working sessions.
    func sync(working rawWorking: [EdgeSnapshot.Working]) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // The Dynamic Island tracks remote/non-editor work only — an editor session you're
        // watching at the Mac would keep it alive forever (it'd "never stop"). The WORKING
        // NOW card still shows everything; this filter is just for the persistent Island.
        let working = rawWorking.filter { !$0.isEditor }
        // Adopt an activity the Mac push-started while we were closed, so we drive the
        // same one (update/end) instead of creating a duplicate.
        if aggregate == nil,
           let existing = Activity<WorkingAttributes>.activities.first(where: {
               $0.activityState == .active || $0.activityState == .stale }) {
            aggregate = existing
            observePushToken(existing)
        }
        let nowIds = Set(working.map { $0.id })

        // Sessions that were running last tick but aren't now → finished. The "finished"
        // ALERT is owned SOLELY by the Mac (APNs pushAlert + ntfy pushDone in
        // EdgePanelState.pushSessionEnded) — debounced 2 scans and reaching the closed app —
        // so a foreground phone no longer gets a duplicate (and undebounced) local banner for
        // the same completion. We still compute `finished` to drive the Island "done" detail.
        let finished = last.values.filter { !nowIds.contains($0.id) }

        // The timer freezes ~90s after the last update — so on the Lock Screen it
        // stops on its own instead of ticking forever once a turn finishes while the
        // app is suspended. While the app is alive each update pushes this forward.
        let freezeAt = Date().addingTimeInterval(90).timeIntervalSince1970
        let lines = working.map { w in
            WorkingAttributes.Line(
                id: w.id, project: w.project, prompt: w.display,
                startEpoch: w.promptAtEpoch ?? Date().timeIntervalSince1970,
                tokens: w.turnTokens, agents: w.runningAgents, queued: w.queuedPrompts, freezeAt: freezeAt)
        }
        last = Dictionary(working.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Nothing running → flip the activity to a brief "done" state, then end it.
        if lines.isEmpty {
            guard let act = aggregate, endTask == nil else { return }   // already ending → don't double-fire
            // Require 2 consecutive empty syncs (~3s) before declaring done — a single
            // missing-session tick (a snapshot built mid-write, the gap between turns) must
            // not flap the Island to "✓ Complete" and tear it down. `finished` is only
            // populated on the FIRST empty tick (after that `last` is already empty), so
            // capture the detail then; fall back to the activity's last primary line.
            if emptyTicks == 0 {
                pendingDoneDetail = finished.count > 1 ? "\(finished.count) chats finished"
                    : finished.first.map { doneDetail($0) }
                    ?? aggregate?.content.state.primary.map { doneDetail(fromLine: $0) }
                    ?? "finished"
            }
            emptyTicks += 1
            guard emptyTicks >= 2 else { return }
            let detail = pendingDoneDetail ?? "finished"
            emptyTicks = 0; pendingDoneDetail = nil
            let done = WorkingAttributes.ContentState(sessions: [], done: true, doneDetail: detail)
            // Keep `aggregate` set until the end actually completes — nil-ing it here let a
            // new turn within the hold window spawn a DUPLICATE activity.
            endTask = Task {
                await act.update(ActivityContent(state: done, staleDate: nil))
                try? await Task.sleep(nanoseconds: 4_000_000_000)   // hold "✓ Complete" visibly
                if Task.isCancelled { return }                      // a new turn reclaimed this activity
                await act.end(ActivityContent(state: done, staleDate: nil),
                              dismissalPolicy: .after(Date().addingTimeInterval(6)))
                // A new turn may have run sync() during the awaits above, cancelling us and
                // re-adopting/recreating `aggregate`. Only tear down if we STILL own it, so the
                // race loser doesn't nil a freshly-adopted activity or its push-token task.
                guard !Task.isCancelled, aggregate?.id == act.id else { return }
                aggregate = nil
                pushTokenTask?.cancel(); pushTokenTask = nil
                endTask = nil
            }
            return
        }

        // Work is present → reset the empty-debounce, and if an "end" is pending cancel it
        // and REUSE the same activity (flip it back to working) rather than ending/duplicating.
        emptyTicks = 0; pendingDoneDetail = nil
        if let t = endTask { t.cancel(); endTask = nil }

        // Requested with a push token: the Mac pushes "end" (and membership updates)
        // the instant a turn finishes, so the Island stops seamlessly even fully
        // closed — no app wake-up needed. The bounded timer still self-ticks live.
        let state = WorkingAttributes.ContentState(sessions: lines, done: false, doneDetail: nil)
        let content = ActivityContent(state: state, staleDate: nil)
        // Update reuses an active OR stale activity — update transitions stale→active, so a
        // push-started (stale) Island is driven back to life instead of stranded as a duplicate.
        if let act = aggregate, act.activityState == .active || act.activityState == .stale {
            Task { await act.update(content) }
        } else {
            // A genuinely dead/ended aggregate → drop the stale reference + tasks so we don't
            // update a corpse, then re-adopt any still-live activity (active or stale, e.g. a
            // push-start race) before creating a duplicate.
            if aggregate != nil {
                aggregate = nil; endTask?.cancel(); endTask = nil
                pushTokenTask?.cancel(); pushTokenTask = nil
            }
            if let existing = Activity<WorkingAttributes>.activities.first(where: { $0.activityState == .active || $0.activityState == .stale }) {
                aggregate = existing; observePushToken(existing)
                Task { await existing.update(content) }
                return
            }
            // Prefer a push-enabled activity (so the Mac can end it via APNs). Fall
            // back to a LOCAL activity if push isn't provisioned — otherwise the
            // Island wouldn't appear at all on a build without a valid push profile.
            let attrs = WorkingAttributes(id: "edgepanel")
            if let act = try? Activity.request(attributes: attrs, content: content, pushType: .token) {
                aggregate = act
                observePushToken(act)
            } else if let act = try? Activity.request(attributes: attrs, content: content) {
                aggregate = act
            }
        }
    }

    /// Forward the Live Activity's APNs push token to the Mac, so it can end/update
    /// the Island via push when the app is suspended or fully closed (Tier 2).
    private var lastActivityTokenHex: String?
    private func observePushToken(_ act: Activity<WorkingAttributes>) {
        pushTokenTask?.cancel()
        pushTokenTask = Task {
            for await tokenData in act.pushTokenUpdates {
                let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                lastActivityTokenHex = hex
                onPushToken?("activity", "edgepanel", hex)
            }
        }
    }

    /// Re-send the current activity token to the Mac (e.g. after the Mac restarted and
    /// forgot it) so it can always push the "end" instead of leaving the Island stuck.
    func resendActivityToken() {
        if let hex = lastActivityTokenHex { onPushToken?("activity", "edgepanel", hex) }
    }

    /// Usage guardrail: notify once when crossing 80% / 90% (re-arms on reset).
    private var forecastAlerted = false
    func checkUsage(plan: EdgeSnapshot.PlanInfo?) {
        guard let pct = plan?.fiveHourPct else { return }
        if pct < lastPlanPct - 5 { alertedAt.removeAll() }   // window reset → re-arm
        lastPlanPct = pct
        for threshold in [80, 90] where pct >= Double(threshold) && !alertedAt.contains(threshold) {
            alertedAt.insert(threshold)
            notify(title: "⚠︎ \(threshold)% of your 5-hour limit", body: "Now at \(Int(pct.rounded()))% — ease off or you'll hit the cap.")
        }
        // Forecast: at the current burn rate you'll hit the cap within ~45 min → one
        // proactive heads-up with the projected time (re-arms when the pace eases).
        if let hit = plan?.limitClockEpoch {
            let mins = Date(timeIntervalSince1970: hit).timeIntervalSinceNow / 60
            // Floor: only forecast once you're actually deep into the window (≥50%), so a
            // noisy early projection right after a window reset can't fire a false alarm.
            if mins > 0, mins <= 45, pct >= 50, !forecastAlerted {
                forecastAlerted = true
                let t = DateFormatter.localizedString(from: Date(timeIntervalSince1970: hit), dateStyle: .none, timeStyle: .short)
                notify(title: "⏳ On track to hit your 5-hour cap", body: "At this pace, around \(t). Ease off or pause autonomous tasks.")
            }
            if mins > 60 || mins <= 0 { forecastAlerted = false }
        } else { forecastAlerted = false }
    }

    /// Done detail synthesized from the Live Activity's own last-known line (used when the
    /// finished session was never tracked locally, e.g. after adopting a push-started Island)
    /// — so the "✓ Complete" card shows a real duration + tokens instead of a bare "finished".
    private func doneDetail(fromLine l: WorkingAttributes.Line) -> String {
        let elapsed = min(max(Date().timeIntervalSince(l.start), 0), 3600)
        let m = Int(elapsed) / 60, s = Int(elapsed) % 60
        let t = m > 0 ? "\(m)m \(s)s" : "\(s)s"
        return "\(t) · \(fmtTokens(l.tokens)) tokens"
    }

    /// Drop the finished-session baseline after a connectivity gap, so the next successful
    /// snapshot RE-SEEDS `last` instead of diffing stale (now-finished) sessions against it
    /// and flapping the Island to a bogus "done". The Mac still owns the real "done" alert.
    func resyncBaseline() { last.removeAll(); emptyTicks = 0; pendingDoneDetail = nil }

    private func doneDetail(_ w: EdgeSnapshot.Working) -> String {
        // Clamp: if the app was suspended for a long time, now-since-start would inflate
        // the figure wildly. A real turn is minutes — cap so we never show a bogus "4h".
        let elapsed = min(w.promptAt.map { max(Date().timeIntervalSince($0), 0) } ?? 0, 3600)
        let m = Int(elapsed) / 60, s = Int(elapsed) % 60
        let t = m > 0 ? "\(m)m \(s)s" : "\(s)s"
        return "\(t) · \(fmtTokens(w.turnTokens)) tokens"
    }

    private func notify(title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
