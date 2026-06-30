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

        var count: Int { sessions.count }
        /// The longest-running prompt (earliest start) — the headline timer.
        var primary: Line? { sessions.min(by: { $0.startEpoch < $1.startEpoch }) }
    }
    var id: String   // constant for the single aggregate activity
}
