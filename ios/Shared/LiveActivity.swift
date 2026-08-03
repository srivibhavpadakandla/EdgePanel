import ActivityKit
import Foundation

// Shared between the app (which starts/updates/ends the activity) and the widget
// extension (which renders it on the Lock Screen + Dynamic Island).
//
// ONE aggregate activity represents ALL prompts currently running, so two (or
// more) concurrent prompts show together in the Live Activity / Dynamic Island —
// iOS only surfaces a single activity in the Island at a time, so we can't use
// one-activity-per-prompt and expect both to appear.
struct WorkingAttributes: ActivityAttributes {
    public struct Line: Codable, Hashable, Identifiable {
        var id: String              // session id
        var project: String
        var prompt: String
        var startEpoch: Double      // when the prompt was submitted (self-ticking timer)
        var tokens: Int
        var agents: Int = 0         // subagents running this turn (live proof-of-work)
        var queued: Int = 0         // prompts waiting in line behind this turn
        var activity: String = ""   // what it's doing right now, e.g. "Editing Chat.swift"
        var freezeAt: Double = 0    // wall-clock the timer stops at (app refreshes it forward while alive)
        // Cap the lower bound at "now" so the count-up always starts ticking from 0 even
        // under Mac/phone clock skew or a missing promptAtEpoch (it never sticks at 00:00).
        var start: Date { min(Date(timeIntervalSince1970: startEpoch), Date()) }
        /// Upper bound for the bounded timer — the count-up freezes here once the app
        /// stops updating (e.g. phone locked), so it doesn't tick forever after a turn
        /// finishes off-screen.
        var freezeEnd: Date { Date(timeIntervalSince1970: max(freezeAt, startEpoch + 1)) }
    }
    public struct ContentState: Codable, Hashable {
        var sessions: [Line]        // every prompt running right now
        var done: Bool              // transient end state (all finished)
        var doneDetail: String?     // e.g. "4m 12s · 32K tokens" or "2 chats finished"

        // Interactive permission overlay — when `permId` is non-nil, ONE pending permission is
        // awaiting a decision. The widget then renders Allow / Deny / Always buttons (driven by
        // PermissionDecisionIntent) so it can be approved right from the Lock Screen / Dynamic
        // Island without opening the app. Cleared (nil) when there is no pending permission.
        var permId: String? = nil
        var permTool: String? = nil
        var permRisk: String? = nil   // "read" | "write" | "danger" → button tint

        var count: Int { sessions.count }
        /// The longest-running prompt (earliest start) — the headline timer.
        var primary: Line? { sessions.min(by: { $0.startEpoch < $1.startEpoch }) }
        /// A permission is awaiting a decision → show the interactive Allow/Deny/Always UI.
        var hasPermission: Bool { permId != nil }
    }
    var id: String   // constant for the single aggregate activity
}

// MARK: - Lenient decoding
// ActivityKit decodes ContentState (and its nested Lines) straight from the APNs push payload.
// Swift's synthesized Decodable IGNORES property defaults and throws `keyNotFound` on ANY missing
// non-optional key — so if the Mac's payload omits a newer field (agents / queued / activity /
// freezeAt on a Line, or done / sessions on ContentState) the WHOLE update is dropped and the Island
// freezes. These decoders fall back to each field's default instead. Defined in extensions so the
// synthesized memberwise initializers (used to BUILD state in the app) are preserved.

extension WorkingAttributes.Line {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)                                  // session id — always sent
        project = (try? c.decode(String.self, forKey: .project)) ?? ""
        prompt = (try? c.decode(String.self, forKey: .prompt)) ?? ""
        startEpoch = (try? c.decode(Double.self, forKey: .startEpoch)) ?? 0
        tokens = (try? c.decode(Int.self, forKey: .tokens)) ?? 0
        agents = (try? c.decode(Int.self, forKey: .agents)) ?? 0
        queued = (try? c.decode(Int.self, forKey: .queued)) ?? 0
        activity = (try? c.decode(String.self, forKey: .activity)) ?? ""
        freezeAt = (try? c.decode(Double.self, forKey: .freezeAt)) ?? 0               // 0 → freezeEnd falls back to startEpoch+1
    }
}

extension WorkingAttributes.ContentState {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessions = (try? c.decode([WorkingAttributes.Line].self, forKey: .sessions)) ?? []
        done = (try? c.decode(Bool.self, forKey: .done)) ?? false
        doneDetail = try? c.decode(String.self, forKey: .doneDetail)
        permId = try? c.decode(String.self, forKey: .permId)
        permTool = try? c.decode(String.self, forKey: .permTool)
        permRisk = try? c.decode(String.self, forKey: .permRisk)
    }
}
