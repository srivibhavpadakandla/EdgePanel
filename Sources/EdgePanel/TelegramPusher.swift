// TelegramPusher — reliable "notify me anywhere" via a Telegram bot, independent of Apple's push
// token (which goes stale) AND of any ntfy subscription. The always-running Mac calls the Bot API
// sendMessage; the message lands in your Telegram chat with the bot. Telegram's own push is rock
// solid, so this is the most dependable of the three notification paths.
//
// GATED behind ~/.edgepanel/telegram.json — absent (or no chatId yet) ⇒ disabled:
//   { "token": "<bot token from @BotFather>", "chatId": 123456789 }
// The token is a SECRET — keep this file private (chmod 600), NEVER commit it (it lives in
// ~/.edgepanel, outside the repo, next to apns.json / ntfy.json).

import Foundation

struct TelegramConfig {
    let token: String
    let chatId: String

    static func load() -> TelegramConfig? {
        let path = ("~/.edgepanel/telegram.json" as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = (j["token"] as? String), !token.isEmpty else { return nil }
        // chatId may be written as a JSON number or a string.
        let chatId: String? = (j["chatId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (j["chatId"] as? Int).map(String.init)
            ?? (j["chatId"] as? Int64).map(String.init)
        guard let cid = chatId, !cid.isEmpty else { return nil }   // no chatId yet → stay disabled
        return TelegramConfig(token: token, chatId: cid)
    }
}

final class TelegramPusher: @unchecked Sendable {
    static let shared = TelegramPusher()
    private let config = TelegramConfig.load()
    var enabled: Bool { config != nil }

    /// "✓ project finished · 2m 14s · 26K tokens"
    func pushDone(title: String, detail: String) { send("✓ \(title)\n\(detail)") }

    /// "Claude is asking you" — answer in the EdgePanel app (questions can be multi-select).
    func pushQuestion(title: String, body: String) { send("❓ \(title)\n\(body)") }

    /// A permission alert. (Text only for now — Allow/Deny happen in the app or via the ntfy
    /// buttons; a Telegram inline keyboard could be added later with a callback handler.)
    func pushPermission(tool: String, summary: String, risk: String) {
        let icon = risk == "danger" ? "🚨" : "🔒"
        send("\(icon) \(tool) needs approval\n\(summary.isEmpty ? "Open EdgePanel to Allow / Deny" : summary)")
    }

    private func send(_ text: String) {
        guard let config,
              let url = URL(string: "https://api.telegram.org/bot\(config.token)/sendMessage"),
              let data = try? JSONSerialization.data(withJSONObject: [
                "chat_id": config.chatId, "text": text, "disable_web_page_preview": true]) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        URLSession.shared.dataTask(with: req) { d, resp, _ in
            if let code = (resp as? HTTPURLResponse)?.statusCode, code >= 300 {
                let msg = d.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                NSLog("Telegram sendMessage failed: HTTP \(code) \(msg.prefix(200))")
            }
        }.resume()
    }
}
