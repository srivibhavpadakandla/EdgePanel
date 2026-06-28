// UsageView — the edge panel's content, matching the ClaudeUsage "Usage"
// screenshot (warm near-black, serif headers, olive bars) and adding the three
// Phase-1 cheap wins: context-window gauge, wall-clock limit time, per-model
// 5H split. Always dark (the overlay floats over arbitrary content).

import SwiftUI
import AppKit

// MARK: - Reusable cards (ported from ClaudeUsage)

struct Pill: View {
    let text: String, theme: Theme
    var body: some View {
        Text(text)
            .font(.claude(12, .medium)).foregroundColor(theme.text)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Capsule().fill(theme.track))
    }
}

struct PercentCard: View {
    let title: String
    let frac: Double?
    let theme: Theme
    var sub: String? = nil
    var body: some View {
        let f = frac ?? 0
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.claude(10, .semibold)).tracking(0.7).foregroundColor(theme.subtext)
            Text(frac == nil ? "—" : fmtPct(f)).font(.claude(22, .bold)).foregroundColor(theme.text)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.track).frame(height: 7)
                    if frac != nil {
                        Capsule().fill(sevColor(f, theme))
                            .frame(width: max(7, geo.size.width * min(max(f, 0), 1)), height: 7)
                    }
                }
            }.frame(height: 7)
            if let sub { Text(sub).font(.claude(11)).foregroundColor(theme.subtext) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.border, lineWidth: 1))
    }
}

struct SpendCard: View {
    let amount: Double, theme: Theme
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("5H SPEND").font(.claude(10, .semibold)).tracking(0.7).foregroundColor(theme.subtext)
            Text(fmtCost(amount)).font(.claude(22, .bold)).foregroundColor(theme.text)
            Text("est. API value · this window").font(.claude(11)).foregroundColor(theme.subtext)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.border, lineWidth: 1))
    }
}

/// GitHub-style heatmap of Claude Code usage this month (real local data: each
/// day shaded by billable tokens used, today ringed, plus a streak badge).
/// Ported from ClaudeUsage; replaces the 5-hour line graph.
struct MonthCalendar: View {
    let dayTokens: [Int: Int]   // day-of-month → billable tokens (>0 = active)
    let theme: Theme
    private static let monthName: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM"; return f
    }()
    private func used(_ day: Int) -> Int { dayTokens[day] ?? 0 }
    private func shade(_ level: Int) -> Color { theme.heat[min(max(level, 0), 4)] }

    var body: some View {
        let cal = Calendar.current
        let now = Date()
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        let daysInMonth = cal.range(of: .day, in: .month, for: now)?.count ?? 30
        let leading = cal.component(.weekday, from: monthStart) - 1
        let today = cal.component(.day, from: now)
        let rows = Int(ceil(Double(leading + daysInMonth) / 7.0))
        let n = dayTokens.values.filter { $0 > 0 }.count
        let maxU = max(dayTokens.values.max() ?? 1, 1)
        let streak: Int = {
            var s = 0, d = today
            if used(today) == 0 && used(today - 1) > 0 { d = today - 1 }
            while d >= 1 && used(d) > 0 { s += 1; d -= 1 }
            return s
        }()
        func level(_ day: Int) -> Int {
            let u = used(day)
            guard u > 0 else { return 0 }
            let r = Double(u) / Double(maxU)
            return r > 0.66 ? 4 : r > 0.33 ? 3 : r > 0.12 ? 2 : 1
        }

        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("DAYS USED · \(Self.monthName.string(from: now).uppercased())")
                    .font(.claude(10, .semibold)).tracking(0.7).foregroundColor(theme.subtext)
                Spacer()
                if streak >= 2 {
                    Text("\(streak)-day streak").font(.claude(10, .medium)).foregroundColor(theme.green)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(theme.green.opacity(0.16)))
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(n)").font(.claude(24, .bold)).foregroundColor(theme.accent)
                Text("of \(today) days").font(.claude(12)).foregroundColor(theme.subtext)
            }
            VStack(spacing: 3) {
                HStack(spacing: 3) {
                    ForEach(Array(["S", "M", "T", "W", "T", "F", "S"].enumerated()), id: \.offset) { _, d in
                        Text(d).font(.claude(8, .medium)).foregroundColor(theme.subtext.opacity(0.7))
                            .frame(maxWidth: .infinity)
                    }
                }
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: 3) {
                        ForEach(0..<7, id: \.self) { col in
                            dayCell(row * 7 + col - leading + 1, today: today, total: daysInMonth, level: level)
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Spacer()
                Text("less").font(.claude(8)).foregroundColor(theme.subtext)
                ForEach(1..<5, id: \.self) { l in
                    RoundedRectangle(cornerRadius: 2).fill(shade(l)).frame(width: 8, height: 8)
                }
                Text("more").font(.claude(8)).foregroundColor(theme.subtext)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.border, lineWidth: 1))
    }

    @ViewBuilder
    private func dayCell(_ day: Int, today: Int, total: Int, level: (Int) -> Int) -> some View {
        if day < 1 || day > total {
            Color.clear.frame(maxWidth: .infinity).frame(height: 18)
        } else {
            let future = day > today
            let lvl = future ? -1 : level(day)
            let fill = future ? theme.heat[0].opacity(0.4) : shade(max(lvl, 0))
            let numColor: Color = future ? theme.subtext.opacity(0.35)
                : lvl <= 0 ? theme.subtext.opacity(0.7)
                : lvl >= 3 ? Color.white.opacity(0.92)
                : Color.black.opacity(0.62)
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(fill)
                    .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5) }
                    .overlay {
                        if day == today {
                            RoundedRectangle(cornerRadius: 4).strokeBorder(theme.accent, lineWidth: 1.2)
                        }
                    }
                Text("\(day)").font(.claude(8, lvl >= 1 ? .semibold : .regular)).foregroundColor(numColor)
            }
            .frame(maxWidth: .infinity).frame(height: 18)
        }
    }
}

// MARK: - New cards (the cheap wins)

/// Recent chats: your latest Claude Code sessions, named by their ai-title (or a
/// summarized first prompt). Click a row to open that chat's project in VS Code (or Cursor).
struct RecentChatsCard: View {
    let chats: [RecentChat]
    let summaries: [String: String]
    let theme: Theme
    let onOpen: (RecentChat) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("RECENT CHATS").font(.claude(10, .semibold)).tracking(0.7).foregroundColor(theme.subtext)
            if chats.isEmpty {
                Text("no recent chats").font(.claude(11)).foregroundColor(theme.subtext)
            } else {
                ForEach(chats) { c in
                    Button { onOpen(c) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "bubble.left.and.text.bubble.right")
                                .font(.system(size: 12)).foregroundColor(theme.accent2).frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.name(summaries: summaries)).font(.claude(13, .medium))
                                    .foregroundColor(theme.text).lineLimit(1)
                                Text(c.project).font(.claude(10)).foregroundColor(theme.subtext).lineLimit(1)
                            }
                            Spacer(minLength: 6)
                            Text(fmtAgo(c.lastActive)).font(.claude(10)).foregroundColor(theme.subtext)
                            Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundColor(theme.subtext)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open “\(c.name(summaries: summaries))” in VS Code")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.border, lineWidth: 1))
    }
}

/// Working chats: sessions you've prompted into that are still generating a
/// response (transcript actively being written). Shows the running clock since
/// your prompt and the tokens the turn has used. The clock ticks every second
/// and stale sessions drop off the moment generation stops.
struct SessionsCard: View {
    let sessions: [LiveSession]
    let summaries: [String: String]   // sessionID → short prompt summary
    let theme: Theme

    private func promptLine(_ s: LiveSession) -> String {
        guard let pt = s.promptText, !pt.isEmpty else { return "working…" }
        if pt.count <= PromptSummarizer.threshold { return pt }
        return summaries[s.id] ?? (String(pt.prefix(60)) + "…")   // summary, or a clean truncation until it lands
    }

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { ctx in
            let now = ctx.date
            let working = sessions.filter { $0.isWorking(asOf: now) }
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("WORKING NOW").font(.claude(10, .semibold)).tracking(0.7).foregroundColor(theme.subtext)
                    Spacer()
                    if !working.isEmpty {
                        Text("\(working.count) running").font(.claude(10, .medium)).foregroundColor(theme.green)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Capsule().fill(theme.green.opacity(0.16)))
                    }
                }
                if working.isEmpty {
                    Text("nothing running — waiting on your next prompt")
                        .font(.claude(11)).foregroundColor(theme.subtext)
                } else {
                    ForEach(working.prefix(4)) { s in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 9) {
                                Circle().fill(theme.green).frame(width: 7, height: 7)
                                Text(s.project).font(.claude(13, .semibold)).foregroundColor(theme.text).lineLimit(1)
                                Spacer(minLength: 6)
                                Image(systemName: "clock").font(.system(size: 9)).foregroundColor(theme.green)
                                Text(s.promptAt == nil ? "—" : fmtElapsed(s.elapsed(asOf: now)))
                                    .font(.claude(13, .semibold)).foregroundColor(theme.green).monospacedDigit()
                            }
                            // The prompt you gave this chat (summarized if long) — labeled
                            // + quoted so it's clearly your prompt, not the stats.
                            (Text("PROMPT  ").font(.claude(9, .semibold)).tracking(0.5).foregroundColor(theme.subtext)
                                + Text("\u{201C}\(promptLine(s))\u{201D}").font(.claude(12)).italic().foregroundColor(theme.text.opacity(0.88)))
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 5) {
                                if s.turnTokens == 0 {
                                    Text("starting…").font(.claude(11)).foregroundColor(theme.subtext)
                                    Text("· \(s.model.map(prettyModel) ?? "Claude")").font(.claude(10)).foregroundColor(theme.subtext)
                                } else {
                                    Text(fmtTokens(s.turnTokens)).font(.claude(13, .semibold)).foregroundColor(theme.text)
                                    Text("tokens this turn · \(s.model.map(prettyModel) ?? "Claude")")
                                        .font(.claude(10)).foregroundColor(theme.subtext)
                                }
                            }
                            // Live proof-of-work: subagents in flight + prompts waiting in line.
                            if s.runningAgents > 0 || s.queuedPrompts > 0 {
                                HStack(spacing: 6) {
                                    if s.runningAgents > 0 {
                                        StatusPill(icon: "person.2.fill", text: "\(s.runningAgents) agent\(s.runningAgents == 1 ? "" : "s") working", color: theme.green)
                                    }
                                    if s.queuedPrompts > 0 {
                                        StatusPill(icon: "tray.full.fill", text: "\(s.queuedPrompts) queued", color: theme.subtext)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(theme.card))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.border, lineWidth: 1))
        }
    }
}

/// A small icon+text capsule for live-status badges (agents working / prompts queued).
private struct StatusPill: View {
    let icon: String, text: String, color: Color
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .semibold))
            Text(text).font(.claude(10, .semibold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

// MARK: - Permission gate (Phase 2)

struct PermissionCard: View {
    let pending: PendingPermission
    let theme: Theme
    let onAllow: () -> Void
    let onDeny: () -> Void
    let onAlways: () -> Void

    private var riskColor: Color {
        switch pending.risk {
        case .read:    return theme.green
        case .write:   return theme.amber
        case .danger:  return theme.red
        case .unknown: return theme.accent
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(riskColor).frame(width: 8, height: 8)
                Text("PERMISSION").font(.claude(10, .semibold)).tracking(0.7).foregroundColor(theme.subtext)
                Spacer()
                Text(pending.reason).font(.claude(10, .medium)).foregroundColor(riskColor)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(pending.toolName).font(.claude(22, .bold)).foregroundColor(theme.text)
                if let p = pending.project {
                    Text(p).font(.claude(11)).foregroundColor(theme.subtext)
                }
            }
            if !pending.preview.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(pending.preview) { line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(previewColor(line.kind))
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9).fill(theme.bg.opacity(0.55)))
            } else if !pending.summary.isEmpty {
                Text(pending.summary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.subtext).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                button("Deny", fg: theme.text, bg: theme.track, action: onDeny)
                button("Always", fg: theme.subtext, bg: theme.track, action: onAlways)
                button("Allow", fg: theme.bg, bg: riskColor, action: onAllow)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(riskColor.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(riskColor.opacity(0.4), lineWidth: 1))
    }

    private func button(_ title: String, fg: Color, bg: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.claude(13, .semibold)).foregroundColor(fg)
                .frame(maxWidth: .infinity).padding(.vertical, 9)
                .background(Capsule().fill(bg))
        }
        .buttonStyle(.plain)
    }
    private func previewColor(_ k: PreviewLine.Kind) -> Color {
        switch k {
        case .added:   return theme.green
        case .removed: return theme.red
        case .context: return theme.subtext
        }
    }
}


// MARK: - Root

struct EdgeUsageView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var state: EdgePanelState

    private let cardWidth: CGFloat = 380

    // Cap the scrolling content so the whole panel never exceeds the screen.
    private var maxContentHeight: CGFloat {
        let h = (NSScreen.screens.max(by: { $0.frame.maxX < $1.frame.maxX })?.frame.height ?? 1000)
        return max(360, h - 220)
    }

    var body: some View {
        let t = Theme.resolve(.dark)
        VStack(spacing: 0) {
            header(t)
            ScrollView(.vertical, showsIndicators: false) {
                content(t).padding(16)
            }
            .frame(maxHeight: maxContentHeight)
            footer(t)
        }
        .frame(width: cardWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 18).fill(t.bg))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(t.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.5), radius: 22, x: -10, y: 0)
        .padding(EdgeInsets(top: 14, leading: 22, bottom: 14, trailing: 6))
    }

    // MARK: header

    private func header(_ t: Theme) -> some View {
        HStack(spacing: 10) {
            headerMascot(t).frame(width: 48, alignment: .leading)
            Spacer(minLength: 0)
            Text("Usage").font(.claude(26, .semibold)).foregroundColor(t.text)
            Spacer(minLength: 0)
            Button { store.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .rotationEffect(.degrees(store.loading ? 360 : 0))
                    .animation(store.loading ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: store.loading)
            }
            .buttonStyle(.plain).foregroundColor(t.subtext).frame(width: 42, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .overlay(Rectangle().fill(t.border).frame(height: 1), alignment: .bottom)
    }

    private func usagePercent() -> Double { store.displayFiveHourPct ?? 0 }

    private func headerMascot(_ t: Theme) -> some View {
        let name: String
        switch state.phase {
        case .failed:  name = "expression_surprise"
        case .done:    name = "dance_bounce"
        case .running: name = "work_coding"
        case .idle:    name = usagePercent() >= 90 ? "expression_surprise" : "idle_blink"
        }
        return AnimatedMascot(name: name, cell: 2.2, fill: t.accent2, eye: t.bg, crop: false)
    }

    // MARK: content

    private func content(_ t: Theme) -> some View {
        let s = store.summary
        let weeklyFrac: Double? = store.plan.map { min(max($0.weekPct / 100, 0), 1) }
        let weeklySub: String? = store.plan?.weekReset.map { r in
            let rem = max(r.timeIntervalSinceNow, 0)
            return "resets in \(Int(rem) / 86400)d \((Int(rem) % 86400) / 3600)h"
        } ?? (store.plan == nil ? "sign in for weekly" : nil)
        let windowSpend: Double = {
            if let reset = store.plan?.fiveHourReset, reset > Date() {
                let start = reset.addingTimeInterval(-18000)
                return s.recentEvents.filter { $0.date >= start && $0.date <= reset }.reduce(0) { $0 + $1.cost }
            }
            return s.block?.cost ?? 0
        }()

        return VStack(spacing: 14) {
            if let p = state.pending {
                PermissionCard(pending: p, theme: t,
                               onAllow: { state.resolveCurrent(.allow) },
                               onDeny: { state.resolveCurrent(.deny) },
                               onAlways: { state.allowAlwaysCurrent() })
            }
            if let plan = store.plan {
                planCard(t, "Current", plan.fiveHourPct, plan.fiveHourReset, burn: store.burn)
            } else if let b = s.block {
                windowCard(t, b, s)
            }

            SessionsCard(sessions: store.sessions, summaries: store.promptSummaries, theme: t)

            MonthCalendar(dayTokens: s.monthDayTokens, theme: t)

            HStack(spacing: 10) {
                PercentCard(title: "Weekly", frac: weeklyFrac, theme: t, sub: weeklySub)
                SpendCard(amount: windowSpend, theme: t)
            }

            RecentChatsCard(chats: store.recentChats, summaries: store.promptSummaries, theme: t,
                            onOpen: { state.openChat(cwd: $0.cwd, id: $0.id) })

            footnote(t)
        }
    }

    private func section<V: View>(_ title: String, _ t: Theme, @ViewBuilder _ body: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.claude(10, .semibold)).tracking(0.7).foregroundColor(t.subtext)
            body()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func planCard(_ t: Theme, _ title: String, _ pct: Double, _ reset: Date?, burn: BurnInfo?) -> some View {
        TimelineView(.periodic(from: Date(), by: 1)) { ctx in
            let now = ctx.date
            let expired = (reset.map { $0 <= now }) ?? false
            let shownPct = expired ? 0 : pct
            let frac = min(max(shownPct / 100, 0), 1)
            let sub: String = {
                guard let reset else { return "live plan usage" }
                if expired { return "new window · updating…" }
                let rem = max(reset.timeIntervalSince(now), 0)
                return "resets in \(Int(rem) / 3600)h \((Int(rem) % 3600) / 60)m"
            }()
            let burnNote: (String, Color)? = {
                guard !expired else { return nil }
                guard let burn else { return ("measuring your pace…", t.subtext) }
                let rate = "+\(Int(burn.ratePerHour.rounded()))%/hr"
                if let tt = burn.timeToLimit, burn.willHitBeforeReset {
                    let clock = store.limitClock.map { "limit ~\(fmtClock($0))" } ?? "≈ \(fmtDur(tt)) left"
                    return ("\(clock) · \(rate)", t.red)
                }
                return burn.ratePerHour >= 0.5
                    ? ("\(rate) · lasts the full window", t.subtext)
                    : ("steady · lasts the full window", t.green)
            }()
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Int(shownPct.rounded()))%").font(.claude(30, .bold)).foregroundColor(t.text)
                    Spacer()
                    Pill(text: title, theme: t)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(t.track).frame(height: 8)
                        Capsule().fill(sevColor(frac, t)).frame(width: max(8, geo.size.width * frac), height: 8)
                    }
                }.frame(height: 8)
                VStack(alignment: .leading, spacing: 4) {
                    Text(sub).font(.claude(12)).foregroundColor(t.subtext)
                    if let (txt, col) = burnNote {
                        Text(txt).font(.claude(12, .medium)).foregroundColor(col)
                    }
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14).fill(t.accentSoft))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(t.border, lineWidth: 1))
        }
    }

    private func windowCard(_ t: Theme, _ b: BlockInfo, _ s: Summary) -> some View {
        let now = Date()
        let frac = min(max(Double(b.billable) / Double(max(s.limitWindow, 1)), 0), 1)
        let rem = max(b.resetAt.timeIntervalSince(now), 0)
        let h = Int(rem) / 3600, m = (Int(rem) % 3600) / 60
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(fmtPct(frac)).font(.claude(28, .bold)).foregroundColor(t.text)
                Spacer()
                Pill(text: "Current (local est.)", theme: t)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(t.track).frame(height: 8)
                    Capsule().fill(sevColor(frac, t)).frame(width: max(8, geo.size.width * frac), height: 8)
                }
            }.frame(height: 8)
            Text("resets in \(h)h \(m)m").font(.claude(12)).foregroundColor(t.subtext)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(t.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(t.border, lineWidth: 1))
    }

    private func footnote(_ t: Theme) -> some View {
        let txt = store.plan != nil
            ? "Current & Weekly are live plan limits. Context is this session. 5H Spend is an est. of API-rate cost; graph is local."
            : (store.tokenMissing
               ? "No Claude Code login found; plan limits unavailable. Numbers below are local estimates."
               : "Fetching live plan…")
        return Text(txt)
            .font(.claude(10)).foregroundColor(t.subtext)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: footer

    private func footer(_ t: Theme) -> some View {
        HStack(spacing: 8) {
            Text("✳").font(.claude(11)).foregroundColor(state.isActive ? t.accent : t.subtext)
            Text(statusText()).font(.claude(11)).foregroundColor(state.isActive ? t.accent : t.subtext)
            Spacer()
            Button { NSApp.terminate(nil) } label: {
                Text("Quit").font(.claude(12, .medium))
            }.buttonStyle(.plain).foregroundColor(t.subtext)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .overlay(Rectangle().fill(t.border).frame(height: 1), alignment: .top)
    }

    private func statusText() -> String {
        if state.phase == .idle && store.loading { return "Baking…" }
        if let p = state.projectLabel, state.isActive { return "\(state.statusVerb) · \(p)" }
        return state.statusVerb
    }
}
