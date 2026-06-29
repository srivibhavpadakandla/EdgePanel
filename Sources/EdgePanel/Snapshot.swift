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
    var question: Question?    // an AskUserQuestion waiting on you (answer from the phone)
    var autoApprove: Bool = false   // Autonomous mode is on (every permission auto-allowed)
    var mode: String = "ask"        // permission mode: ask | edit | plan | auto | bypass
    var effort: String = ""         // reasoning effort: low | medium | high | ultra | "" (unknown)
    var mascotAnim: String = "idle_blink"   // live mascot posture — phone can mirror it
    var promptHistory: [PromptItem] = []    // recent human-typed prompts, newest first
    // The live editor session you're working in at the Mac — the phone's "Editor" chat
    // targets this so typing on the phone types into the Claude Code chat open here.
    var editorSessionId: String?
    var editorCwd: String = ""
    var editorProject: String = ""

    struct PromptItem: Codable {
        var id: String
        var text: String
        var atEpoch: Double
        var project: String
    }

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
        var cwd: String
        var model: String?
        var prompt: String?
        var promptSummary: String?
        var promptAtEpoch: Double?
        var turnTokens: Int
        var runningAgents: Int = 0
        var queuedPrompts: Int = 0
        var isEditor: Bool = false   // editor session you're watching → kept off the Island
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
    struct Question: Codable {
        var id: String
        var project: String?
        var items: [Item]
        struct Item: Codable {
            var question: String
            var header: String
            var multiSelect: Bool
            var options: [Opt]
            struct Opt: Codable { var label: String; var description: String? }
        }
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

        // Publish the DEBOUNCED working set (carries a session for 1 missing scan) rather
        // than the raw isWorking() filter, so a single-scan blip never flickers the phone's
        // Dynamic Island or fires a false "finished". Falls back to the raw filter until the
        // first detectEnded() pass has populated it.
        let workingSrc = store.workingDebounced.isEmpty ? store.sessions.filter { $0.isWorking() }
                                                        : store.workingDebounced
        let working = workingSrc.map { sn in
            Working(id: sn.id, project: sn.project, cwd: sn.cwd, model: sn.model.map(prettyModel),
                    prompt: sn.promptText, promptSummary: store.promptSummaries[sn.id],
                    promptAtEpoch: sn.promptAt?.timeIntervalSince1970, turnTokens: sn.turnTokens,
                    runningAgents: sn.runningAgents, queuedPrompts: sn.queuedPrompts, isEditor: sn.isEditor)
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

        let question = state.pendingQuestion.map { q in
            Question(id: q.id, project: q.project, items: q.items.map { item in
                Question.Item(question: item.question, header: item.header, multiSelect: item.multiSelect,
                              options: item.options.map { Question.Item.Opt(label: $0.label, description: $0.description) })
            })
        }

        return EdgeSnapshot(generatedAt: now.timeIntervalSince1970, plan: plan,
                            spend: Spend(fiveHourUSD: windowSpend),
                            working: working, chats: chats, calendar: calendar,
                            pending: pending, question: question, autoApprove: state.autoApprove,
                            mode: state.normalizedMode, effort: state.normalizedEffort,
                            mascotAnim: state.mascotAnimName,
                            promptHistory: store.promptHistory.map {
                                PromptItem(id: $0.id, text: $0.text,
                                           atEpoch: $0.at.timeIntervalSince1970, project: $0.project)
                            },
                            editorSessionId: store.editorSessionId,
                            editorCwd: store.editorCwd,
                            editorProject: store.editorProject)
    }
}
