import ActivityKit
import Foundation

// Shared between the app (which starts/updates/ends the activity) and the widget
// extension (which renders it on the Lock Screen + Dynamic Island).
struct WorkingAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var project: String
        var prompt: String
        var startEpoch: Double      // when the prompt was submitted (self-ticking timer)
        var tokens: Int
        var done: Bool
        var doneDetail: String?     // e.g. "4m 12s · 32K tokens"
        var start: Date { Date(timeIntervalSince1970: startEpoch) }
    }
    var sessionId: String
}
