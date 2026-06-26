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
        var start: Date { Date(timeIntervalSince1970: startEpoch) }
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
