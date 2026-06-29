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
    var autoApprove: Bool?           // Autonomous mode on (every permission auto-allowed)
    var mode: String?                // permission mode: ask | edit | plan | auto | bypass
    var effort: String?              // reasoning effort: low | medium | high | ultra | "" unknown
    var mascotAnim: String?          // live mascot posture name (mirrors the Mac creature)
    var promptHistory: [PromptItem]? // recent human-typed prompts, newest first
    var editorSessionId: String?     // the live editor session — typing here types into it
    var editorCwd: String?
    var editorProject: String?

    struct PromptItem: Codable, Identifiable {
        var id: String
        var text: String
        var atEpoch: Double
        var project: String
        var at: Date { Date(timeIntervalSince1970: atEpoch) }
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
    struct Working: Codable, Identifiable {
        var id: String
        var project: String
        var cwd: String = ""
        var model: String?
        var prompt: String?
        var promptSummary: String?
        var promptAtEpoch: Double?
        var turnTokens: Int
        var runningAgents: Int = 0   // in-flight Task subagents this turn
        var queuedPrompts: Int = 0   // prompts typed while this turn runs, waiting their turn
        var queuedTexts: [String] = []   // the actual queued prompt texts, in order
        var isEditor: Bool = false   // editor session you're watching at the Mac → kept off the Island
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
    @Published var lastUpdated: Date?   // when /snapshot last succeeded — shown when offline
    @Published var refreshing = false   // a manual refresh is in flight (spins the button)

    @AppStorage("edgepanel.host") var host: String = ""   // set by pairing (QR/manual); empty → show pairing
    @AppStorage("edgepanel.token") var token: String = ""

    private var timer: Timer?
    private var lastPollOK: Date?   // gap detection → reset the finished-session baseline after a blackout

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

    /// Manual pull-to-refresh / button: fetch a fresh snapshot right now. Keeps whatever
    /// data we already have on failure (offline → most-recent data stays on screen).
    func refresh() async {
        if refreshing { return }
        refreshing = true
        await poll()
        refreshing = false
    }

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

    /// Send a message to Claude Code on the Mac; returns a jobId to poll for the
    /// streamed reply (a `claude -p [--resume]` turn).
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

    struct Project: Identifiable, Hashable { var name: String; var cwd: String; var id: String { cwd } }

    /// Projects on the Mac you can start a new autonomous task in.
    func fetchProjects() async -> [Project] {
        guard !host.isEmpty, !token.isEmpty, let url = URL(string: "http://\(host)/projects") else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue(token, forHTTPHeaderField: "X-EdgePanel-Token")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["projects"] as? [[String: String]] else { return [] }
        return arr.compactMap { p in p["cwd"].map { Project(name: p["name"] ?? ($0 as NSString).lastPathComponent, cwd: $0) } }
    }

    /// PANIC STOP: kill all running turns + Autonomous off + deny held/incoming.
    func panic() {
        guard !host.isEmpty, !token.isEmpty, let url = URL(string: "http://\(host)/panic") else { return }
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "X-EdgePanel-Token")
        Task { _ = try? await URLSession.shared.data(for: req); await poll() }
    }

    /// Toggle Autonomous (auto-approve) mode on the Mac.
    func setAutoApprove(_ on: Bool) {
        guard !host.isEmpty, !token.isEmpty, let url = URL(string: "http://\(host)/automode") else { return }
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "X-EdgePanel-Token")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["on": on])
        Task { _ = try? await URLSession.shared.data(for: req); await poll() }
    }

    /// Stop a running chat turn.
    func cancelChat(jobId: String) {
        guard !host.isEmpty, !token.isEmpty, let url = URL(string: "http://\(host)/chat/cancel") else { return }
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "X-EdgePanel-Token")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["jobId": jobId])
        Task { _ = try? await URLSession.shared.data(for: req) }
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
            snapshot = snap; connected = true; lastError = nil; lastUpdated = Date()
            // After a connectivity gap (>10s blind), sessions may have finished while we
            // couldn't see them — drop the stale baseline so we re-seed instead of firing a
            // burst of bogus "done" Island flips for sessions that ended minutes ago.
            if let prev = lastPollOK, Date().timeIntervalSince(prev) > 10 {
                ActivityManager.shared.resyncBaseline()
            }
            lastPollOK = Date()
            ActivityManager.shared.sync(working: snap.working)
            // Re-seed the Mac with the current Live Activity token on every poll, so it
            // always has a fresh token to push the "end" — even right after a Mac restart
            // (which used to leave the Island frozen on a stuck timer).
            ActivityManager.shared.resendActivityToken()
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
