import Foundation
import SwiftUI

// Mirrors EdgeSnapshot served by the Mac (epoch-second dates).
struct EdgeSnapshot: Codable {
    var generatedAt: Double
    var plan: PlanInfo?
    var spend: Spend
    var working: [Working]
    var chats: [Chat]
    var calendar: [CalDay]
    var pending: Pending?
    var question: Question?

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
    struct Working: Codable, Identifiable {
        var id: String
        var project: String
        var cwd: String = ""
        var model: String?
        var prompt: String?
        var promptSummary: String?
        var promptAtEpoch: Double?
        var turnTokens: Int
        var promptAt: Date? { promptAtEpoch.map { Date(timeIntervalSince1970: $0) } }
        /// The prompt to show: the Mac's summary if present, else the raw prompt.
        var display: String { (promptSummary?.isEmpty == false ? promptSummary : prompt) ?? "working…" }
    }
    struct Chat: Codable, Identifiable {
        var id: String
        var name: String
        var project: String
        var cwd: String?
        var lastActiveEpoch: Double
        var lastActive: Date { Date(timeIntervalSince1970: lastActiveEpoch) }
    }
    struct CalDay: Codable, Identifiable {
        var day: Int; var tokens: Int
        var id: Int { day }
    }
    struct Pending: Codable, Identifiable {
        var id: String
        var tool: String
        var summary: String
        var reason: String
        var risk: String          // "read" | "write" | "danger"
        var project: String?
        var preview: [String]
        var allowRule: String
    }
    struct Question: Codable, Identifiable {
        var id: String
        var project: String?
        var items: [Item]
        struct Item: Codable, Identifiable {
            var question: String
            var header: String
            var multiSelect: Bool
            var options: [Opt]
            var id: String { question }
            struct Opt: Codable { var label: String; var description: String? }
        }
    }
}

@MainActor
final class EdgeClient: ObservableObject {
    static let shared = EdgeClient()
    @Published var snapshot: EdgeSnapshot?
    @Published var connected = false
    @Published var lastError: String?

    @AppStorage("edgepanel.host") var host: String = ""   // set by pairing (QR/manual); empty → show pairing
    @AppStorage("edgepanel.token") var token: String = ""

    private var timer: Timer?

    func start() {
        ActivityManager.shared.onPushToken = { [weak self] kind, sid, tok in
            self?.postPushToken(kind: kind, sessionId: sid, pushToken: tok)
        }
        Task { await poll() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { await self?.poll() }
        }
    }
    func stop() { timer?.invalidate(); timer = nil }

    /// Approve / deny / always a held permission request on the Mac, then poll
    /// immediately so the card clears without waiting for the next tick.
    func decidePermission(id: String, decision: String) {
        guard !host.isEmpty, !token.isEmpty,
              let url = URL(string: "http://\(host)/permission/decide") else { return }
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "X-EdgePanel-Token")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["id": id, "decision": decision])
        Task { _ = try? await URLSession.shared.data(for: req); await poll() }
    }

    /// Forward an APNs token to the Mac (Tier 2).
    func postPushToken(kind: String, sessionId: String?, pushToken: String) {
        guard !host.isEmpty, !token.isEmpty, let url = URL(string: "http://\(host)/pushtoken") else { return }
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "X-EdgePanel-Token")
        var body: [String: Any] = ["kind": kind, "token": pushToken]
        if let sessionId { body["sessionId"] = sessionId }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        Task { _ = try? await URLSession.shared.data(for: req) }
    }

    struct ChatJob: Codable { var status: String; var result: String?; var sessionId: String?; var error: String? }

    /// Answer a held AskUserQuestion. answers = {questionText: "label" or "a,b"}.
    func answerQuestion(id: String, answers: [String: String]) {
        guard !host.isEmpty, !token.isEmpty, let url = URL(string: "http://\(host)/question/decide") else { return }
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "X-EdgePanel-Token")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["id": id, "answers": answers])
        Task { _ = try? await URLSession.shared.data(for: req); await poll() }
    }

    /// Send a message to Claude Code on the Mac; returns a jobId to poll.
    func sendChat(cwd: String, sessionId: String?, message: String) async -> String? {
        guard !host.isEmpty, !token.isEmpty, let url = URL(string: "http://\(host)/chat") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "X-EdgePanel-Token")
        var body: [String: Any] = ["message": message, "cwd": cwd]
        if let sessionId { body["sessionId"] = sessionId }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["jobId"] as? String
    }

    /// Load a session's real conversation history from the Mac transcript.
    func fetchHistory(sessionId: String, cwd: String) async -> [(role: String, text: String)] {
        guard !host.isEmpty, !token.isEmpty, let url = URL(string: "http://\(host)/chat/history") else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "X-EdgePanel-Token")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": sessionId, "cwd": cwd])
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["messages"] as? [[String: String]] else { return [] }
        return arr.compactMap { m in
            guard let r = m["role"], let t = m["text"] else { return nil }
            return (r, t)
        }
    }

    /// Poll a chat job until it's done/error.
    func pollChat(_ jobId: String) async -> ChatJob? {
        guard !host.isEmpty, !token.isEmpty, let url = URL(string: "http://\(host)/chat/poll") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "X-EdgePanel-Token")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["jobId": jobId])
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return try? JSONDecoder().decode(ChatJob.self, from: data)
    }

    /// Ask the Mac to resume this chat (opens it in VS Code on the Mac).
    func openChat(_ chat: EdgeSnapshot.Chat) {
        guard let url = URL(string: "http://\(host)/open") else { return }
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "X-EdgePanel-Token")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["id": chat.id, "cwd": chat.cwd ?? ""])
        Task { _ = try? await URLSession.shared.data(for: req) }
    }

    func poll() async {
        guard !host.isEmpty, !token.isEmpty,
              let url = URL(string: "http://\(host)/snapshot") else {
            connected = false; lastError = "Set the Mac address + token"; return
        }
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.setValue(token, forHTTPHeaderField: "X-EdgePanel-Token")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let code = (resp as? HTTPURLResponse)?.statusCode else { throw URLError(.badServerResponse) }
            if code == 401 { connected = false; lastError = "Wrong token"; return }
            guard code == 200 else { throw URLError(.badServerResponse) }
            let snap = try JSONDecoder().decode(EdgeSnapshot.self, from: data)
            snapshot = snap; connected = true; lastError = nil
            ActivityManager.shared.sync(working: snap.working)
            ActivityManager.shared.checkUsage(plan: snap.plan)
            ActivityManager.shared.syncPermission(snap.pending)
            ActivityManager.shared.syncQuestion(snap.question)
        } catch {
            connected = false
            lastError = (error as? URLError)?.code == .cannotConnectToHost
                ? "Can’t reach the Mac — is EdgePanel running?"
                : error.localizedDescription
        }
    }
}
