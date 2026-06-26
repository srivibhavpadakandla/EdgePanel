import SwiftUI

@main
struct EdgePanelMobileApp: App {
    @StateObject private var client = EdgeClient()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(client)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var client: EdgeClient
    @State private var showPair = false
    var body: some View {
        ZStack {
            T.bg.ignoresSafeArea()
            ScrollView { Dashboard().padding(16) }
        }
        .safeAreaInset(edge: .top) { header }
        .sheet(isPresented: $showPair) { PairSheet().environmentObject(client) }
        .onAppear {
            ActivityManager.shared.requestNotifications()
            if client.token.isEmpty { showPair = true } else { client.start() }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "bird.fill").foregroundColor(T.accent2)
            Text("Usage").font(.claude(24, .semibold)).foregroundColor(T.text)
            Spacer()
            Circle().fill(client.connected ? T.green : T.red).frame(width: 8, height: 8)
            Button { showPair = true } label: { Image(systemName: "gearshape").foregroundColor(T.subtext) }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(T.bg.opacity(0.96))
    }
}

struct Dashboard: View {
    @EnvironmentObject var client: EdgeClient
    var body: some View {
        VStack(spacing: 14) {
            if let s = client.snapshot {
                if let p = s.plan { PlanCard(plan: p) }
                WorkingCard(working: s.working)
                CalendarCard(days: s.calendar)
                HStack(spacing: 12) {
                    WeeklyCard(plan: s.plan)
                    SpendCard(spend: s.spend)
                }
                RecentChatsCard(chats: s.chats)
            } else {
                VStack(spacing: 10) {
                    ProgressView().tint(T.accent)
                    Text(client.lastError ?? "Connecting to your Mac…")
                        .font(.claude(13)).foregroundColor(T.subtext).multilineTextAlignment(.center)
                }.padding(.top, 80)
            }
        }
    }
}

// MARK: - Cards

struct PlanCard: View {
    let plan: EdgeSnapshot.PlanInfo
    var body: some View {
        let frac = min(max(plan.fiveHourPct / 100, 0), 1)
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Int(plan.fiveHourPct.rounded()))%").font(.claude(38, .bold)).foregroundColor(T.text)
                    Spacer()
                    Text("CURRENT").font(.claude(12, .medium)).foregroundColor(T.text)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Capsule().fill(T.track))
                }
                Bar(frac: frac, color: sevColor(frac))
                if let reset = plan.fiveHourResetEpoch {
                    let rem = max(reset - Date().timeIntervalSince1970, 0)
                    Text("resets in \(Int(rem) / 3600)h \((Int(rem) % 3600) / 60)m")
                        .font(.claude(13)).foregroundColor(T.subtext)
                }
                if let burn = plan.burnPerHour, burn >= 0.5 {
                    let clock = plan.limitClockEpoch.map { "limit ~\(timeStr($0))" }
                    Text("\(clock.map { "\($0) · " } ?? "")+\(Int(burn.rounded()))%/hr")
                        .font(.claude(13, .medium)).foregroundColor(plan.limitClockEpoch != nil ? T.red : T.subtext)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(T.accentSoft))
    }
}

struct WorkingCard: View {
    let working: [EdgeSnapshot.Working]
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel(text: "Working now")
                    Spacer()
                    if !working.isEmpty {
                        Text("\(working.count) running").font(.claude(11, .medium)).foregroundColor(T.green)
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .background(Capsule().fill(T.green.opacity(0.16)))
                    }
                }
                if working.isEmpty {
                    Text("nothing running — waiting on your next prompt")
                        .font(.claude(12)).foregroundColor(T.subtext)
                } else {
                    ForEach(working) { w in WorkingRow(w: w) }
                }
            }
        }
    }
}

struct WorkingRow: View {
    let w: EdgeSnapshot.Working
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Circle().fill(T.green).frame(width: 8, height: 8)
                Text(w.project).font(.claude(15, .semibold)).foregroundColor(T.text)
                Spacer()
                Image(systemName: "clock").font(.system(size: 10)).foregroundColor(T.green)
                if let at = w.promptAt {
                    Text(at, style: .timer).font(.claude(14, .semibold)).foregroundColor(T.green).monospacedDigit()
                } else {
                    Text("—").foregroundColor(T.green)
                }
            }
            (Text("PROMPT  ").font(.claude(10, .semibold)).foregroundColor(T.subtext)
                + Text("\u{201C}\(w.display)\u{201D}").font(.claude(14)).italic().foregroundColor(T.text.opacity(0.9)))
                .lineLimit(3)
            HStack(spacing: 5) {
                Text(fmtTokens(w.turnTokens)).font(.claude(14, .semibold)).foregroundColor(T.text)
                Text("tokens this turn · \(prettyModel(w.model))").font(.claude(11)).foregroundColor(T.subtext)
            }
        }
        .padding(.vertical, 4)
    }
}

struct WeeklyCard: View {
    let plan: EdgeSnapshot.PlanInfo?
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Weekly")
                Text(plan.map { "\(Int($0.weekPct.rounded()))%" } ?? "—").font(.claude(24, .bold)).foregroundColor(T.text)
                Bar(frac: min(max((plan?.weekPct ?? 0) / 100, 0), 1), color: sevColor((plan?.weekPct ?? 0) / 100))
                if let reset = plan?.weekResetEpoch {
                    let rem = max(reset - Date().timeIntervalSince1970, 0)
                    Text("resets in \(Int(rem) / 86400)d \((Int(rem) % 86400) / 3600)h")
                        .font(.claude(11)).foregroundColor(T.subtext)
                }
            }
        }
    }
}

struct SpendCard: View {
    let spend: EdgeSnapshot.Spend
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "5H Spend")
                Text(fmtCost(spend.fiveHourUSD)).font(.claude(24, .bold)).foregroundColor(T.text)
                Text("est. API value · this window").font(.claude(11)).foregroundColor(T.subtext)
            }
        }
    }
}

struct RecentChatsCard: View {
    @EnvironmentObject var client: EdgeClient
    let chats: [EdgeSnapshot.Chat]
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Recent chats")
                if chats.isEmpty {
                    Text("no recent chats").font(.claude(12)).foregroundColor(T.subtext)
                } else {
                    ForEach(chats) { c in
                        Button { client.openChat(c) } label: {
                            HStack(spacing: 11) {
                                Image(systemName: "bubble.left.and.text.bubble.right")
                                    .font(.system(size: 13)).foregroundColor(T.accent2).frame(width: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(c.name).font(.claude(14, .medium)).foregroundColor(T.text).lineLimit(1)
                                    Text(c.project).font(.claude(11)).foregroundColor(T.subtext).lineLimit(1)
                                }
                                Spacer(minLength: 6)
                                Text(c.lastActive, style: .relative).font(.claude(10)).foregroundColor(T.subtext)
                                Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundColor(T.subtext)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if c.id != chats.last?.id { Divider().overlay(T.border) }
                    }
                }
            }
        }
    }
}

struct CalendarCard: View {
    let days: [EdgeSnapshot.CalDay]
    var body: some View {
        let map = Dictionary(uniqueKeysWithValues: days.map { ($0.day, $0.tokens) })
        let cal = Calendar.current
        let now = Date()
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        let daysInMonth = cal.range(of: .day, in: .month, for: now)?.count ?? 30
        let leading = cal.component(.weekday, from: monthStart) - 1
        let today = cal.component(.day, from: now)
        let rows = Int(ceil(Double(leading + daysInMonth) / 7.0))
        let maxU = max(map.values.max() ?? 1, 1)
        let used = map.values.filter { $0 > 0 }.count
        func level(_ d: Int) -> Int {
            guard let u = map[d], u > 0 else { return 0 }
            let r = Double(u) / Double(maxU)
            return r > 0.66 ? 4 : r > 0.33 ? 3 : r > 0.12 ? 2 : 1
        }
        let monthName = monthStart.formatted(.dateTime.month(.wide))
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Days used · \(monthName)")
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(used)").font(.claude(26, .bold)).foregroundColor(T.accent)
                    Text("of \(today) days").font(.claude(13)).foregroundColor(T.subtext)
                }
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        ForEach(Array(["S", "M", "T", "W", "T", "F", "S"].enumerated()), id: \.offset) { _, d in
                            Text(d).font(.claude(9, .medium)).foregroundColor(T.subtext.opacity(0.7)).frame(maxWidth: .infinity)
                        }
                    }
                    ForEach(0..<rows, id: \.self) { row in
                        HStack(spacing: 4) {
                            ForEach(0..<7, id: \.self) { col in
                                let day = row * 7 + col - leading + 1
                                cell(day, today: today, total: daysInMonth, level: level)
                            }
                        }
                    }
                }
            }
        }
    }
    @ViewBuilder
    private func cell(_ day: Int, today: Int, total: Int, level: (Int) -> Int) -> some View {
        if day < 1 || day > total {
            Color.clear.frame(maxWidth: .infinity).frame(height: 26)
        } else {
            let future = day > today
            let lvl = future ? -1 : level(day)
            let fill = future ? T.heat[0].opacity(0.4) : T.heat[min(max(lvl, 0), 4)]
            let numColor: Color = future ? T.subtext.opacity(0.35)
                : lvl <= 0 ? T.subtext.opacity(0.7) : lvl >= 3 ? .white.opacity(0.92) : .black.opacity(0.62)
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(fill)
                    .overlay { if day == today { RoundedRectangle(cornerRadius: 5).strokeBorder(T.accent, lineWidth: 1.4) } }
                Text("\(day)").font(.claude(10, lvl >= 1 ? .semibold : .regular)).foregroundColor(numColor)
            }
            .frame(maxWidth: .infinity).frame(height: 26)
        }
    }
}

struct Bar: View {
    let frac: Double; let color: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(T.track).frame(height: 8)
                Capsule().fill(color).frame(width: max(8, geo.size.width * min(max(frac, 0), 1)), height: 8)
            }
        }.frame(height: 8)
    }
}

// MARK: - Pairing

struct PairSheet: View {
    @EnvironmentObject var client: EdgeClient
    @Environment(\.dismiss) var dismiss
    @State private var host = ""
    @State private var token = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("Mac address") {
                    TextField("192.168.1.20:8788", text: $host)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                }
                Section("Pairing token") {
                    TextField("from the EdgePanel menu on your Mac", text: $token)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                }
                Section {
                    Text("On your Mac, EdgePanel logs its address + token at launch. Both apps must be on the same network.")
                        .font(.footnote).foregroundColor(.secondary)
                }
            }
            .navigationTitle("Connect to Mac")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        client.host = host.trimmingCharacters(in: .whitespaces)
                        client.token = token.trimmingCharacters(in: .whitespaces)
                        client.start(); dismiss()
                    }.disabled(host.isEmpty || token.isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear { host = client.host; token = client.token }
        }
    }
}

func timeStr(_ epoch: Double) -> String {
    let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
    return f.string(from: Date(timeIntervalSince1970: epoch))
}
