import Foundation

// Pure, side-effect-free extractions of the usage math so it can be unit-tested (UsageStore's own
// methods are @MainActor with UserDefaults side effects). UsageStore delegates to these; the tests
// exercise them directly. Every branch here maps to a real bug the audits found.
enum UsageMath {

    // MARK: Burn rate / projection

    /// The burn note's model. Given the recent utilization samples and the current reading, either:
    ///  • a MEASURED recent-trend rate (≥3 samples spanning ≥5 min) with a real willHitBeforeReset
    ///    projection, or
    ///  • a fallback whole-window AVERAGE (isAverage=true) — stated as a fact, never projected
    ///    (projecting an average produced the "+95%/hr · lasts the full window" contradiction), or
    ///  • nil when there's not even enough elapsed window to average.
    static func computeBurn(history: [(t: Date, util: Double)], pct: Double, reset: Date?, now: Date) -> BurnInfo? {
        let recent = history.filter { now.timeIntervalSince($0.t) <= 1800 }
        if let first = recent.first, let last = recent.last, recent.count >= 3 {
            let dt = last.t.timeIntervalSince(first.t)
            if dt >= 300 {
                let rate = (last.util - first.util) / dt * 3600
                guard rate > 0.5 else {
                    return BurnInfo(ratePerHour: max(rate, 0), timeToLimit: nil, willHitBeforeReset: false)
                }
                let secsToLimit = max(100 - pct, 0) / (rate / 3600)
                let toReset = reset.map { $0.timeIntervalSince(now) } ?? .infinity
                return BurnInfo(ratePerHour: rate, timeToLimit: secsToLimit, willHitBeforeReset: secsToLimit < toReset)
            }
        }
        if let reset {
            let hrs = now.timeIntervalSince(reset.addingTimeInterval(-18000)) / 3600
            if hrs > 0.05 {
                return BurnInfo(ratePerHour: max(pct / hrs, 0), timeToLimit: nil, willHitBeforeReset: false, isAverage: true)
            }
        }
        return nil
    }

    // MARK: Usage-limit alert dedup

    struct AlertOutcome: Equatable {
        var fires: [Int]        // thresholds crossed THIS step → fire an alert (in ascending order)
        var alerted: Set<Int>   // new dedup set (which thresholds have fired this window)
        var windowRolled: Bool  // the 5-hour window rolled → caller also re-arms the forecast alert
        var newLastReset: Date? // caller persists this (only advances when a real reset is present)
    }

    /// One dedup step for the 80/90/100 usage alerts. Pure: no persistence, no notifications.
    /// - Re-arms the whole set ONLY on a true window roll (both resets present and differ) — a nil
    ///   reset (absent/unparseable resets_at on a 200) must NOT clear the dedup (that re-fired the
    ///   alerts on every flap and cleared them forever).
    /// - 80/90 use ±8 hysteresis; 100 ("limit reached") LATCHES until a roll (never re-armed by a dip).
    static func usageAlertStep(pct: Double,
                               reset: Date?,
                               lastReset: Date?,
                               alerted: Set<Int>,
                               thresholds: [Int] = [80, 90, 100]) -> AlertOutcome {
        var alerted = alerted
        var lastReset = lastReset
        var rolled = false
        if let reset {
            if reset != lastReset { alerted.removeAll(); rolled = true }
            lastReset = reset
        }
        var fires: [Int] = []
        for thr in thresholds.sorted() {
            if thr != 100, pct < Double(thr) - 8 { alerted.remove(thr) }
            if pct >= Double(thr), !alerted.contains(thr) {
                alerted.insert(thr)
                fires.append(thr)
            }
        }
        return AlertOutcome(fires: fires, alerted: alerted, windowRolled: rolled, newLastReset: lastReset)
    }
}
