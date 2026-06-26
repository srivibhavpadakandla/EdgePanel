import ActivityKit
import UserNotifications
import UIKit
import Foundation

/// Drives Live Activities (Dynamic Island) from the working-now state, and fires
/// local notifications when a prompt finishes or usage crosses a threshold.
@MainActor
final class ActivityManager {
    static let shared = ActivityManager()

    private var activities: [String: Activity<WorkingAttributes>] = [:]
    private var last: [String: EdgeSnapshot.Working] = [:]
    private var lastPlanPct: Double = 0
    private var alertedAt: Set<Int> = []   // thresholds already alerted this window

    /// Set by EdgeClient to forward APNs tokens to the Mac (Tier 2). (kind, sessionId?, hexToken)
    var onPushToken: ((String, String?, String) -> Void)?

    func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
            guard ok else { return }
            Task { @MainActor in UIApplication.shared.registerForRemoteNotifications() }   // device token (Tier 2)
        }
    }

    /// Reconcile Live Activities with the current working sessions.
    func sync(working: [EdgeSnapshot.Working]) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let nowIds = Set(working.map { $0.id })

        // Start or update an activity per working session.
        for w in working {
            let state = WorkingAttributes.ContentState(
                project: w.project, prompt: w.display,
                startEpoch: w.promptAtEpoch ?? Date().timeIntervalSince1970,
                tokens: w.turnTokens, done: false, doneDetail: nil)
            if let act = activities[w.id] {
                Task { await act.update(ActivityContent(state: state, staleDate: nil)) }
            } else if activities.count < 2 {            // keep the Island uncluttered
                if let act = try? Activity.request(attributes: WorkingAttributes(sessionId: w.id),
                                                   content: ActivityContent(state: state, staleDate: nil),
                                                   pushType: .token) {
                    activities[w.id] = act
                    let sid = w.id
                    Task { @MainActor in   // forward the Live Activity push token to the Mac (Tier 2)
                        for await data in act.pushTokenUpdates {
                            self.onPushToken?("activity", sid, data.map { String(format: "%02x", $0) }.joined())
                        }
                    }
                }
            }
            last[w.id] = w
        }

        // A tracked session that's no longer working → flip to "done", end, notify.
        for (id, act) in activities where !nowIds.contains(id) {
            let prev = last[id]
            let detail = doneDetail(prev)
            let done = WorkingAttributes.ContentState(
                project: prev?.project ?? "Chat", prompt: prev?.display ?? "",
                startEpoch: prev?.promptAtEpoch ?? Date().timeIntervalSince1970,
                tokens: prev?.turnTokens ?? 0, done: true, doneDetail: detail)
            Task {
                await act.update(ActivityContent(state: done, staleDate: nil))
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await act.end(ActivityContent(state: done, staleDate: nil),
                              dismissalPolicy: .after(Date().addingTimeInterval(20)))
            }
            notify(title: "✓ \(prev?.project ?? "Chat") finished", body: detail)
            activities[id] = nil
            last[id] = nil
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

    private func doneDetail(_ w: EdgeSnapshot.Working?) -> String {
        guard let w else { return "finished" }
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
