// UsageData — the local Claude Code usage model, ported from ClaudeUsage.
// Reads ~/.claude/projects/**/*.jsonl for token/cost aggregation and the live
// plan % from Claude Code's OAuth usage endpoint (keychain token). The claude.ai
// cookie sign-in path is intentionally omitted here (Claude Code OAuth only).

import SwiftUI
import AppKit
import Foundation

// MARK: - Fonts

extension Font {
    /// macOS "New York" serif — closest system match to Claude's serif type.
    static func claude(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

// MARK: - Color helpers

extension Color {
    init(_ hex: UInt, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: alpha)
    }
}

struct Theme {
    let bg, card, accentSoft, text, subtext, accent, accent2, border, track, green, amber, red: Color
    let heat: [Color]
    static func resolve(_ s: ColorScheme) -> Theme {
        if s == .dark {
            return Theme(bg: Color(0x16150F), card: Color(0x201F1C), accentSoft: Color(0x342A22),
                         text: Color(0xF3EFE6), subtext: Color(0x9C968C), accent: Color(0xE08A6A),
                         accent2: Color(0xD9795E), border: Color(0x33322D), track: Color(0x2C2B27),
                         green: Color(0x93A063), amber: Color(0xD9A24E), red: Color(0xD05A4E),
                         heat: [Color(0x2C2B27), Color(0xB6CE8A), Color(0x88AC5A), Color(0x57813A), Color(0x2E5220)])
        }
        return Theme(bg: Color(0xF0EEE6), card: Color(0xFAF9F5), accentSoft: Color(0xF3E6DF),
                     text: Color(0x1F1E1D), subtext: Color(0x736F68), accent: Color(0xC96442),
                     accent2: Color(0xD97757), border: Color(0xE6E1D7), track: Color(0xE8E3D9),
                     green: Color(0x7E8A47), amber: Color(0xB07A2E), red: Color(0xC0453B),
                     heat: [Color(0xE7E4D8), Color(0xC8DCA0), Color(0x9DBE6A), Color(0x6E9442), Color(0x456A26)])
    }
}

/// Severity color: green < 50% < amber < 80% < red.
func sevColor(_ frac: Double, _ t: Theme) -> Color {
    frac >= 0.8 ? t.red : frac >= 0.5 ? t.amber : t.green
}

// MARK: - Formatting

func fmtDur(_ s: TimeInterval) -> String {
    let m = max(Int(ceil(s / 60)), 0)   // round up so 30s reads "1m", not "0m"
    return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
}
func fmtCost(_ c: Double) -> String {
    if c >= 1000 { return String(format: "$%.0f", c) }
    if c >= 100 { return String(format: "$%.1f", c) }
    return String(format: "$%.2f", c)
}
func fmtTokens(_ t: Int) -> String {
    if t >= 1_000_000 { return String(format: "%.2fM", Double(t) / 1_000_000) }
    if t >= 1_000 { return String(format: "%.1fK", Double(t) / 1_000) }
    return "\(t)"
}
func fmtPct(_ f: Double) -> String {
    "\(Int((min(max(f, 0), 1) * 100).rounded()))%"
}
/// Short wall-clock time, e.g. "7:42 PM".
func fmtClock(_ d: Date) -> String {
    let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
    return f.string(from: d)
}
/// Relative "time since", compact: now / 12s / 4m / 2h.
func fmtAgo(_ d: Date) -> String {
    let s = max(Date().timeIntervalSince(d), 0)
    if s < 8 { return "now" }
    if s < 60 { return "\(Int(s))s" }
    if s < 3600 { return "\(Int(s) / 60)m" }
    return "\(Int(s) / 3600)h"
}
/// Elapsed clock for a running turn: 45s / 1m 20s / 1h 2m.
func fmtElapsed(_ s: TimeInterval) -> String {
    let t = max(Int(s), 0)
    if t < 60 { return "\(t)s" }
    if t < 3600 { return "\(t / 60)m \(t % 60)s" }
    return "\(t / 3600)h \((t % 3600) / 60)m"
}

// MARK: - Pricing (USD per million tokens)

struct Pricing {
    let input, output, cacheWrite, cacheRead: Double
    static func forModel(_ model: String) -> Pricing {
        let m = model.lowercased()
        if m.contains("opus") {
            return Pricing(input: 15, output: 75, cacheWrite: 18.75, cacheRead: 1.5)
        }
        if m.contains("haiku") {
            if m.contains("haiku-4") || m.contains("4-5") || m.contains("4.5") {
                return Pricing(input: 1, output: 5, cacheWrite: 1.25, cacheRead: 0.1)
            }
            return Pricing(input: 0.8, output: 4, cacheWrite: 1.0, cacheRead: 0.08)
        }
        return Pricing(input: 3, output: 15, cacheWrite: 3.75, cacheRead: 0.3) // sonnet / default
    }
}

func prettyModel(_ m: String) -> String {
    let l = m.lowercased()
    let fam = l.contains("opus") ? "Opus"
            : l.contains("sonnet") ? "Sonnet"
            : l.contains("haiku") ? "Haiku" : "Claude"
    if let r = m.range(of: #"\d+([.-]\d+)?"#, options: .regularExpression) {
        let v = m[r].replacingOccurrences(of: "-", with: ".")
        return "\(fam) \(v)"
    }
    return fam
}

/// Total context window for a model id (input-side token ceiling). Default 200K;
/// 1M for the long-context beta variants (id contains "1m"/"[1m]").
func contextLimit(for model: String) -> Int {
    let m = model.lowercased()
    if m.contains("1m") || m.contains("[1m]") { return 1_000_000 }
    return 200_000
}

// MARK: - Data model

struct Rec {
    let date: Date
    let model: String
    let inT, outT, cacheW, cacheR: Int
    let cost: Double
    var tokens: Int { inT + outT + cacheW + cacheR }
    var billable: Int { inT + outT + cacheW }
}

struct Bucket {
    var cost = 0.0, inT = 0, outT = 0, cacheW = 0, cacheR = 0, tokens = 0
    var billable: Int { inT + outT + cacheW }
    mutating func add(_ r: Rec) {
        cost += r.cost; inT += r.inT; outT += r.outT
        cacheW += r.cacheW; cacheR += r.cacheR; tokens += r.tokens
    }
}

struct BlockInfo { var start: Date; var resetAt: Date; var cost: Double; var tokens: Int; var billable: Int }

struct Summary {
    var today = Bucket(), week = Bucket(), month = Bucket(), all = Bucket()
    var last7: [(day: Date, cost: Double, tokens: Int)] = []
    var models: [(name: String, cost: Double, tokens: Int)] = []        // all-time
    var windowModels: [(name: String, cost: Double, tokens: Int)] = []  // current 5-hour window
    var block: BlockInfo?
    var recentEvents: [(date: Date, cost: Double)] = []
    var monthDayTokens: [Int: Int] = [:]
    var weekTokens = 0
    var peakDayTokens = 0, peakWeekTokens = 0, peakMonthTokens = 0, peakWindowTokens = 0
    var limitWindow = 0, limitDay = 0, limitWeek = 0, limitMonth = 0
    var generatedAt = Date()
    var recordCount = 0
    var fileCount = 0
}

// MARK: - Loader

enum UsageLoader {
    static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    static func parseDate(_ s: String) -> Date? { isoFrac.date(from: s) ?? iso.date(from: s) }

    static func projectsBase() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    static func computeSummary() -> Summary {
        let base = projectsBase()
        var recs: [Rec] = []
        var seen = Set<String>()
        var fileCount = 0
        if let en = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) {
            while let u = en.nextObject() as? URL {
                guard u.pathExtension == "jsonl" else { continue }
                fileCount += 1
                parseFile(u, into: &recs, seen: &seen)
            }
        }
        var s = aggregate(recs, fileCount: fileCount)
        applyLimits(&s)
        return s
    }

    struct Limits: Codable { var window, day, week, month: Int }

    static func limitsFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("ClaudeUsage/limits.json")
    }

    static func applyLimits(_ s: inout Summary) {
        let url = limitsFileURL()
        if let data = try? Data(contentsOf: url),
           let lim = try? JSONDecoder().decode(Limits.self, from: data),
           lim.window > 0, lim.day > 0, lim.week > 0, lim.month > 0 {
            s.limitWindow = lim.window; s.limitDay = lim.day
            s.limitWeek = lim.week; s.limitMonth = lim.month
            return
        }
        func seed(_ peak: Int, _ floor: Int) -> Int { max(Int(Double(peak) * 1.25), floor) }
        let lim = Limits(window: seed(s.peakWindowTokens, 250_000),
                         day: seed(s.peakDayTokens, 1_000_000),
                         week: seed(s.peakWeekTokens, 5_000_000),
                         month: seed(s.peakMonthTokens, 15_000_000))
        s.limitWindow = lim.window; s.limitDay = lim.day
        s.limitWeek = lim.week; s.limitMonth = lim.month
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(lim) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }

    static func parseFile(_ url: URL, into recs: inout [Rec], seen: inout Set<String>) {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return }
        for sub in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(sub.utf8))) as? [String: Any],
                  let msg = obj["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any],
                  let ts = obj["timestamp"] as? String,
                  let date = parseDate(ts) else { continue }

            let inT = usage["input_tokens"] as? Int ?? 0
            let outT = usage["output_tokens"] as? Int ?? 0
            let cacheW = usage["cache_creation_input_tokens"] as? Int ?? 0
            let cacheR = usage["cache_read_input_tokens"] as? Int ?? 0
            if inT == 0 && outT == 0 && cacheW == 0 && cacheR == 0 { continue }

            // Dedup by message/request id; fall back to a synthetic key (timestamp +
            // token shape) so records lacking BOTH ids still can't be double-counted.
            let mid = msg["id"] as? String ?? ""
            let rid = (obj["requestId"] as? String) ?? (obj["request_id"] as? String) ?? ""
            let key = (mid.isEmpty && rid.isEmpty) ? "\(ts)|\(inT)|\(outT)|\(cacheW)|\(cacheR)" : mid + "|" + rid
            if seen.contains(key) { continue }
            seen.insert(key)

            let model = msg["model"] as? String ?? "unknown"
            let p = Pricing.forModel(model)
            let cost = (Double(inT) * p.input + Double(outT) * p.output
                        + Double(cacheW) * p.cacheWrite + Double(cacheR) * p.cacheRead) / 1_000_000
            recs.append(Rec(date: date, model: model, inT: inT, outT: outT, cacheW: cacheW, cacheR: cacheR, cost: cost))
        }
    }

    static func aggregate(_ recs: [Rec], fileCount: Int) -> Summary {
        var s = Summary()
        s.fileCount = fileCount
        s.recordCount = recs.count
        guard !recs.isEmpty else { return s }

        let cal = Calendar.current
        let now = Date()
        let startToday = cal.startOfDay(for: now)
        let weekAgo = cal.date(byAdding: .day, value: -6, to: startToday) ?? startToday
        let startMonth = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? startToday
        let sixHoursAgo = now.addingTimeInterval(-21600)

        var dayBuckets: [Date: Bucket] = [:]
        var modelBuckets: [String: Bucket] = [:]
        var weekTok: [Int: Int] = [:]
        var monthTok: [Int: Int] = [:]
        var weekBill: [Int: Int] = [:]
        var monthBill: [Int: Int] = [:]
        func weekKey(_ d: Date) -> Int {
            let c = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: d)
            return (c.yearForWeekOfYear ?? 0) * 100 + (c.weekOfYear ?? 0)
        }
        func monthKey(_ d: Date) -> Int {
            let c = cal.dateComponents([.year, .month], from: d)
            return (c.year ?? 0) * 100 + (c.month ?? 0)
        }

        for r in recs {
            s.all.add(r)
            if r.date >= startToday { s.today.add(r) }
            if r.date >= weekAgo { s.week.add(r) }
            if r.date >= startMonth { s.month.add(r) }
            let day = cal.startOfDay(for: r.date)
            dayBuckets[day, default: Bucket()].add(r)
            modelBuckets[prettyModel(r.model), default: Bucket()].add(r)
            weekTok[weekKey(r.date), default: 0] += r.tokens
            monthTok[monthKey(r.date), default: 0] += r.tokens
            weekBill[weekKey(r.date), default: 0] += r.billable
            monthBill[monthKey(r.date), default: 0] += r.billable
            if r.date >= sixHoursAgo { s.recentEvents.append((r.date, r.cost)) }
        }
        s.weekTokens = weekTok[weekKey(now)] ?? 0
        s.peakDayTokens = dayBuckets.values.map { $0.billable }.max() ?? 0
        s.peakWeekTokens = weekBill.values.max() ?? 0
        s.peakMonthTokens = monthBill.values.max() ?? 0
        var monthDayTokens: [Int: Int] = [:]
        for (d, b) in dayBuckets where d >= startMonth {
            monthDayTokens[cal.component(.day, from: d)] = b.billable
        }
        s.monthDayTokens = monthDayTokens

        s.last7 = (0..<7).map { i -> (day: Date, cost: Double, tokens: Int) in
            let day = cal.date(byAdding: .day, value: i - 6, to: startToday) ?? startToday
            let b = dayBuckets[day] ?? Bucket()
            return (day, b.cost, b.tokens)
        }

        s.models = modelBuckets
            .map { (name: $0.key, cost: $0.value.cost, tokens: $0.value.tokens) }
            .sorted { $0.cost > $1.cost }

        let sorted = recs.sorted { $0.date < $1.date }
        var blocks: [(start: Date, end: Date, cost: Double, tok: Int, bill: Int, last: Date)] = []
        for r in sorted {
            if var b = blocks.last, r.date < b.end, r.date.timeIntervalSince(b.last) < 18000 {
                b.cost += r.cost; b.tok += r.tokens; b.bill += r.billable; b.last = r.date
                blocks[blocks.count - 1] = b
            } else {
                let start = r.date
                blocks.append((start, start.addingTimeInterval(18000), r.cost, r.tokens, r.billable, r.date))
            }
        }
        if let b = blocks.last, now < b.end {
            s.block = BlockInfo(start: b.start, resetAt: b.end, cost: b.cost, tokens: b.tok, billable: b.bill)
            // Per-model split for the live window → sits under "5H SPEND".
            var windowModelBuckets: [String: Bucket] = [:]
            for r in recs where r.date >= b.start && r.date <= b.end {
                windowModelBuckets[prettyModel(r.model), default: Bucket()].add(r)
            }
            s.windowModels = windowModelBuckets
                .map { (name: $0.key, cost: $0.value.cost, tokens: $0.value.tokens) }
                .sorted { $0.cost > $1.cost }
        }
        s.peakWindowTokens = blocks.map { $0.bill }.max() ?? 0
        return s
    }

    /// Context-window occupancy of the most-recently-active session: the input
    /// side of the LAST assistant message in the most-recently-modified transcript
    /// (input + cache_read + cache_creation ≈ the full prompt currently in context).
    static func activeContext() -> (tokens: Int, model: String, pct: Double, session: String)? {
        let base = projectsBase()
        guard let en = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var newest: (url: URL, date: Date)?
        while let u = en.nextObject() as? URL {
            guard u.pathExtension == "jsonl" else { continue }
            let mod = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if newest == nil || mod > newest!.date { newest = (u, mod) }
        }
        guard let pick = newest,
              let data = try? Data(contentsOf: pick.url),
              let text = String(data: data, encoding: .utf8) else { return nil }

        var lastInput = 0, model = "claude"
        for sub in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(sub.utf8))) as? [String: Any],
                  (obj["type"] as? String) == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any] else { continue }
            let inT = usage["input_tokens"] as? Int ?? 0
            let cacheR = usage["cache_read_input_tokens"] as? Int ?? 0
            let cacheW = usage["cache_creation_input_tokens"] as? Int ?? 0
            let total = inT + cacheR + cacheW
            if total > 0 { lastInput = total; model = msg["model"] as? String ?? model }
        }
        guard lastInput > 0 else { return nil }
        // The JSONL `model` id doesn't carry the "[1m]" beta tag, so a 1M-context
        // session looks like a 200K one. But a 200K model would have compacted
        // before 200K — so anything above ~190K is necessarily long-context.
        let baseLimit = contextLimit(for: model)
        let limit = (baseLimit == 200_000 && lastInput > 190_000) ? 1_000_000 : baseLimit
        let pct = min(max(Double(lastInput) / Double(limit), 0), 1)
        let session = pick.url.deletingPathExtension().lastPathComponent
        return (lastInput, model, pct, session)
    }
}

/// A recent Claude Code chat (one session/transcript), for the "recent chats" list.
struct RecentChat: Identifiable {
    let id: String            // session uuid
    let project: String       // cwd basename
    let cwd: String?
    let title: String?        // Claude Code's own ai-title (already human-readable)
    let firstPrompt: String?  // fallback name source
    let lastActive: Date
    /// A clean name: the ai-title, else a short form of the first prompt (never raw JSON).
    func name(summaries: [String: String]) -> String {
        if let t = title, !t.isEmpty { return t }
        guard let p = firstPrompt, !p.isEmpty, !p.hasPrefix("["), !p.hasPrefix("{") else { return "Chat" }
        if p.count <= 60 { return p }
        return summaries[id] ?? (String(p.prefix(56)) + "…")
    }
    /// True when we need the claude CLI to shorten a long, title-less prompt.
    var needsSummary: Bool { (title?.isEmpty ?? true) && (firstPrompt?.count ?? 0) > 60 }
}

/// One tool call, for the activity feed. Parsed from a transcript `tool_use`.
struct ToolEvent: Identifiable, Equatable {
    let id = UUID()
    let tool: String
    let summary: String
    let filePath: String?
    let project: String?
    let date: Date
}

// MARK: - Active sessions ("which chat am I waiting on right now")

/// A Claude Code session currently generating a response — i.e. a prompt was
/// submitted and the transcript is still being written. Carries the turn's
/// elapsed clock (since the prompt) and tokens used so far.
struct LiveSession: Identifiable {
    let id: String            // session uuid (transcript filename)
    let project: String       // cwd basename
    var cwd: String = ""      // full working dir (to resume the session from the phone)
    let model: String?
    let promptAt: Date?       // when the current turn's user prompt was submitted
    let promptText: String?   // the user's prompt that started this turn
    let turnTokens: Int       // billable tokens used so far this turn
    let lastWrite: Date       // transcript mtime
    let turnComplete: Bool    // the latest assistant turn ended (stop_reason end_turn)
    /// Still generating: you prompted and the turn hasn't finished (no end_turn
    /// yet — covers long tool calls), and the transcript is recent enough not to
    /// be an abandoned/crashed turn.
    func isWorking(asOf now: Date = Date()) -> Bool { !turnComplete && now.timeIntervalSince(lastWrite) < 240 }
    func elapsed(asOf now: Date = Date()) -> TimeInterval { promptAt.map { now.timeIntervalSince($0) } ?? 0 }
}

extension UsageLoader {
    /// Sessions whose transcript was touched within `within` seconds, newest
    /// first, each annotated with the in-flight turn's prompt time + token count.
    /// The view filters to the ones still generating (`isWorking`).
    static func activeSessions(within: TimeInterval = 300, limit: Int = 8) -> [LiveSession] {
        let base = projectsBase()
        guard let en = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let now = Date()
        var recent: [(url: URL, date: Date)] = []
        while let u = en.nextObject() as? URL {
            guard u.pathExtension == "jsonl", !isTransientProject(u) else { continue }
            let mod = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(mod) <= within { recent.append((u, mod)) }
        }
        recent.sort { $0.date > $1.date }

        var out: [LiveSession] = []
        for (u, mod) in recent.prefix(limit) {
            // The current turn lives at the END of the transcript — read only the
            // tail so this stays cheap enough to refresh every couple of seconds
            // even when the active session's transcript is many MB.
            guard let text = tailString(u, maxBytes: 6_000_000) else { continue }
            let objs = text.split(separator: "\n", omittingEmptySubsequences: true)
                .compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }

            // The current turn = everything after your last *typed* prompt.
            // userPromptText() skips tool_result continuations and Claude Code's
            // injected context (system reminders, slash-command wrappers, caveats).
            var boundary = -1
            var promptText: String?
            for (i, o) in objs.enumerated() {
                if let t = userPromptText(o) { boundary = i; promptText = t }
            }
            var promptAt: Date?
            if boundary >= 0, let ts = objs[boundary]["timestamp"] as? String { promptAt = parseDate(ts) }

            // Tokens this turn: dedup assistant calls by request id (keep the final
            // non-streaming one), then sum the NON-cached tokens — fresh input +
            // output. Cache reads/writes are excluded: on the first call of a turn
            // cache_creation can be the entire (re-cached) context, which would
            // swamp the real number with hundreds of K of non-work tokens.
            var byReq: [String: (inT: Int, outT: Int)] = [:]
            var anon = 0
            if boundary >= 0 {
                for o in objs[(boundary + 1)...] {
                    guard (o["type"] as? String) == "assistant",
                          let m = o["message"] as? [String: Any],
                          let usage = m["usage"] as? [String: Any] else { continue }
                    let inT = intVal(usage["input_tokens"]), outT = intVal(usage["output_tokens"])
                    let rid = (o["requestId"] as? String) ?? (m["id"] as? String) ?? { anon += 1; return "a\(anon)" }()
                    if let e = byReq[rid], e.outT >= outT { continue }
                    byReq[rid] = (inT, outT)
                }
            }
            let turnTokens = byReq.values.reduce(0) { $0 + $1.inT + $1.outT }

            // The turn is finished when a completed assistant message (stop_reason
            // end_turn / stop_sequence / max_tokens) exists AFTER your last prompt.
            // Looking only at user/assistant messages ignores trailing metadata
            // records (ai-title, mode, last-prompt) that would otherwise make an
            // idle, already-answered session look like it's still working.
            var lastTerminalAssistant = -1
            for (i, o) in objs.enumerated() {
                guard (o["type"] as? String) == "assistant",
                      let m = o["message"] as? [String: Any],
                      let sr = m["stop_reason"] as? String else { continue }
                if sr == "end_turn" || sr == "stop_sequence" || sr == "max_tokens" { lastTerminalAssistant = i }
            }
            let turnComplete = boundary < 0 || lastTerminalAssistant > boundary

            var project = "session"
            var cwdFull = ""
            var model: String?
            for o in objs.reversed() {
                if cwdFull.isEmpty, let cwd = o["cwd"] as? String, !cwd.isEmpty {
                    cwdFull = cwd
                    project = (cwd as NSString).lastPathComponent
                }
                if model == nil, (o["type"] as? String) == "assistant",
                   let mm = (o["message"] as? [String: Any])?["model"] as? String { model = mm }
                if !cwdFull.isEmpty && model != nil { break }
            }

            // cwd for the phone = the session's CREATION dir (resumable + matches the
            // transcript dir for history), not the latest cwd. project label stays the
            // latest cwd basename (more meaningful for "where work is happening").
            let resumeCwd = Self.headCwd(u) ?? cwdFull
            out.append(LiveSession(id: u.deletingPathExtension().lastPathComponent, project: project,
                                   cwd: resumeCwd, model: model, promptAt: promptAt, promptText: promptText,
                                   turnTokens: turnTokens, lastWrite: mod, turnComplete: turnComplete))
        }
        return out
    }

    /// Recent tool calls of the most-recently-active session, parsed straight
    /// from the transcript's `tool_use` blocks — real activity, no hooks needed.
    static func recentActivity(limit: Int = 8) -> [ToolEvent] {
        let base = projectsBase()
        guard let en = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var newest: (url: URL, date: Date)?
        while let u = en.nextObject() as? URL {
            guard u.pathExtension == "jsonl", !isTransientProject(u) else { continue }
            let mod = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if newest == nil || mod > newest!.date { newest = (u, mod) }
        }
        guard let pick = newest,
              let data = try? Data(contentsOf: pick.url),
              let text = String(data: data, encoding: .utf8) else { return [] }

        var project = "session"
        var out: [ToolEvent] = []
        for sub in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(sub.utf8))) as? [String: Any] else { continue }
            if let cwd = obj["cwd"] as? String, !cwd.isEmpty { project = (cwd as NSString).lastPathComponent }
            guard (obj["type"] as? String) == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]] else { continue }
            let date = (obj["timestamp"] as? String).flatMap(parseDate) ?? Date()
            for block in content where (block["type"] as? String) == "tool_use" {
                let raw = block["name"] as? String ?? "tool"
                let name = raw.hasPrefix("mcp__") ? (raw.components(separatedBy: "__").last ?? raw) : raw
                let input = block["input"] as? [String: Any] ?? [:]
                let filePath = (input["file_path"] as? String) ?? (input["path"] as? String) ?? (input["notebook_path"] as? String)
                let label: String
                if let fp = filePath { label = (fp as NSString).lastPathComponent }
                else if let cmd = input["command"] as? String { label = cleanCommand(cmd) }
                else if let pat = input["pattern"] as? String { label = pat }
                else if let url = input["url"] as? String { label = url }
                else if let q = input["query"] as? String { label = q }
                else if let d = input["description"] as? String { label = d }
                else if name == "TodoWrite" { label = "updated the to-do list" }
                else { label = name }
                out.append(ToolEvent(tool: name, summary: clip(label, 40), filePath: filePath, project: project, date: date))
            }
        }
        return Array(out.suffix(limit).reversed())   // newest first
    }

    /// Strip leading env-var assignments and take the first line, so a Bash
    /// activity row reads as the actual command (not "SCR=… ; nap() …").
    private static func cleanCommand(_ cmd: String) -> String {
        let firstLine = cmd.split(separator: "\n").first.map(String.init) ?? cmd
        let toks = firstLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        var out: [String] = []
        var started = false
        for t in toks {
            if !started && t.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil { continue }
            started = true
            out.append(t)
        }
        let joined = out.joined(separator: " ")
        return joined.isEmpty ? firstLine : joined
    }
    private static func clip(_ s: String, _ n: Int) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return t.count <= n ? t : String(t.prefix(n - 1)) + "…"
    }

    /// True for transcripts that live under a temp dir — e.g. the throwaway
    /// `claude` calls EdgePanel itself makes to summarize prompts. These must
    /// never appear as "working chats" or in the activity feed.
    static func isTransientProject(_ fileURL: URL) -> Bool {
        let proj = fileURL.deletingLastPathComponent().lastPathComponent
        return proj.contains("var-folders") || proj.contains("private-tmp") || proj.contains("-tmp-")
    }

    /// A recent Claude Code chat (session), for the "recent chats" list.
    static func recentChats(within: TimeInterval = 86400, limit: Int = 6) -> [RecentChat] {
        let base = projectsBase()
        guard let en = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let now = Date()
        var recent: [(url: URL, date: Date)] = []
        while let u = en.nextObject() as? URL {
            guard u.pathExtension == "jsonl", !isTransientProject(u) else { continue }
            let mod = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(mod) <= within { recent.append((u, mod)) }
        }
        recent.sort { $0.date > $1.date }

        var out: [RecentChat] = []
        var seenNames = Set<String>()
        for (u, mod) in recent {
            if out.count >= limit { break }
            // ai-title + first prompt + cwd live near the start; read a prefix only.
            guard let fh = try? FileHandle(forReadingFrom: u) else { continue }
            let data = (try? fh.read(upToCount: 524_288)) ?? Data()
            try? fh.close()
            let text = String(decoding: data, as: UTF8.self)

            var title: String?, cwd: String?, firstPrompt: String?, isInteractive = false
            for sub in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let o = (try? JSONSerialization.jsonObject(with: Data(sub.utf8))) as? [String: Any] else { continue }
                // Only YOUR interactive chats: real Claude Code UI/CLI sessions carry an
                // `entrypoint` (e.g. "claude-vscode"); subagent/workflow/headless
                // sessions (the "Verify…"/"Audit…"/"qa-ok" ones) don't, so this drops them.
                if let e = o["entrypoint"] as? String, !e.isEmpty { isInteractive = true }
                if title == nil, (o["type"] as? String) == "ai-title" {
                    title = (o["aiTitle"] as? String) ?? (o["title"] as? String)
                }
                if cwd == nil, let c = o["cwd"] as? String, !c.isEmpty { cwd = c }
                // Skip raw-JSON first messages (tool blobs) as a name source.
                if firstPrompt == nil, let p = userPromptText(o), !p.hasPrefix("["), !p.hasPrefix("{") { firstPrompt = p }
                if title != nil && cwd != nil && isInteractive { break }
            }
            let id = u.deletingPathExtension().lastPathComponent
            // Only real, established interactive chats: they have an entrypoint AND a
            // Claude-generated ai-title. Subagent ("agent-*"), workflow, and headless
            // sessions lack the title (or use the agent- naming), so they're dropped.
            guard isInteractive, let realTitle = title, !realTitle.isEmpty, !id.hasPrefix("agent-") else { continue }
            let project = cwd.map { ($0 as NSString).lastPathComponent } ?? "chat"
            let chat = RecentChat(id: id, project: project, cwd: cwd,
                                  title: realTitle, firstPrompt: firstPrompt, lastActive: mod)
            let key = realTitle.lowercased()
            if seenNames.contains(key) { continue }                    // dedupe
            seenNames.insert(key)
            out.append(chat)
        }
        return out
    }

    /// The genuine human-typed text of a user message, or nil if this isn't one
    /// (tool_result continuation, or Claude Code injected context).
    private static func userPromptText(_ o: [String: Any]) -> String? {
        guard (o["type"] as? String) == "user", let m = o["message"] as? [String: Any] else { return nil }
        let injected = ["<system-reminder", "<command-", "<local-command", "<user-memory",
                        "Caveat:", "[Request interrupted", "This session is being continued"]
        var text: String?
        if let s = m["content"] as? String { text = s }
        else if let blocks = m["content"] as? [[String: Any]] {
            // Keep only real text blocks, dropping injected-context blocks individually
            // — so a real prompt preceded by an injected block isn't lost (which froze
            // WORKING NOW on an old prompt).
            let texts = blocks.compactMap { b -> String? in
                guard (b["type"] as? String) == "text", let t = b["text"] as? String else { return nil }
                let tt = t.trimmingCharacters(in: .whitespacesAndNewlines)
                return (tt.isEmpty || injected.contains { tt.hasPrefix($0) }) ? nil : tt
            }
            if texts.isEmpty { return nil }   // tool_result / injected-only = mid-turn continuation
            text = texts.joined(separator: " ")
        }
        guard var t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        if injected.contains(where: { t.hasPrefix($0) }) { return nil }
        // Strip a system-reminder appended to an otherwise-real prompt.
        if let r = t.range(of: "<system-reminder") { t = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines) }
        return t.isEmpty ? nil : t
    }
    private static func intVal(_ a: Any?) -> Int {
        if let i = a as? Int { return i }
        if let d = a as? Double { return Int(d) }
        if let n = a as? NSNumber { return n.intValue }
        return 0
    }

    /// The recent conversation of a session (your prompts + Claude's text replies),
    /// oldest→newest, for showing the real chat thread on the phone. Tail-reads so
    /// it's cheap even on a huge transcript (older messages beyond the tail drop off).
    static func sessionMessages(sessionId: String, cwd: String = "", limit: Int = 40) -> [(role: String, text: String)] {
        let base = projectsBase()
        var url: URL?
        if !cwd.isEmpty {   // fast path: Claude Code encodes the cwd as the project dir name
            let encoded = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
            let candidate = base.appendingPathComponent(encoded).appendingPathComponent("\(sessionId).jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) { url = candidate }
        }
        if url == nil, let en = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) {
            while let u = en.nextObject() as? URL {
                if u.lastPathComponent == "\(sessionId).jsonl" { url = u; break }
            }
        }
        guard let url, let text = tailString(url, maxBytes: 4_000_000) else { return [] }
        var out: [(role: String, text: String)] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            switch o["type"] as? String {
            case "user":
                if let t = userPromptText(o) { out.append(("user", t)) }
            case "assistant":
                if let blocks = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] {
                    let txt = blocks.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
                        .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !txt.isEmpty { out.append(("assistant", txt)) }
                }
            default: break
            }
        }
        return Array(out.suffix(limit))
    }

    private static let headCwdLock = NSLock()
    private static var headCwdCache: [String: String] = [:]   // sessionId → creation cwd (the resumable project dir)

    /// The cwd the session was CREATED in (first record) — the project dir that
    /// `claude --resume` needs. Resume is cwd-sensitive: run from the wrong dir it
    /// fails with "No conversation found". The latest cwd in the transcript can
    /// differ (you cd'd), so we must use the creation cwd to resume from the phone.
    static func headCwd(_ url: URL) -> String? {
        let id = url.deletingPathExtension().lastPathComponent
        headCwdLock.lock(); let cached = headCwdCache[id]; headCwdLock.unlock()
        if let cached { return cached }
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let data = (try? fh.read(upToCount: 131072)) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
               let cwd = o["cwd"] as? String, !cwd.isEmpty {
                headCwdLock.lock(); headCwdCache[id] = cwd; headCwdLock.unlock()
                return cwd
            }
        }
        return nil
    }

    /// The last `maxBytes` of a file as text, dropping the partial first line.
    /// Lets the working-session scan stay fast on huge transcripts.
    private static func tailString(_ url: URL, maxBytes: Int) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? fh.seek(toOffset: start)
        let data = (try? fh.readToEnd()) ?? Data()
        // Lossy decode: the tail can start mid-codepoint, where String(data:utf8:)
        // returns nil and silently drops all history. Dropping the partial first line
        // removes any replacement chars from the split.
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
        return text
    }
}

// MARK: - Live plan usage (Claude Code OAuth)

struct PlanUsage: Codable {
    var fiveHourPct: Double = 0
    var fiveHourReset: Date?
    var weekPct: Double = 0
    var weekReset: Date?
    var extraEnabled = false
    var extraUsed: Double = 0
    var extraLimit: Double = 0
}

struct BurnInfo {
    var ratePerHour: Double          // % of the 5-hour window per hour
    var timeToLimit: TimeInterval?   // seconds to 100% at current pace, nil if flat
    var willHitBeforeReset: Bool
}

func readClaudeOAuthToken() -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-a", NSUserName(), "-w"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let done = DispatchSemaphore(value: 0)
    var data = Data()
    DispatchQueue.global(qos: .userInitiated).async {
        data = out.fileHandleForReading.readDataToEndOfFile()
        done.signal()
    }
    if done.wait(timeout: .now() + 5) == .timedOut { p.terminate(); return nil }
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let o = j["claudeAiOauth"] as? [String: Any],
          let tok = o["accessToken"] as? String, !tok.isEmpty else { return nil }
    return tok
}

func parseResetDate(_ s: String) -> Date? {
    if let d = UsageLoader.parseDate(s) { return d }
    if let r = s.range(of: #"\.\d+"#, options: .regularExpression) {
        var t = s; t.removeSubrange(r); return UsageLoader.parseDate(t)
    }
    return nil
}

enum PlanResult { case ok(PlanUsage), unauthorized, rateLimited, transient }

func parsePlanUsage(_ j: [String: Any]) -> PlanUsage? {
    guard j["five_hour"] is [String: Any] else { return nil }
    func blk(_ key: String) -> (Double, Date?) {
        guard let b = j[key] as? [String: Any] else { return (0, nil) }
        let raw: Double = (b["utilization"] as? Double) ?? Double(b["utilization"] as? Int ?? 0)
        let u = raw.isFinite ? min(max(raw, 0), 1000) : 0
        let d = (b["resets_at"] as? String).flatMap(parseResetDate)
        return (u, d)
    }
    let (f, fr) = blk("five_hour"); let (w, wr) = blk("seven_day")
    var pu = PlanUsage(fiveHourPct: f, fiveHourReset: fr, weekPct: w, weekReset: wr)
    if let e = j["extra_usage"] as? [String: Any] {
        pu.extraEnabled = e["is_enabled"] as? Bool ?? false
        pu.extraUsed = (e["used_credits"] as? Double) ?? Double(e["used_credits"] as? Int ?? 0)
        pu.extraLimit = (e["monthly_limit"] as? Double) ?? Double(e["monthly_limit"] as? Int ?? 0)
    }
    return pu
}

func classifyPlanResponse(_ data: Data?, _ resp: URLResponse?) -> PlanResult {
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    switch code {
    case 200:
        if let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let p = parsePlanUsage(j) { return .ok(p) }
        return .transient
    case 401, 403: return .unauthorized
    case 429:      return .rateLimited
    default:       return .transient
    }
}

func fetchPlanUsage(_ token: String, _ completion: @escaping (PlanResult) -> Void) {
    guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { completion(.transient); return }
    var req = URLRequest(url: url, timeoutInterval: 12)
    req.cachePolicy = .reloadIgnoringLocalCacheData
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue("claude-cli/2.1.156 (external, cli)", forHTTPHeaderField: "User-Agent")
    URLSession.shared.dataTask(with: req) { data, resp, _ in completion(classifyPlanResponse(data, resp)) }.resume()
}
