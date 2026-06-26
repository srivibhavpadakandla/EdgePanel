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
    private var pushTokenTask: Task<Void, Never>?

    /// Set by EdgeClient to forward APNs tokens to the Mac (Tier 2). (kind, sessionId?, hexToken)
    var onPushToken: ((String, String?, String) -> Void)?

    func requestNotifications() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        // Allow / Deny buttons right on the permission notification.
        let allow = UNNotificationAction(identifier: "ALLOW", title: "Allow", options: [.authenticationRequired])
        let deny  = UNNotificationAction(identifier: "DENY",  title: "Deny",  options: [.destructive, .authenticationRequired])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "PERMISSION", actions: [allow, deny],
                                   intentIdentifiers: [], options: [])
        ])
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
        c.body = q.items.first.map { $0.header.isEmpty ? $0.question : $0.header } ?? "Tap to choose an answer"
        c.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "q-\(q.id)", content: c, trigger: nil))
    }

    /// Reconcile the aggregate Live Activity with the current working sessions.
    func sync(working: [EdgeSnapshot.Working]) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let nowIds = Set(working.map { $0.id })

        // Sessions that were running last tick but aren't now → finished → notify.
        let finished = last.values.filter { !nowIds.contains($0.id) }
        for w in finished { notify(title: "✓ \(w.project) finished", body: doneDetail(w)) }

        // The timer freezes ~90s after the last update — so on the Lock Screen it
        // stops on its own instead of ticking forever once a turn finishes while the
        // app is suspended. While the app is alive each update pushes this forward.
        let freezeAt = Date().addingTimeInterval(90).timeIntervalSince1970
        let lines = working.map { w in
            WorkingAttributes.Line(
                id: w.id, project: w.project, prompt: w.display,
                startEpoch: w.promptAtEpoch ?? Date().timeIntervalSince1970,
                tokens: w.turnTokens, freezeAt: freezeAt)
        }
        last = Dictionary(working.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Nothing running → flip the activity to a brief "done" state, then end it.
        if lines.isEmpty {
            guard let act = aggregate else { return }
            let detail = finished.count == 1 ? doneDetail(finished[0])
                       : finished.isEmpty   ? "finished"
                                            : "\(finished.count) chats finished"
            let done = WorkingAttributes.ContentState(sessions: [], done: true, doneDetail: detail)
            Task {
                await act.update(ActivityContent(state: done, staleDate: nil))
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await act.end(ActivityContent(state: done, staleDate: nil),
                              dismissalPolicy: .after(Date().addingTimeInterval(15)))
            }
            aggregate = nil
            pushTokenTask?.cancel(); pushTokenTask = nil
            return
        }

        // Requested with a push token: the Mac pushes "end" (and membership updates)
        // the instant a turn finishes, so the Island stops seamlessly even fully
        // closed — no app wake-up needed. The bounded timer still self-ticks live.
        let state = WorkingAttributes.ContentState(sessions: lines, done: false, doneDetail: nil)
        let content = ActivityContent(state: state, staleDate: nil)
        if let act = aggregate {
            Task { await act.update(content) }
        } else if let act = try? Activity.request(
            attributes: WorkingAttributes(id: "edgepanel"), content: content, pushType: .token) {
            aggregate = act
            observePushToken(act)
        }
    }

    /// Forward the Live Activity's APNs push token to the Mac, so it can end/update
    /// the Island via push when the app is suspended or fully closed (Tier 2).
    private func observePushToken(_ act: Activity<WorkingAttributes>) {
        pushTokenTask?.cancel()
        pushTokenTask = Task {
            for await tokenData in act.pushTokenUpdates {
                let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                onPushToken?("activity", "edgepanel", hex)
            }
        }
    }

    /// Usage guardrail: notify once when crossing 80% / 90% (re-arms on reset).
    func checkUsage(plan: EdgeSnapshot.PlanInfo?) {
        guard let pct = plan?.fiveHourPct else { return }
        if pct < lastPlanPct - 5 { alertedAt.removeAll() }   // window reset → re-arm
        lastPlanPct = pct
        for threshold in [80, 90] where pct >= Double(threshold) && !alertedAt.contains(threshold) {
            alertedAt.insert(threshold)
            notify(title: "⚠︎ \(threshold)% of your 5-hour limit", body: "Now at \(Int(pct.rounded()))% — ease off or you'll hit the cap.")
        }
    }

    private func doneDetail(_ w: EdgeSnapshot.Working) -> String {
        let elapsed = w.promptAt.map { max(Date().timeIntervalSince($0), 0) } ?? 0
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
