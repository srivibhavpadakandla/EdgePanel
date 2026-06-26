// EdgeSnapshot — a JSON-serializable mirror of everything the panel shows, for
// the iPhone companion. Served (token-protected) over the LAN by AppDelegate.
// Dates are epoch seconds so any client decodes them trivially.

import Foundation

struct EdgeSnapshot: Codable {
    var generatedAt: Double
    var plan: PlanInfo?
    var spend: Spend
    var working: [Working]
    var activity: [Activity]
    var calendar: [CalDay]

    struct PlanInfo: Codable {
        var fiveHourPct: Double
        var weekPct: Double
        var fiveHourResetEpoch: Double?
        var weekResetEpoch: Double?
        var burnPerHour: Double?
        var limitClockEpoch: Double?
    }
    struct Spend: Codable {
        var fiveHourUSD: Double
        var perModel: [ModelSpend]
        struct ModelSpend: Codable { var name: String; var costUSD: Double; var tokens: Int }
    }
    struct Working: Codable {
        var id: String
        var project: String
        var model: String?
        var prompt: String?
        var promptSummary: String?
        var promptAtEpoch: Double?
        var turnTokens: Int
    }
    struct Activity: Codable {
        var tool: String
        var summary: String
        var filePath: String?
        var atEpoch: Double
    }
    struct CalDay: Codable { var day: Int; var tokens: Int }

    @MainActor
    static func build(store: UsageStore, state: EdgePanelState) -> EdgeSnapshot {
        let s = store.summary
        let now = Date()

        let plan: PlanInfo? = store.plan.map { p in
            PlanInfo(fiveHourPct: store.displayFiveHourPct ?? p.fiveHourPct,
                     weekPct: p.weekPct,
                     fiveHourResetEpoch: p.fiveHourReset?.timeIntervalSince1970,
                     weekResetEpoch: p.weekReset?.timeIntervalSince1970,
                     burnPerHour: store.burn?.ratePerHour,
                     limitClockEpoch: store.limitClock?.timeIntervalSince1970)
        }

        let windowSpend: Double = {
            if let reset = store.plan?.fiveHourReset, reset > now {
                let start = reset.addingTimeInterval(-18000)
                return s.recentEvents.filter { $0.date >= start && $0.date <= reset }.reduce(0) { $0 + $1.cost }
            }
            return s.block?.cost ?? 0
        }()
        let models = (!s.windowModels.isEmpty ? s.windowModels : s.models).prefix(4).map {
            Spend.ModelSpend(name: $0.name, costUSD: $0.cost, tokens: $0.tokens)
        }

        let working = store.sessions.filter { $0.isWorking() }.map { sn in
            Working(id: sn.id, project: sn.project, model: sn.model.map(prettyModel),
                    prompt: sn.promptText, promptSummary: store.promptSummaries[sn.id],
                    promptAtEpoch: sn.promptAt?.timeIntervalSince1970, turnTokens: sn.turnTokens)
        }
        let activity = store.recentTools.map {
            Activity(tool: $0.tool, summary: $0.summary, filePath: $0.filePath, atEpoch: $0.date.timeIntervalSince1970)
        }
        let calendar = s.monthDayTokens.map { CalDay(day: $0.key, tokens: $0.value) }.sorted { $0.day < $1.day }

        return EdgeSnapshot(generatedAt: now.timeIntervalSince1970, plan: plan,
                            spend: Spend(fiveHourUSD: windowSpend, perModel: Array(models)),
                            working: working, activity: activity, calendar: calendar)
    }
}
