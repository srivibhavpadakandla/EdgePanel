import Foundation
import Testing
@testable import EdgePanel

// Locks the usage-alert dedup + burn-projection fixes that kept regressing. Each case is a concrete
// sequence from a real bug report / audit finding.

private let D1 = Date(timeIntervalSince1970: 1_000_000)
private let D2 = Date(timeIntervalSince1970: 2_000_000)  // a later window's reset

// Threads state through a sequence of (pct, reset) readings, collecting the fires at each step.
private func fires(_ steps: [(Double, Date?)], startReset: Date? = nil) -> [[Int]] {
    var alerted: Set<Int> = []
    var last = startReset
    var out: [[Int]] = []
    for (pct, reset) in steps {
        let o = UsageMath.usageAlertStep(pct: pct, reset: reset, lastReset: last, alerted: alerted)
        alerted = o.alerted; last = o.newLastReset
        out.append(o.fires)
    }
    return out
}

@Suite("UsageMath · alert dedup")
struct UsageAlertStepTests {
    @Test("each threshold fires once as usage climbs")
    func climbsFireOnce() {
        #expect(fires([(85, D1)]) == [[80]])
        #expect(fires([(85, D1), (92, D1)]) == [[80], [90]])
        #expect(fires([(50, D1), (95, D1)]) == [[], [80, 90]])
    }

    @Test("no re-fire when % oscillates near the cap (96→90→95)")
    func nearCapOscillation() {
        #expect(fires([(96, D1), (90, D1), (95, D1)]) == [[80, 90], [], []])
    }

    @Test("100% 'limit reached' latches — a dip+recross (100→91→100) does not re-fire it")
    func limitLatches() {
        #expect(fires([(100, D1), (91, D1), (100, D1)]) == [[80, 90, 100], [], []])
    }

    @Test("80/90 warnings use ±8 hysteresis: a shallow dip doesn't re-arm, a deep one does")
    func hysteresis() {
        #expect(fires([(85, D1), (79, D1), (85, D1)]) == [[80], [], []])   // 79 > 80-8 → no re-arm
        #expect(fires([(85, D1), (70, D1), (85, D1)]) == [[80], [], [80]]) // 70 < 72 → re-arms, re-fires
    }

    @Test("a nil reset (absent/unparseable resets_at) does NOT re-arm — the flap-spam bug")
    func nilResetHoldsDedup() {
        // Was: nil⇄date treated as a window roll → re-fired 80 on every flap.
        #expect(fires([(85, D1), (85, nil), (85, D1)]) == [[80], [], []])
    }

    @Test("a persistently-nil reset fires once and never clears the dedup (the die-forever bug)")
    func persistentNilDoesNotClear() {
        #expect(fires([(85, nil), (85, nil), (85, nil)], startReset: nil) == [[80], [], []])
    }

    @Test("a true window roll re-arms the whole set")
    func windowRollRearms() {
        #expect(fires([(85, D1), (85, D2)]) == [[80], [80]])
        let o = UsageMath.usageAlertStep(pct: 85, reset: D2, lastReset: D1, alerted: [80])
        #expect(o.windowRolled)
        #expect(!UsageMath.usageAlertStep(pct: 85, reset: D1, lastReset: D1, alerted: [80]).windowRolled)
    }
}

@Suite("UsageMath · burn projection")
struct ComputeBurnTests {
    @Test("no recent trend → whole-window AVERAGE, stated not projected")
    func averageFallback() {
        let now = Date()
        let reset = now.addingTimeInterval(4 * 3600)      // window started 1h ago (reset-5h)
        let b = UsageMath.computeBurn(history: [], pct: 95, reset: reset, now: now)
        #expect(b?.isAverage == true)
        #expect(b?.willHitBeforeReset == false)          // an average must never project
        #expect((b?.ratePerHour ?? 0) > 90)              // ~95%/hr over 1h
    }

    @Test("a measured climbing trend projects willHitBeforeReset")
    func measuredTrendProjects() {
        let now = Date()
        let hist: [(t: Date, util: Double)] = [
            (now.addingTimeInterval(-600), 10),
            (now.addingTimeInterval(-300), 15),
            (now, 20),
        ]
        let b = UsageMath.computeBurn(history: hist, pct: 20, reset: now.addingTimeInterval(2 * 3600), now: now)
        #expect(b?.isAverage == false)
        #expect(b?.willHitBeforeReset == true)           // ~60%/hr from 20% hits 100 in ~80min < 2h
        #expect(b?.timeToLimit != nil)
    }

    @Test("a measured FLAT trend is not average and won't hit")
    func measuredFlat() {
        let now = Date()
        let hist: [(t: Date, util: Double)] = [
            (now.addingTimeInterval(-600), 50),
            (now.addingTimeInterval(-300), 50),
            (now, 50),
        ]
        let b = UsageMath.computeBurn(history: hist, pct: 50, reset: now.addingTimeInterval(3600), now: now)
        #expect(b?.isAverage == false)
        #expect(b?.willHitBeforeReset == false)
        #expect(b?.timeToLimit == nil)
    }

    @Test("too little elapsed window → nil (nothing to project or average)")
    func notEnoughData() {
        let now = Date()
        #expect(UsageMath.computeBurn(history: [], pct: 5, reset: nil, now: now) == nil)
        // window started ~1 min ago (reset ≈ now+4h59m) → hrs < 0.05 → nil
        #expect(UsageMath.computeBurn(history: [], pct: 5, reset: now.addingTimeInterval(4 * 3600 + 3540), now: now) == nil)
    }
}
