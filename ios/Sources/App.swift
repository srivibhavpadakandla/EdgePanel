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

    // While the app is foreground, the in-app cards + Dynamic Island already show every
    // permission / question / "done" event, so suppress the REMOTE APNs duplicate (which iOS
    // would otherwise surface as a second banner the moment the Mac pushes). Local
    // notifications (usage thresholds / forecast — trigger == nil) still banner, since those
    // have no on-screen equivalent. Backgrounded/closed pushes never hit willPresent, so this
    // can't suppress alerts when you actually need them.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        guard notification.request.trigger is UNPushNotificationTrigger else {
            completionHandler([.banner, .sound]); return   // local (usage/forecast) — no on-screen equivalent
        }
        // Remote APNs duplicate: suppress ONLY if the LAN poll already surfaced this exact
        // permission/question in-app. If it hasn't (e.g. the phone is off-LAN so /snapshot
        // never delivered the card), this push is the ONLY actionable surface — let it through.
        let info = notification.request.content.userInfo
        let am = ActivityManager.shared
        if let pid = info["permId"] as? String, pid == am.surfacedPermId || am.wasRecentlySurfaced(perm: pid) {
            completionHandler([]); return
        }
        if let qid = info["questionId"] as? String, qid == am.surfacedQuestionId || am.wasRecentlySurfaced(question: qid) {
            completionHandler([]); return
        }
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
            ChatStore.shared.reconnectInFlight()   // reattach to turns that were running when last killed
        }
        // Reconcile the moment the app returns to the foreground, so a stale "still
        // counting" Live Activity self-heals instantly on open.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, !client.token.isEmpty {
                ActivityManager.shared.resendActivityToken()   // re-arm push end after a Mac restart
                UIApplication.shared.registerForRemoteNotifications()  // re-seed the device token too
                Task { await client.poll() }
                ChatStore.shared.reconnectInFlight()   // resume any in-flight remote turn (iOS suspended its poll)
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
                ScrollView { Dashboard().padding(16).padding(.bottom, 28) }
                    .scrollIndicators(.hidden)
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
                if let q = s.question { QuestionCard(q: q).id(q.id) }   // fresh @State per question (no stale selection leak)
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
    @State private var exactReset = false   // tap → toggle relative ↔ exact reset time
    var body: some View {
        let frac = min(max(plan.fiveHourPct / 100, 0), 1)
        let sev = sevColor(frac)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(Int(plan.fiveHourPct.rounded()))").font(.claude(46, .bold)).foregroundColor(T.text)
                Text("%").font(.claude(24, .bold)).foregroundColor(T.text.opacity(0.55))
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(sev).frame(width: 6, height: 6)
                    Text("5-HOUR").font(.claude(11, .semibold)).tracking(0.8).foregroundColor(T.text.opacity(0.85))
                }
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(Capsule().fill(Color.black.opacity(0.22)))
            }
            Bar(frac: frac, color: sev, height: 11)
            HStack(spacing: 8) {
                if let reset = plan.fiveHourResetEpoch {
                    let rem = max(reset - Date().timeIntervalSince1970, 0)
                    let label = exactReset ? "resets at \(timeStr(reset))" : "resets in \(Int(rem) / 3600)h \((Int(rem) % 3600) / 60)m"
                    Label(label, systemImage: "arrow.clockwise").font(.claude(12.5)).foregroundColor(T.subtext)
                }
                Spacer()
                if let burn = plan.burnPerHour, burn >= 0.5 {
                    let clock = plan.limitClockEpoch.map { "~\(timeStr($0))" }
                    Label("\(clock.map { "\($0) · " } ?? "")+\(Int(burn.rounded()))%/hr", systemImage: "flame.fill")
                        .font(.claude(12.5, .medium)).foregroundColor(plan.limitClockEpoch != nil ? T.red : T.amber)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { exactReset.toggle() } }
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x302720), Color(hex: 0x211C18)], startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [T.accent.opacity(0.30), Color.white.opacity(0.03)],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.42), radius: 13, x: 0, y: 6)
        )
    }
}

struct QuestionCard: View {
    @EnvironmentObject var client: EdgeClient
    let q: EdgeSnapshot.Question
    @State private var sel: [Int: Set<String>] = [:]   // item INDEX → chosen labels (text isn't unique across items)

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    Image(systemName: "questionmark.bubble.fill").foregroundColor(T.accent)
                    Text("Claude is asking").font(.claude(15, .semibold)).foregroundColor(T.text)
                    Spacer()
                    if let p = q.project { Text(p).font(.claude(10)).foregroundColor(T.subtext) }
                }
                ForEach(Array(q.items.enumerated()), id: \.offset) { idx, item in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(item.question).font(.claude(13, .semibold)).foregroundColor(T.text)
                        if item.multiSelect {
                            Text("pick one or more").font(.claude(10)).foregroundColor(T.subtext)
                        }
                        ForEach(item.options, id: \.label) { opt in
                            Button { toggle(idx, item, opt.label) } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: isSel(idx, opt.label)
                                          ? (item.multiSelect ? "checkmark.square.fill" : "checkmark.circle.fill")
                                          : (item.multiSelect ? "square" : "circle"))
                                        .foregroundColor(isSel(idx, opt.label) ? T.accent : T.subtext)
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
                                    .fill(isSel(idx, opt.label) ? T.accent.opacity(0.16) : T.track.opacity(0.5)))
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

    private var answered: Bool { q.items.indices.allSatisfy { !(sel[$0] ?? []).isEmpty } }
    private func isSel(_ idx: Int, _ label: String) -> Bool { (sel[idx] ?? []).contains(label) }
    private func toggle(_ idx: Int, _ item: EdgeSnapshot.Question.Item, _ label: String) {
        var s = sel[idx] ?? []
        if item.multiSelect { if s.contains(label) { s.remove(label) } else { s.insert(label) } }
        else { s = [label] }
        sel[idx] = s
    }
    private func submit() {
        // Internal selection is by index, but the wire answers map stays keyed by question text
        // (the hook contract). Last-writer-wins if two items share text — unavoidable on the wire,
        // but the on-screen selection is now per-item-correct.
        var answers: [String: String] = [:]
        for (idx, item) in q.items.enumerated() {
            let chosen = item.options.map { $0.label }.filter { (sel[idx] ?? []).contains($0) }
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
                        } label: {
                            WorkingRow(w: w)
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(T.green.opacity(0.06)))
                                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(T.green.opacity(0.16), lineWidth: 1))
                        }.buttonStyle(.plain)
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
                PulsingDot()
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
            // Live proof-of-work: subagents running + prompts waiting in line.
            if w.runningAgents > 0 || w.queuedPrompts > 0 {
                HStack(spacing: 7) {
                    if w.runningAgents > 0 {
                        StatusPill(icon: "person.2.fill", text: "\(w.runningAgents) agent\(w.runningAgents == 1 ? "" : "s") working", color: T.green)
                    }
                    if w.queuedPrompts > 0 {
                        StatusPill(icon: "tray.full.fill", text: "\(w.queuedPrompts) queued", color: T.subtext)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// A live "radar ping" dot — solid core + an expanding, fading ring.
struct PulsingDot: View {
    var color: Color = T.green
    @State private var animate = false
    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.4)).frame(width: 9, height: 9)
                .scaleEffect(animate ? 2.6 : 1).opacity(animate ? 0 : 0.7)
            Circle().fill(color).frame(width: 9, height: 9)
        }
        .frame(width: 9, height: 9)
        .animation(.easeOut(duration: 1.5).repeatForever(autoreverses: false), value: animate)
        .onAppear { animate = true }
    }
}

/// Small icon+text capsule for live-status badges (agents working / prompts queued).
struct StatusPill: View {
    let icon: String, text: String, color: Color
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .semibold))
            Text(text).font(.claude(10, .semibold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.15)))
    }
}

struct WeeklyCard: View {
    let plan: EdgeSnapshot.PlanInfo?
    @State private var exactReset = false
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Weekly")
                Text(plan.map { "\(Int($0.weekPct.rounded()))%" } ?? "—").font(.claude(24, .bold)).foregroundColor(T.text)
                Bar(frac: min(max((plan?.weekPct ?? 0) / 100, 0), 1), color: sevColor((plan?.weekPct ?? 0) / 100))
                if let reset = plan?.weekResetEpoch {
                    let rem = max(reset - Date().timeIntervalSince1970, 0)
                    Text(exactReset ? "resets \(dayStr(reset))" : "resets in \(Int(rem) / 86400)d \((Int(rem) % 86400) / 3600)h")
                        .font(.claude(11)).foregroundColor(T.subtext)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { exactReset.toggle() } }
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
                        // Tap → continue the chat ON THE PHONE (loads its real transcript and
                        // resumes it). Long-press → open it in VS Code/Cursor on the Mac.
                        NavigationLink {
                            ChatThreadView(sessionId: c.id, project: c.project, cwd: c.cwd ?? "")
                        } label: {
                            HStack(spacing: 11) {
                                Image(systemName: "bubble.left.and.text.bubble.right")
                                    .font(.system(size: 13)).foregroundColor(T.accent2).frame(width: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(c.name).font(.claude(14, .medium)).foregroundColor(T.text).lineLimit(1)
                                    Text(c.project).font(.claude(11)).foregroundColor(T.subtext).lineLimit(1)
                                }
                                Spacer(minLength: 6)
                                Text(c.lastActive, style: .relative).font(.claude(10)).foregroundColor(T.subtext)
                                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundColor(T.subtext)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { client.openChat(c) } label: { Label("Open in VS Code on Mac", systemImage: "macwindow") }
                        }
                        if c.id != chats.last?.id { Divider().overlay(T.border) }
                    }
                }
            }
        }
    }
}

struct CalendarCard: View {
    let days: [EdgeSnapshot.CalDay]
    @State private var selected: Int?
    var body: some View {
        let map = Dictionary(days.map { ($0.day, $0.tokens) }, uniquingKeysWith: { a, _ in a })   // dup-day-safe
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
                    // Tap a day to see its usage; otherwise the month summary.
                    if let s = selected, let u = map[s] {
                        Text("· \(monthName.prefix(3)) \(s): \(fmtTokens(u)) tokens").font(.claude(13)).foregroundColor(T.text.opacity(0.85))
                    } else if let s = selected {
                        Text("· \(monthName.prefix(3)) \(s): no usage").font(.claude(13)).foregroundColor(T.subtext)
                    } else {
                        Text("of \(today) days").font(.claude(13)).foregroundColor(T.subtext)
                    }
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
        .onChange(of: monthStart) { _, _ in selected = nil }   // month rolled over → clear stale day selection
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
                    .overlay { if day == selected { RoundedRectangle(cornerRadius: 5).strokeBorder(.white, lineWidth: 1.6) } }
                Text("\(day)").font(.claude(10, lvl >= 1 ? .semibold : .regular)).foregroundColor(numColor)
            }
            .frame(maxWidth: .infinity).frame(height: 26)
            .contentShape(Rectangle())
            .onTapGesture { if !future { selected = (selected == day ? nil : day) } }   // tap a day for its usage
        }
    }
}

struct Bar: View {
    let frac: Double; let color: Color
    var height: CGFloat = 10
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(T.track)
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.85), color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, geo.size.width * min(max(frac, 0), 1)))
                    .shadow(color: color.opacity(0.45), radius: 5, y: 1)   // subtle glow on the fill
            }
        }.frame(height: height)
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
func dayStr(_ epoch: Double) -> String {
    Date(timeIntervalSince1970: epoch).formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
}
