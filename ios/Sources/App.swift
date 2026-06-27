import SwiftUI
import BackgroundTasks
import UIKit

let bgRefreshID = "com.srivibhav.edgepanel.refresh"

@main
struct EdgePanelMobileApp: App {
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate
    @StateObject private var client = EdgeClient.shared
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(client)
                .preferredColorScheme(.dark)
        }
    }
}

/// Forwards the APNs device token to the Mac (Tier 2 alerts) and handles the
/// Allow/Deny buttons on permission notifications.
final class PushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Best-effort background reconcile: lets a finished prompt flip the Live
        // Activity to done + fire its notification even while the app is backgrounded.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: bgRefreshID, using: nil) { task in
            self.handleAppRefresh(task as! BGAppRefreshTask)
        }
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) { scheduleAppRefresh() }

    private func scheduleAppRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: bgRefreshID)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }

    private func handleAppRefresh(_ task: BGAppRefreshTask) {
        scheduleAppRefresh()   // chain the next one
        let work = Task { @MainActor in await EdgeClient.shared.poll() }
        task.expirationHandler = { work.cancel() }
        Task { _ = await work.value; task.setTaskCompleted(success: true) }
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in EdgeClient.shared.postPushToken(kind: "device", sessionId: nil, pushToken: hex) }
    }

    // Show permission/done banners even when the app is in the foreground.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // Allow / Deny tapped on a permission notification → resolve it on the Mac.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let id = response.notification.request.content.userInfo["permId"] as? String {
            let decision = response.actionIdentifier == "ALLOW" ? "allow"
                         : response.actionIdentifier == "DENY"  ? "deny"  : ""
            if !decision.isEmpty {
                Task { @MainActor in EdgeClient.shared.decidePermission(id: id, decision: decision) }
            }
        }
        completionHandler()
    }
}

struct RootView: View {
    @EnvironmentObject var client: EdgeClient
    @Environment(\.scenePhase) private var scenePhase
    @State private var showPair = false
    var body: some View {
        TabView {
            UsageTab(showPair: $showPair)
                .tabItem { Label("Usage", systemImage: "gauge.with.dots.needle.bottom.50percent") }
            ChatListView()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right.fill") }
        }
        .tint(T.accent)
        .sheet(isPresented: $showPair) { PairSheet().environmentObject(client) }
        .onAppear {
            ActivityManager.shared.requestNotifications()
            if client.token.isEmpty { showPair = true } else { client.start() }
        }
        // Reconcile the moment the app returns to the foreground, so a stale "still
        // counting" Live Activity self-heals instantly on open.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, !client.token.isEmpty {
                ActivityManager.shared.resendActivityToken()   // re-arm push end after a Mac restart
                UIApplication.shared.registerForRemoteNotifications()  // re-seed the device token too
                Task { await client.poll() }
            }
        }
    }
}

struct UsageTab: View {
    @EnvironmentObject var client: EdgeClient
    @Binding var showPair: Bool
    var body: some View {
        NavigationStack {
            ZStack {
                T.bg.ignoresSafeArea()
                ScrollView { Dashboard().padding(16) }
            }
            .safeAreaInset(edge: .top) { header }
            .toolbar(.hidden, for: .navigationBar)
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
                if let q = s.question { QuestionCard(q: q) }
                if let pend = s.pending { PermissionCard(p: pend) }
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

struct QuestionCard: View {
    @EnvironmentObject var client: EdgeClient
    let q: EdgeSnapshot.Question
    @State private var sel: [String: Set<String>] = [:]   // question → chosen labels

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    Image(systemName: "questionmark.bubble.fill").foregroundColor(T.accent)
                    Text("Claude is asking").font(.claude(15, .semibold)).foregroundColor(T.text)
                    Spacer()
                    if let p = q.project { Text(p).font(.claude(10)).foregroundColor(T.subtext) }
                }
                ForEach(q.items) { item in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(item.question).font(.claude(13, .semibold)).foregroundColor(T.text)
                        if item.multiSelect {
                            Text("pick one or more").font(.claude(10)).foregroundColor(T.subtext)
                        }
                        ForEach(item.options, id: \.label) { opt in
                            Button { toggle(item, opt.label) } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: isSel(item, opt.label)
                                          ? (item.multiSelect ? "checkmark.square.fill" : "checkmark.circle.fill")
                                          : (item.multiSelect ? "square" : "circle"))
                                        .foregroundColor(isSel(item, opt.label) ? T.accent : T.subtext)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(opt.label).font(.claude(13, .medium)).foregroundColor(T.text)
                                        if let d = opt.description, !d.isEmpty {
                                            Text(d).font(.claude(10)).foregroundColor(T.subtext).lineLimit(2)
                                        }
                                    }
                                    Spacer(minLength: 4)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 9)
                                    .fill(isSel(item, opt.label) ? T.accent.opacity(0.16) : T.track.opacity(0.5)))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                Button { submit() } label: {
                    Text("Send answer").font(.claude(14, .semibold)).foregroundColor(.black)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(answered ? T.accent : T.subtext.opacity(0.4)))
                }.buttonStyle(.plain).disabled(!answered)
            }
        }
        .background(RoundedRectangle(cornerRadius: 16).strokeBorder(T.accent.opacity(0.55), lineWidth: 1.2))
    }

    private var answered: Bool { q.items.allSatisfy { !(sel[$0.question] ?? []).isEmpty } }
    private func isSel(_ item: EdgeSnapshot.Question.Item, _ label: String) -> Bool {
        (sel[item.question] ?? []).contains(label)
    }
    private func toggle(_ item: EdgeSnapshot.Question.Item, _ label: String) {
        var s = sel[item.question] ?? []
        if item.multiSelect { if s.contains(label) { s.remove(label) } else { s.insert(label) } }
        else { s = [label] }
        sel[item.question] = s
    }
    private func submit() {
        var answers: [String: String] = [:]
        for item in q.items {
            let chosen = item.options.map { $0.label }.filter { (sel[item.question] ?? []).contains($0) }
            answers[item.question] = chosen.joined(separator: ",")
        }
        client.answerQuestion(id: q.id, answers: answers)
    }
}

struct PermissionCard: View {
    @EnvironmentObject var client: EdgeClient
    let p: EdgeSnapshot.Pending
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    Image(systemName: "lock.shield.fill").foregroundColor(riskColor)
                    Text("Permission needed").font(.claude(15, .semibold)).foregroundColor(T.text)
                    Spacer()
                    Text(p.risk.uppercased()).font(.claude(10, .semibold)).foregroundColor(riskColor)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(riskColor.opacity(0.16)))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(p.tool + (p.project.map { " · \($0)" } ?? ""))
                        .font(.claude(13, .semibold)).foregroundColor(T.text)
                    if !p.summary.isEmpty {
                        Text(p.summary).font(.claude(13)).foregroundColor(T.text.opacity(0.9)).lineLimit(3)
                    }
                    if !p.reason.isEmpty {
                        Text(p.reason).font(.claude(11)).foregroundColor(T.subtext).lineLimit(2)
                    }
                }
                if !p.preview.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(p.preview.prefix(5).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 11, design: .monospaced))
                                .foregroundColor(T.subtext).lineLimit(1)
                        }
                    }
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(T.track.opacity(0.5)))
                }
                HStack(spacing: 10) {
                    Button { client.decidePermission(id: p.id, decision: "deny") } label: {
                        Text("Deny").font(.claude(14, .semibold)).foregroundColor(T.red)
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(T.red.opacity(0.14)))
                    }.buttonStyle(.plain)
                    Button { client.decidePermission(id: p.id, decision: "allow") } label: {
                        Text("Allow").font(.claude(14, .semibold)).foregroundColor(.black)
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(T.green))
                    }.buttonStyle(.plain)
                }
                Button { client.decidePermission(id: p.id, decision: "always") } label: {
                    Text("Always allow this").font(.claude(12, .medium)).foregroundColor(T.accent2)
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.plain)
            }
        }
        .background(RoundedRectangle(cornerRadius: 16).strokeBorder(riskColor.opacity(0.55), lineWidth: 1.2))
    }
    private var riskColor: Color {
        switch p.risk.lowercased() {
        case "danger": return T.red
        case "write":  return T.accent
        default:        return T.accent2
        }
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
                    ForEach(working) { w in
                        NavigationLink {
                            ChatThreadView(sessionId: w.id, project: w.project, cwd: w.cwd)
                        } label: { WorkingRow(w: w) }.buttonStyle(.plain)
                    }
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
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundColor(T.subtext)
            }
            (Text("PROMPT  ").font(.claude(10, .semibold)).foregroundColor(T.subtext)
                + Text("\u{201C}\(w.display)\u{201D}").font(.claude(14)).italic().foregroundColor(T.text.opacity(0.9)))
                .lineLimit(3)
            HStack(spacing: 5) {
                if w.turnTokens == 0 {
                    Text("starting…").font(.claude(12)).foregroundColor(T.subtext)
                    Text("· \(prettyModel(w.model))").font(.claude(11)).foregroundColor(T.subtext)
                } else {
                    Text(fmtTokens(w.turnTokens)).font(.claude(14, .semibold)).foregroundColor(T.text)
                    Text("tokens this turn · \(prettyModel(w.model))").font(.claude(11)).foregroundColor(T.subtext)
                }
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
    @State private var showScanner = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { showScanner = true } label: {
                        Label("Scan QR from your Mac", systemImage: "qrcode.viewfinder")
                    }
                } footer: {
                    Text("On your Mac: EdgePanel menu-bar icon → Pair iPhone…")
                }
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
            .sheet(isPresented: $showScanner) {
                NavigationStack {
                    QRScanner { code in
                        if let c = URLComponents(string: code), c.scheme == "edgepanel" {
                            if let h = c.queryItems?.first(where: { $0.name == "host" })?.value { host = h }
                            if let t = c.queryItems?.first(where: { $0.name == "token" })?.value { token = t }
                        }
                        showScanner = false
                    }
                    .ignoresSafeArea()
                    .navigationTitle("Scan")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showScanner = false } } }
                }
            }
        }
    }
}

func timeStr(_ epoch: Double) -> String {
    let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
    return f.string(from: Date(timeIntervalSince1970: epoch))
}
