// EdgeSnapshot — a JSON-serializable mirror of everything the panel shows, for
// the iPhone companion. Served (token-protected) over the LAN by AppDelegate.
// Dates are epoch seconds so any client decodes them trivially.

import Foundation

struct EdgeSnapshot: Codable {
    var generatedAt: Double
    var plan: PlanInfo?
    var spend: Spend
    var working: [Working]
    var chats: [Chat]
    var calendar: [CalDay]
    var pending: Pending?      // a permission request waiting on you (approve from the phone)

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
    struct Chat: Codable {
        var id: String
        var name: String
        var project: String
        var cwd: String?
        var lastActiveEpoch: Double
    }
    struct CalDay: Codable { var day: Int; var tokens: Int }
    struct Pending: Codable {
        var id: String
        var tool: String
        var summary: String
        var reason: String
        var risk: String          // "read" | "write" | "danger"
        var project: String?
        var preview: [String]     // a few command / diff lines for context
        var allowRule: String
    }

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

        let working = store.sessions.filter { $0.isWorking() }.map { sn in
            Working(id: sn.id, project: sn.project, model: sn.model.map(prettyModel),
                    prompt: sn.promptText, promptSummary: store.promptSummaries[sn.id],
                    promptAtEpoch: sn.promptAt?.timeIntervalSince1970, turnTokens: sn.turnTokens)
        }
        let chats = store.recentChats.map { c in
            Chat(id: c.id, name: c.name(summaries: store.promptSummaries), project: c.project,
                 cwd: c.cwd, lastActiveEpoch: c.lastActive.timeIntervalSince1970)
        }
        let calendar = s.monthDayTokens.map { CalDay(day: $0.key, tokens: $0.value) }.sorted { $0.day < $1.day }

        let pending = state.pending.map { p in
            Pending(id: p.id, tool: p.toolName, summary: p.summary, reason: p.reason,
                    risk: p.risk.rawValue, project: p.project,
                    preview: p.preview.prefix(6).map { $0.text }, allowRule: p.allowRule)
        }

        return EdgeSnapshot(generatedAt: now.timeIntervalSince1970, plan: plan,
                            spend: Spend(fiveHourUSD: windowSpend),
                            working: working, chats: chats, calendar: calendar, pending: pending)
    }
}
