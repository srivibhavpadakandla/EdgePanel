import Foundation
import SwiftUI
import Security

private enum PairingKeychain {
    private static let service = "com.srivibhav.edgepanel.mobile"
    private static let account = "pairing-token"

    static func read() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    @discardableResult
    static func write(_ token: String) -> Bool {
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if token.isEmpty {
            let status = SecItemDelete(key as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let attrs: [String: Any] = [kSecValueData as String: Data(token.utf8)]
        if SecItemUpdate(key as CFDictionary, attrs as CFDictionary) == errSecSuccess { return true }
        var add = key
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

// Mirrors EdgeSnapshot served by the Mac (epoch-second dates).
struct EdgeSnapshot: Codable {
    // All non-optional fields are DEFAULTED so one missing key can't fail the whole decode and
    // blank the dashboard — a partial/older/error-state snapshot still degrades gracefully.
    var generatedAt: Double = 0
    var plan: PlanInfo?
    var spend = Spend(fiveHourUSD: 0)
    var working: [Working] = []
    var chats: [Chat] = []
    var calendar: [CalDay] = []
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

    // Every non-optional field below is DEFAULTED — Swift's synthesized decoder throws on a
    // missing key even inside a present (optional-typed) object/array, which would propagate up
    // and blank the WHOLE dashboard. Defaults make a partial/older/error snapshot degrade per-field.
    struct PromptItem: Codable, Identifiable {
        var id = UUID().uuidString
        var text = ""
        var atEpoch: Double = 0
        var project = ""
        var at: Date { Date(timeIntervalSince1970: atEpoch) }
    }

    struct PlanInfo: Codable {
        var fiveHourPct: Double = 0
        var weekPct: Double = 0
        var fiveHourResetEpoch: Double?
        var weekResetEpoch: Double?
        var burnPerHour: Double?
        var limitClockEpoch: Double?
    }
    struct Spend: Codable {
        var fiveHourUSD: Double = 0
    }
    struct Working: Codable, Identifiable {
        var id = UUID().uuidString
        var project = ""
        var cwd: String = ""
        var model: String?
        var prompt: String?
        var promptSummary: String?
        var promptAtEpoch: Double?
        var turnTokens: Int = 0
        var runningAgents: Int = 0   // in-flight Task subagents this turn
        var queuedPrompts: Int = 0   // prompts typed while this turn runs, waiting their turn
        var queuedTexts: [String] = []   // the actual queued prompt texts, in order
        var modeKey: String = "ask"      // this chat's permission mode
        var effortKey: String = ""       // this chat's reasoning effort
        var isEditor: Bool = false   // editor session you're watching at the Mac → kept off the Island
        var activity: String? = nil  // what it's doing right now, e.g. "Editing Chat.swift"
        var promptAt: Date? { promptAtEpoch.map { Date(timeIntervalSince1970: $0) } }
        /// The prompt to show: the Mac's summary if present, else the raw prompt.
        var display: String { (promptSummary?.isEmpty == false ? promptSummary : prompt) ?? "working…" }
    }
    struct Chat: Codable, Identifiable {
        var id = UUID().uuidString
        var name = ""
        var project = ""
        var cwd: String?
        var lastActiveEpoch: Double = 0
        var lastActive: Date { Date(timeIntervalSince1970: lastActiveEpoch) }
    }
    struct CalDay: Codable, Identifiable {
        var day = 0; var tokens = 0
        var id: Int { day }
    }
    struct Pending: Codable, Identifiable {
        var id = UUID().uuidString
        var tool = ""
        var summary = ""
        var reason = ""
        var risk = "read"          // "read" | "write" | "danger"
        var project: String?
        var preview: [String] = []
        var allowRule = ""
    }
    struct Question: Codable, Identifiable {
        var id = UUID().uuidString
        var project: String?
        var items: [Item] = []
        struct Item: Codable, Identifiable {
            var question = ""
            var header = ""
            var multiSelect = false
            var options: [Opt] = []
            var id: String { question }
            struct Opt: Codable { var label = ""; var description: String? }
        }
    }
}

// MARK: - Lenient decoding
// Swift's synthesized Decodable IGNORES property defaults and throws `keyNotFound` on ANY missing
// non-optional key — so the slightest Mac↔phone schema skew, or a partial/error snapshot, would
// fail the whole decode and blank the dashboard ("Connecting…" forever though the Mac is reachable).
// These decoders fall back to each field's default instead, and DROP (not reject) a malformed array
// element. Defined in extensions so the synthesized memberwise inits are preserved.

private struct EPLossy<T: Decodable>: Decodable { let v: T?; init(from d: Decoder) throws { v = try? T(from: d) } }
private extension KeyedDecodingContainer {
    func g<T: Decodable>(_ k: Key, _ def: T) -> T { (try? decode(T.self, forKey: k)) ?? def }   // missing/null/mismatch → default
    func g<T: Decodable>(_ k: Key) -> T? { try? decode(T.self, forKey: k) }                       // optional field → nil
    func arr<T: Decodable>(_ k: Key) -> [T] { ((try? decode([EPLossy<T>].self, forKey: k)) ?? []).compactMap(\.v) }
    func arrOpt<T: Decodable>(_ k: Key) -> [T]? { contains(k) ? ((try? decode([EPLossy<T>].self, forKey: k)) ?? []).compactMap(\.v) : nil }
}

extension EdgeSnapshot {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self); self.init()
        generatedAt = c.g(.generatedAt, 0); plan = c.g(.plan); spend = c.g(.spend, Spend(fiveHourUSD: 0))
        working = c.arr(.working); chats = c.arr(.chats); calendar = c.arr(.calendar)
        pending = c.g(.pending); question = c.g(.question); autoApprove = c.g(.autoApprove)
        mode = c.g(.mode); effort = c.g(.effort); mascotAnim = c.g(.mascotAnim); promptHistory = c.arrOpt(.promptHistory)
        editorSessionId = c.g(.editorSessionId); editorCwd = c.g(.editorCwd); editorProject = c.g(.editorProject)
    }
}
extension EdgeSnapshot.PromptItem {
    init(from d: Decoder) throws { let c = try d.container(keyedBy: CodingKeys.self); self.init()
        id = c.g(.id, id); text = c.g(.text, ""); atEpoch = c.g(.atEpoch, 0); project = c.g(.project, "") }
}
extension EdgeSnapshot.PlanInfo {
    init(from d: Decoder) throws { let c = try d.container(keyedBy: CodingKeys.self); self.init()
        fiveHourPct = c.g(.fiveHourPct, 0); weekPct = c.g(.weekPct, 0)
        fiveHourResetEpoch = c.g(.fiveHourResetEpoch); weekResetEpoch = c.g(.weekResetEpoch)
        burnPerHour = c.g(.burnPerHour); limitClockEpoch = c.g(.limitClockEpoch) }
}
extension EdgeSnapshot.Spend {
    init(from d: Decoder) throws { let c = try d.container(keyedBy: CodingKeys.self); self.init(); fiveHourUSD = c.g(.fiveHourUSD, 0) }
}
extension EdgeSnapshot.Working {
    init(from d: Decoder) throws { let c = try d.container(keyedBy: CodingKeys.self); self.init()
        id = c.g(.id, id); project = c.g(.project, ""); cwd = c.g(.cwd, "")
        model = c.g(.model); prompt = c.g(.prompt); promptSummary = c.g(.promptSummary); promptAtEpoch = c.g(.promptAtEpoch)
        turnTokens = c.g(.turnTokens, 0); runningAgents = c.g(.runningAgents, 0); queuedPrompts = c.g(.queuedPrompts, 0)
        queuedTexts = c.arr(.queuedTexts); modeKey = c.g(.modeKey, "ask"); effortKey = c.g(.effortKey, "")
        isEditor = c.g(.isEditor, false); activity = c.g(.activity) }
}
extension EdgeSnapshot.Chat {
    init(from d: Decoder) throws { let c = try d.container(keyedBy: CodingKeys.self); self.init()
        id = c.g(.id, id); name = c.g(.name, ""); project = c.g(.project, ""); cwd = c.g(.cwd); lastActiveEpoch = c.g(.lastActiveEpoch, 0) }
}
extension EdgeSnapshot.CalDay {
    init(from d: Decoder) throws { let c = try d.container(keyedBy: CodingKeys.self); self.init(); day = c.g(.day, 0); tokens = c.g(.tokens, 0) }
}
extension EdgeSnapshot.Pending {
    init(from d: Decoder) throws { let c = try d.container(keyedBy: CodingKeys.self); self.init()
        id = c.g(.id, id); tool = c.g(.tool, ""); summary = c.g(.summary, ""); reason = c.g(.reason, "")
        risk = c.g(.risk, "read"); project = c.g(.project); preview = c.arr(.preview); allowRule = c.g(.allowRule, "") }
}
extension EdgeSnapshot.Question {
    init(from d: Decoder) throws { let c = try d.container(keyedBy: CodingKeys.self); self.init()
        id = c.g(.id, id); project = c.g(.project); items = c.arr(.items) }
}
extension EdgeSnapshot.Question.Item {
    init(from d: Decoder) throws { let c = try d.container(keyedBy: CodingKeys.self); self.init()
        question = c.g(.question, ""); header = c.g(.header, ""); multiSelect = c.g(.multiSelect, false); options = c.arr(.options) }
}
extension EdgeSnapshot.Question.Item.Opt {
    init(from d: Decoder) throws { let c = try d.container(keyedBy: CodingKeys.self); self.init(); label = c.g(.label, ""); description = c.g(.description) }
}

@MainActor
final class EdgeClient: ObservableObject {
    static let shared = EdgeClient()
    @Published var snapshot: EdgeSnapshot?
    @Published var connected = false
    @Published var lastError: String?
    @Published var lastUpdated: Date?   // when /snapshot last succeeded — shown when offline
    @Published var refreshing = false   // a manual refresh is in flight (spins the button)

    @AppStorage("edgepanel.host") var host: String = ""   // full HTTPS base URL
    @Published var token: String {
        didSet {
            PairingKeychain.write(token)
            // Mirror host+token into the App Group so the interactive Live Activity intent
            // (which runs outside this process) can POST /permission/decide.
            UsageShared.writeConn(host: host, token: token)
        }
    }

    init() {
        let secure = PairingKeychain.read()
        let legacy = UserDefaults.standard.string(forKey: "edgepanel.token") ?? ""
        token = secure.isEmpty ? legacy : secure
        if !legacy.isEmpty, (!secure.isEmpty || PairingKeychain.write(legacy)) {
            UserDefaults.standard.removeObject(forKey: "edgepanel.token")
        }
    }

    /// Build one API endpoint. Plain HTTP is accepted only on loopback or Tailscale's dedicated
    /// address ranges, where the connection is already carried inside the tailnet's WireGuard
    /// tunnel. Public/LAN HTTP remains rejected. A scheme-less host is upgraded to HTTPS.
    private func endpoint(_ path: String) -> URL? {
        let raw = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let normalized = raw.contains("://") ? raw : "https://\(raw)"
        guard let base = URL(string: normalized), let scheme = base.scheme?.lowercased() else { return nil }
        let loopback = base.host == "127.0.0.1" || base.host == "localhost" || base.host == "::1"
        let tailnet: Bool = {
            guard let host = base.host?.lowercased() else { return false }
            // Require an EXACT dotted-quad: 4 labels, ALL numeric octets. compactMap alone silently
            // dropped non-numeric labels, so a hostname like "100.64.0.1.attacker.example" mis-parsed
            // to a 4-octet "tailnet" IP and would have permitted cleartext HTTP to an attacker host.
            let parts = host.split(separator: ".")
            if parts.count == 4 {
                let octets = parts.compactMap { UInt8($0) }
                if octets.count == 4, octets[0] == 100, (64...127).contains(octets[1]) { return true }
            }
            return host.hasPrefix("fd7a:115c:a1e0:")
        }()
        guard scheme == "https" || (scheme == "http" && (loopback || tailnet)) else { return nil }
        return base.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

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
              let url = endpoint("permission/decide") else { return }
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "X-EdgePanel-Token")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["id": id, "decision": decision])
        Task { _ = try? await URLSession.shared.data(for: req); await poll() }
    }

    /// Forward an APNs token to the Mac (Tier 2).
    func postPushToken(kind: String, sessionId: String?, pushToken: String) {
        guard !host.isEmpty, !token.isEmpty, let url = endpoint("pushtoken") else { return }
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "X-EdgePanel-Token")
        var body: [String: Any] = ["kind": kind, "token": pushToken]
        if let sessionId { body["sessionId"] = sessionId }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        Task { _ = try? await URLSession.shared.data(for: req) }
    }

    struct ChatJob: Codable { var status: String; var result: String?; var sessionId: String?; var error: String?; var delivered: Bool? }

    /// Answer a held AskUserQuestion. answers = {questionText: "label" or "a,b"}.
    func answerQuestion(id: String, answers: [String: String]) {
        guard !host.isEmpty, !token.isEmpty, let url = endpoint("question/decide") else { return }
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "X-EdgePanel-Token")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["id": id, "answers": answers])
        Task { _ = try? await URLSession.shared.data(for: req); await poll() }
    }

    /// Send a message to Claude Code on the Mac; returns a jobId to poll for the
    /// streamed reply (a `claude -p [--resume]` turn).
    func sendChat(cwd: String, sessionId: String?, message: String) async -> String? {
        guard !host.isEmpty, !token.isEmpty, let url = endpoint("chat") else { return nil }
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
        guard !host.isEmpty, !token.isEmpty, let url = endpoint("projects") else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue(token, forHTTPHeaderField: "X-EdgePanel-Token")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["projects"] as? [[String: String]] else { return [] }
        return arr.compactMap { p in p["cwd"].map { Project(name: p["name"] ?? ($0 as NSString).lastPathComponent, cwd: $0) } }
    }

    /// PANIC STOP: kill all running turns + Autonomous off + deny held/incoming.
    func panic() {
        guard !host.isEmpty, !token.isEmpty, let url = endpoint("panic") else { return }
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "X-EdgePanel-Token")
        Task { _ = try? await URLSession.shared.data(for: req); await poll() }
    }

    /// Set this chat's reasoning EFFORT on the Mac (low|medium|high|xhigh|max), then poll
    /// immediately so the UI reflects it on the next tick. Fire-and-forget, same authed POST
    /// pattern as decidePermission. An empty cwd lets the Mac fall back to ~/.claude.
    func setEffort(cwd: String, effort: String) {
        guard !host.isEmpty, !token.isEmpty, let url = endpoint("effort") else { return }
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "X-EdgePanel-Token")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["cwd": cwd, "effort": effort])
        Task { _ = try? await URLSession.shared.data(for: req); await poll() }
    }

    /// Toggle Autonomous (auto-approve) mode on the Mac.
    func setAutoApprove(_ on: Bool) {
        guard !host.isEmpty, !token.isEmpty, let url = endpoint("automode") else { return }
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "X-EdgePanel-Token")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["on": on])
        Task { _ = try? await URLSession.shared.data(for: req); await poll() }
    }

    /// Stop a running chat turn.
    func cancelChat(jobId: String) {
        guard !host.isEmpty, !token.isEmpty, let url = endpoint("chat/cancel") else { return }
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "X-EdgePanel-Token")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["jobId": jobId])
        Task { _ = try? await URLSession.shared.data(for: req) }
    }

    /// Load a session's real conversation history from the Mac transcript.
    func fetchHistory(sessionId: String, cwd: String) async -> [(role: String, text: String)] {
        guard !host.isEmpty, !token.isEmpty, let url = endpoint("chat/history") else { return [] }
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
        guard !host.isEmpty, !token.isEmpty, let url = endpoint("chat/poll") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "X-EdgePanel-Token")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["jobId": jobId])
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return try? JSONDecoder().decode(ChatJob.self, from: data)
    }

    /// Ask the Mac to resume this chat (opens it in VS Code on the Mac).
    func openChat(_ chat: EdgeSnapshot.Chat) {
        guard !token.isEmpty, let url = endpoint("open") else { return }
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "X-EdgePanel-Token")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["id": chat.id, "cwd": chat.cwd ?? ""])
        Task { _ = try? await URLSession.shared.data(for: req) }
    }

    private var polling = false
    func poll() async {
        // Single-flight: the 1.5s timer fires unconditionally, but a poll can outlast a tick on a
        // slow link. Without this, two+ polls overlap and the LAST to resume wins — which can be the
        // OLDER response, flickering stale data + feeding a spurious Island "done". Drop re-entrant polls.
        if polling { return }
        polling = true
        defer { polling = false }
        guard !host.isEmpty, !token.isEmpty,
              let url = endpoint("snapshot") else {
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
            // Keep the App Group's conn (host+token) fresh so the interactive permission intent
            // can reach the Mac even after the host was edited (host has no didSet of its own).
            UsageShared.writeConn(host: host, token: token)
            // Mirror the usage % to the App Group so the Lock Screen widget shows it live.
            if let p = snap.plan {
                UsageShared.write(fiveHourPct: p.fiveHourPct, weekPct: p.weekPct,
                                  fiveHourResetEpoch: p.fiveHourResetEpoch)
            }
            // After a connectivity gap (>10s blind), sessions may have finished while we
            // couldn't see them — drop the stale baseline so we re-seed instead of firing a
            // burst of bogus "done" Island flips for sessions that ended minutes ago.
            if let prev = lastPollOK, Date().timeIntervalSince(prev) > 10 {
                ActivityManager.shared.resyncBaseline()
            }
            lastPollOK = Date()
            ActivityManager.shared.sync(working: snap.working, pending: snap.pending)
            // Re-seed the Mac with the current Live Activity token on every poll, so it
            // always has a fresh token to push the "end" — even right after a Mac restart
            // (which used to leave the Island frozen on a stuck timer).
            ActivityManager.shared.resendActivityToken()
            // Usage limit alerts are now owned by the always-on Mac (pushUsageAlert) so they
            // reach the phone even when the app is CLOSED — not just when you open it. (The old
            // poll-driven checkUsage only ran while the app was open.)
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
