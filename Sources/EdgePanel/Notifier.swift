// Notifier — the ONE place every EdgePanel notification goes out, broadcasting to ALL configured
// channels at once: APNs device push · ntfy · Telegram. Every alert routes through these three
// methods, so a notification is never delivered to only some channels, and adding a new channel
// is a single-file change here (not a hunt through every call site).
//
// Each underlying pusher self-gates on its own config (APNs needs apns.json + a device token,
// ntfy needs ntfy.json, Telegram needs telegram.json), so a call is a safe no-op for any channel
// that isn't set up.

import Foundation

enum Notifier {
    /// Quiet hours suppress ONLY the non-urgent "done"/usage alerts — permissions and questions
    /// always fire (they block Claude). Off unless ~/.edgepanel/notify.json sets it, e.g.
    /// { "quietStartHour": 23, "quietEndHour": 8 } — local hours, overnight wrap supported.
    static func inQuietHours(now: Date = Date()) -> Bool {
        guard let data = FileManager.default.contents(atPath: ("~/.edgepanel/notify.json" as NSString).expandingTildeInPath),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let start = j["quietStartHour"] as? Int, let end = j["quietEndHour"] as? Int,
              (0...23).contains(start), (0...23).contains(end), start != end else { return false }
        let h = Calendar.current.component(.hour, from: now)
        return start < end ? (h >= start && h < end) : (h >= start || h < end)
    }

    /// A "done" / usage / generic alert → every channel.
    static func alert(deviceToken: String?, title: String, body: String) {
        if inQuietHours() { return }   // non-urgent → suppressed during configured quiet hours
        if APNsPusher.shared.enabled, let dt = deviceToken {
            APNsPusher.shared.pushAlert(deviceToken: dt, title: title, body: body)
        }
        NtfyPusher.shared.pushDone(title: title, detail: body)
        TelegramPusher.shared.pushDone(title: title, detail: body)
    }

    /// A question ("Claude is asking you") → every channel.
    static func question(deviceToken: String?, id: String, title: String, body: String) {
        if APNsPusher.shared.enabled, let dt = deviceToken {
            APNsPusher.shared.pushAlert(deviceToken: dt, title: title, body: body, questionId: id)
        }
        NtfyPusher.shared.pushQuestion(title: title, body: body)
        TelegramPusher.shared.pushQuestion(title: title, body: body)
    }

    /// A permission request → every channel (ntfy carries Allow / Deny / Always action buttons).
    static func permission(deviceToken: String?, id: String, tool: String, summary: String, risk: String) {
        if APNsPusher.shared.enabled, let dt = deviceToken {
            APNsPusher.shared.pushPermission(deviceToken: dt, id: id, title: "\(tool) needs approval", body: summary)
        }
        NtfyPusher.shared.pushPermission(id: id, tool: tool, summary: summary, risk: risk)
        TelegramPusher.shared.pushPermission(tool: tool, summary: summary, risk: risk)
    }
}
