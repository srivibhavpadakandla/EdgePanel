import Foundation
import WidgetKit

/// Bridges the live usage % from the app to the Lock Screen / Home Screen widget via a shared
/// App Group (the widget runs in its own process and can't read the app's UserDefaults).
enum UsageShared {
    static let suite = "group.com.srivibhav.edgepanel"
    private static var store: UserDefaults? { UserDefaults(suiteName: suite) }

    /// Called by the app on each poll. Only reloads the widget when the displayed % actually
    /// changes (WidgetKit rate-limits reloads, and the % only moves a point at a time).
    static func write(fiveHourPct rawFive: Double, weekPct rawWeek: Double, fiveHourResetEpoch: Double?) {
        guard let d = store else { return }
        // Sanitize: a non-finite/out-of-range % (corrupted source) would trap Int(Double.inf) in
        // the widget. Clamp to a sane range so the widget can never crash on it.
        let fiveHourPct = rawFive.isFinite ? min(max(rawFive, 0), 999) : 0
        let weekPct = rawWeek.isFinite ? min(max(rawWeek, 0), 999) : 0
        let prev = d.object(forKey: "fiveHourPct") as? Double
        d.set(fiveHourPct, forKey: "fiveHourPct")
        d.set(weekPct, forKey: "weekPct")
        d.set(fiveHourResetEpoch ?? 0, forKey: "fiveHourResetEpoch")
        d.set(Date().timeIntervalSince1970, forKey: "updatedAt")
        if prev == nil || Int(prev!.rounded()) != Int(fiveHourPct.rounded()) {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    struct Snapshot { let five: Double; let week: Double; let reset: Date?; let updated: Date }
    static func read() -> Snapshot? {
        guard let d = store, let u = d.object(forKey: "updatedAt") as? Double else { return nil }
        let reset = d.double(forKey: "fiveHourResetEpoch")
        return Snapshot(five: d.double(forKey: "fiveHourPct"),
                        week: d.double(forKey: "weekPct"),
                        reset: reset > 0 ? Date(timeIntervalSince1970: reset) : nil,
                        updated: Date(timeIntervalSince1970: u))
    }
}
