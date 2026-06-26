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
}

@MainActor
final class EdgeClient: ObservableObject {
    @Published var snapshot: EdgeSnapshot?
    @Published var connected = false
    @Published var lastError: String?

    @AppStorage("edgepanel.host") var host: String = "192.168.87.250:8788"
    @AppStorage("edgepanel.token") var token: String = ""

    private var timer: Timer?

    func start() {
        Task { await poll() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { await self?.poll() }
        }
    }
    func stop() { timer?.invalidate(); timer = nil }

    /// Ask the Mac to resume this chat (opens it in Terminal on the Mac).
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
        } catch {
            connected = false
            lastError = (error as? URLError)?.code == .cannotConnectToHost
                ? "Can’t reach the Mac — is EdgePanel running?"
                : error.localizedDescription
        }
    }
}
