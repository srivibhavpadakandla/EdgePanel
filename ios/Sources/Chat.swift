import SwiftUI
import UIKit

// MARK: - Model

struct ChatMessage: Codable, Identifiable {
    enum Role: String, Codable { case user, assistant, error }
    var id = UUID()
    var role: Role
    var text: String
    var at = Date()
}

/// A chat thread = a REAL Claude Code session (keyed by its session id). You only
/// chat in sessions that are actually running on your Mac; we load their true
/// transcript history and continue them with `claude --resume`.
struct ChatThread: Codable, Identifiable {
    var id: String              // stable UI key (for existing sessions, == the session id)
    var sessionId: String?      // real Claude session to --resume (adopted for new tasks)
    var project: String
    var cwd: String
    var messages: [ChatMessage] = []
    var updatedAt = Date()
    /// What to pass as --resume; nil = start a fresh session (a new task not yet adopted).
    var resumeId: String? { sessionId ?? (id.hasPrefix("new-") ? nil : id) }
}

@MainActor
final class ChatStore: ObservableObject {
    static let shared = ChatStore()
    @Published var threads: [ChatThread] = []
    @Published var busy: Set<String> = []        // thread ids awaiting a reply
    @Published var busyJob: [String: String] = [:]   // thread id → running jobId (for Stop)

    private let url: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chats.json")
    }()
    init() { load() }

    func thread(_ id: String) -> ChatThread? { threads.first { $0.id == id } }

    /// Open (or create) the thread for a real session and pull its live history
    /// from the Mac so you see the conversation that's on your PC.
    func open(sessionId: String, project: String, cwd: String) {
        if let i = threads.firstIndex(where: { $0.id == sessionId }) {
            threads[i].project = project
            if !cwd.isEmpty { threads[i].cwd = cwd }
            if threads[i].sessionId == nil, !sessionId.hasPrefix("new-") { threads[i].sessionId = sessionId }
        } else if !sessionId.hasPrefix("new-") {   // never create a thread keyed by a temp id
            threads.insert(ChatThread(id: sessionId, sessionId: sessionId, project: project, cwd: cwd), at: 0)
        }
        save()
        refreshHistory(sessionId)
    }

    /// Replace the thread's messages with the real transcript (the source of truth
    /// — includes turns you ran on the PC and from the phone). Skipped while a reply
    /// is in flight so we don't clobber the optimistic bubbles.
    func refreshHistory(_ threadId: String) {
        guard let t = thread(threadId), let resume = t.resumeId else { return }   // new task not yet adopted → no history
        let cwd = t.cwd
        Task {
            let hist = await EdgeClient.shared.fetchHistory(sessionId: resume, cwd: cwd)
            guard !hist.isEmpty, !busy.contains(threadId),
                  let i = threads.firstIndex(where: { $0.id == threadId }) else { return }
            threads[i].messages = hist.map {
                ChatMessage(role: $0.role == "assistant" ? .assistant : .user, text: $0.text)
            }
            save()
        }
    }

    func send(_ threadId: String, _ text: String) {
        guard let i = threads.firstIndex(where: { $0.id == threadId }) else { return }
        threads[i].messages.append(ChatMessage(role: .user, text: text))
        threads[i].updatedAt = Date()
        let cwd = threads[i].cwd, resume = threads[i].resumeId   // capture before the sort changes indices
        threads.sort { $0.updatedAt > $1.updatedAt }             // float this thread to the top now, not only on completion
        busy.insert(threadId); save()

        Task {
            guard let jobId = await EdgeClient.shared.sendChat(cwd: cwd, sessionId: resume, message: text) else {
                finish(threadId, .error, "Couldn’t reach your Mac — is EdgePanel running?"); return
            }
            busyJob[threadId] = jobId
            await streamJob(jobId, into: threadId)
        }
    }

    /// Stop the running turn — terminates the `claude` process on the Mac.
    func stop(_ id: String) {
        if let job = busyJob[id] { EdgeClient.shared.cancelChat(jobId: job) }
    }

    /// Start a BRAND-NEW autonomous task in `cwd`. The thread keeps a stable id and
    /// adopts the real Claude session id (into `sessionId`) the moment the Mac reports
    /// it, so the next turn resumes the same session — without re-keying an open view.
    @discardableResult
    func startNewTask(cwd: String, project: String, _ text: String) -> String {
        let tempId = "new-" + UUID().uuidString
        var t = ChatThread(id: tempId, project: project, cwd: cwd)
        t.messages.append(ChatMessage(role: .user, text: text))
        threads.insert(t, at: 0)
        busy.insert(tempId); save()

        Task {
            guard let jobId = await EdgeClient.shared.sendChat(cwd: cwd, sessionId: nil, message: text) else {
                finish(tempId, .error, "Couldn’t reach your Mac — is EdgePanel running?"); return
            }
            busyJob[tempId] = jobId
            await streamJob(jobId, into: tempId)
        }
        return tempId
    }

    /// Shared streaming poll loop: render the reply token-by-token, adopt the real
    /// session id when it appears, and settle on done/error.
    private func streamJob(_ jobId: String, into threadId: String) async {
        var streamId: UUID?, fails = 0
        for _ in 0..<1400 {                       // ~12 min at 0.5s
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let job = await EdgeClient.shared.pollChat(jobId) else {
                fails += 1                        // unreachable Mac → don't hang busy forever
                if fails >= 20 { finalize(threadId, streamId, "Lost connection to your Mac.", .error); busyJob[threadId] = nil; return }
                continue
            }
            fails = 0
            if let sid = job.sessionId, !sid.isEmpty { adopt(threadId, sessionId: sid) }
            if job.status == "running" {
                if let partial = job.result, !partial.isEmpty { streamId = upsertStream(threadId, streamId, partial) }
                continue
            }
            if job.status == "done" {
                finalize(threadId, streamId, job.result ?? "(no reply)", .assistant); busyJob[threadId] = nil; return
            }
            if job.status == "error" {
                finalize(threadId, streamId, job.error ?? "Something went wrong.", .error); busyJob[threadId] = nil; return
            }
        }
        finalize(threadId, streamId, "Timed out waiting for a reply.", .error); busyJob[threadId] = nil
    }

    private func adopt(_ threadId: String, sessionId: String) {
        guard let i = threads.firstIndex(where: { $0.id == threadId }), threads[i].sessionId != sessionId else { return }
        threads[i].sessionId = sessionId; save()
    }

    /// Create-or-update the in-progress assistant bubble with the latest streamed text.
    @discardableResult
    private func upsertStream(_ sessionId: String, _ existing: UUID?, _ text: String) -> UUID {
        guard let i = threads.firstIndex(where: { $0.id == sessionId }) else { return existing ?? UUID() }
        if let id = existing, let mi = threads[i].messages.firstIndex(where: { $0.id == id }) {
            threads[i].messages[mi].text = text
            return id
        }
        let m = ChatMessage(role: .assistant, text: text)
        threads[i].messages.append(m)
        return m.id
    }

    /// Settle the streaming bubble (or append a fresh one if nothing streamed) with the final text.
    private func finalize(_ id: String, _ streamId: UUID?, _ text: String, _ role: ChatMessage.Role) {
        if let i = threads.firstIndex(where: { $0.id == id }) {
            if let sid = streamId, let mi = threads[i].messages.firstIndex(where: { $0.id == sid }) {
                threads[i].messages[mi].text = text
                threads[i].messages[mi].role = role
            } else {
                threads[i].messages.append(ChatMessage(role: role, text: text))
            }
            threads[i].updatedAt = Date()
            threads.sort { $0.updatedAt > $1.updatedAt }
        }
        busy.remove(id); busyJob[id] = nil; save()
    }

    private func finish(_ id: String, _ role: ChatMessage.Role, _ text: String) {
        finalize(id, nil, text, role)
    }
    func delete(_ id: String) { threads.removeAll { $0.id == id }; busy.remove(id); save() }

    private var pendingSave: Task<Void, Never>?
    /// Debounced, off-main persistence — was a synchronous main-actor disk write on every
    /// streamed token (a write storm). Coalesce: capture state now, write ~0.6s later.
    private func save() {
        pendingSave?.cancel()
        let snapshot = threads, u = url
        pendingSave = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 600_000_000)
            if Task.isCancelled { return }
            try? JSONEncoder().encode(snapshot).write(to: u)
        }
    }
    private func load() {
        if let d = try? Data(contentsOf: url), let t = try? JSONDecoder().decode([ChatThread].self, from: d) {
            threads = t.sorted { $0.updatedAt > $1.updatedAt }
        }
    }
}

// MARK: - Chat tab = saved history of the sessions you've worked in

struct ChatListView: View {
    @ObservedObject private var store = ChatStore.shared
    @EnvironmentObject var client: EdgeClient
    @State private var showNew = false
    @State private var showPanic = false
    @State private var openId: String?
    var body: some View {
        NavigationStack {
            ZStack {
                T.bg.ignoresSafeArea()
                if store.threads.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 34)).foregroundColor(T.accent2)
                        Text("Drive Claude Code from here").font(.claude(15, .semibold)).foregroundColor(T.text)
                        Text("Tap ＋ to start a new task in any project on your Mac — it runs autonomously and streams back here. Or open a session from WORKING NOW on the Usage tab.")
                            .font(.claude(12)).foregroundColor(T.subtext).multilineTextAlignment(.center).padding(.horizontal, 34)
                        Button { showNew = true } label: {
                            Label("New Task", systemImage: "plus.circle.fill").font(.claude(14, .semibold))
                        }.buttonStyle(.borderedProminent).tint(T.accent).padding(.top, 4)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(store.threads) { t in
                                NavigationLink {
                                    ChatThreadView(sessionId: t.id, project: t.project, cwd: t.cwd)
                                } label: { ThreadRow(t: t, busy: store.busy.contains(t.id)) }
                                    .buttonStyle(.plain)
                            }
                        }.padding(16)
                    }
                }
            }
            .navigationTitle("Command")
            .confirmationDialog("Stop everything?", isPresented: $showPanic, titleVisibility: .visible) {
                Button("Stop all & disarm", role: .destructive) { client.panic() }
            } message: { Text("Kills every running task, turns Autonomous off, and denies pending permissions.") }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { AutonomyToggle().environmentObject(client) }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        Button(role: .destructive) { showPanic = true } label: {
                            Image(systemName: "exclamationmark.octagon.fill").font(.system(size: 18)).foregroundColor(T.red)
                        }
                        Button { showNew = true } label: { Image(systemName: "plus.circle.fill").font(.system(size: 19, weight: .semibold)) }
                    }
                }
            }
            .navigationDestination(item: $openId) { id in
                ChatThreadView(sessionId: id, project: store.thread(id)?.project ?? "Task", cwd: store.thread(id)?.cwd ?? "")
            }
        }
        .tint(T.accent)
        .sheet(isPresented: $showNew) {
            // Dismiss the sheet first, then push the new thread (avoids a present/push race).
            NewTaskSheet { id in
                showNew = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { openId = id }
            }.environmentObject(client)
        }
    }
}

/// Toolbar control for Autonomous (auto-approve) mode — flip it on and the Mac
/// auto-allows every permission so work runs hands-off.
private struct AutonomyToggle: View {
    @EnvironmentObject var client: EdgeClient
    @State private var pending: Bool?      // optimistic flip until the snapshot reconciles
    private var on: Bool { pending ?? client.snapshot?.autoApprove ?? false }
    var body: some View {
        Button {
            let next = !on; pending = next; client.setAutoApprove(next)   // flip instantly
        } label: {
            HStack(spacing: 5) {
                Image(systemName: on ? "bolt.fill" : "bolt.slash.fill")
                Text(on ? "Autonomous" : "Manual").font(.claude(12, .semibold))
            }
            .foregroundColor(on ? T.accent : T.subtext)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Capsule().fill(on ? T.accent.opacity(0.15) : T.track))
        }
        .onChange(of: client.snapshot?.autoApprove) { _, v in if v == pending { pending = nil } }
    }
}

/// Start a brand-new autonomous task: pick a project on the Mac + describe the task.
struct NewTaskSheet: View {
    @EnvironmentObject var client: EdgeClient
    @Environment(\.dismiss) private var dismiss
    var onStart: (String) -> Void
    @State private var projects: [EdgeClient.Project] = []
    @State private var picked: EdgeClient.Project?
    @State private var task = ""
    @FocusState private var focused: Bool

    private var canStart: Bool { picked != nil && !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            ZStack {
                T.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("PROJECT").font(.claude(11, .semibold)).foregroundColor(T.subtext)
                        if projects.isEmpty {
                            HStack { ProgressView().tint(T.accent); Text("Loading projects…").font(.claude(12)).foregroundColor(T.subtext) }
                        }
                        ForEach(projects) { p in
                            Button { picked = p } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: picked == p ? "checkmark.circle.fill" : "folder")
                                        .foregroundColor(picked == p ? T.accent : T.subtext)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(p.name).font(.claude(14, .semibold)).foregroundColor(T.text).lineLimit(1)
                                        Text(p.cwd).font(.claude(10)).foregroundColor(T.subtext).lineLimit(1)
                                    }
                                    Spacer(minLength: 4)
                                }
                                .padding(11)
                                .background(RoundedRectangle(cornerRadius: 11).fill(picked == p ? T.accent.opacity(0.13) : T.track))
                            }.buttonStyle(.plain)
                        }
                        Text("TASK").font(.claude(11, .semibold)).foregroundColor(T.subtext).padding(.top, 6)
                        TextField("What should Claude Code do?", text: $task, axis: .vertical)
                            .focused($focused).lineLimit(3...10)
                            .padding(12).background(RoundedRectangle(cornerRadius: 12).fill(T.track)).foregroundColor(T.text)
                        Text("Runs with full autonomy (permissions bypassed) and streams the reply into a new chat.")
                            .font(.claude(11)).foregroundColor(T.subtext)
                    }.padding(16)
                }
            }
            .navigationTitle("New Task").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        guard let p = picked else { return }
                        let t = task.trimmingCharacters(in: .whitespacesAndNewlines)
                        onStart(ChatStore.shared.startNewTask(cwd: p.cwd, project: p.name, t))
                    }.disabled(!canStart)
                }
            }
            .task { projects = await client.fetchProjects(); if picked == nil { picked = projects.first } }
        }
        .tint(T.accent)
    }
}

private struct ThreadRow: View {
    let t: ChatThread
    let busy: Bool
    var body: some View {
        Card {
            HStack(spacing: 11) {
                Image(systemName: "bubble.left.and.text.bubble.right").foregroundColor(T.accent2).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.project).font(.claude(15, .semibold)).foregroundColor(T.text).lineLimit(1)
                    Text(t.messages.last?.text ?? "—").font(.claude(11)).foregroundColor(T.subtext).lineLimit(1)
                }
                Spacer(minLength: 6)
                if busy { ProgressView().tint(T.accent) }
                else { Text(t.updatedAt, style: .relative).font(.claude(10)).foregroundColor(T.subtext) }
            }
        }
    }
}

// MARK: - One thread (a real session), claude.ai-style

struct ChatThreadView: View {
    @ObservedObject private var store = ChatStore.shared
    let sessionId: String
    let project: String
    let cwd: String
    @State private var draft = ""
    @State private var atBottom = true
    @FocusState private var focused: Bool

    private var thread: ChatThread? { store.thread(sessionId) }
    private var busy: Bool { store.busy.contains(sessionId) }
    private var messages: [ChatMessage] { thread?.messages ?? [] }
    private var thinking: Bool { busy && messages.last?.role == .user }   // sent, nothing back yet

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            T.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(messages) { m in
                                MessageView(message: m, streaming: busy && m.id == messages.last?.id && m.role == .assistant)
                                    .id(m.id)
                            }
                            if thinking { ThinkingRow().id("thinking") }
                            Color.clear.frame(height: 1).id("bottom")
                                .onAppear { atBottom = true }.onDisappear { atBottom = false }
                        }
                        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: messages.last?.text) { _, _ in if atBottom { scrollToBottom(proxy) } }
                    .onChange(of: messages.count) { _, _ in scrollToBottom(proxy) }
                    .onChange(of: thinking) { _, t in if t { scrollToBottom(proxy) } }
                    .overlay(alignment: .bottomTrailing) {
                        if !atBottom && !messages.isEmpty {
                            Button { withAnimation { scrollToBottom(proxy) } } label: {
                                Image(systemName: "arrow.down").font(.system(size: 14, weight: .bold))
                                    .foregroundColor(T.text).padding(10)
                                    .background(Circle().fill(T.card)).overlay(Circle().stroke(T.border, lineWidth: 1))
                                    .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                            }.padding(.trailing, 14).padding(.bottom, 8)
                        }
                    }
                }
                composer
            }
        }
        .navigationTitle(project)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if store.thread(sessionId) == nil { store.open(sessionId: sessionId, project: project, cwd: cwd) }
            else { store.refreshHistory(sessionId) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) { proxy.scrollTo("bottom", anchor: .bottom) }

    private var composer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(T.border).frame(height: 1)
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Reply to Claude…", text: $draft, axis: .vertical)
                    .font(.claude(15.5)).foregroundColor(T.text)
                    .focused($focused).lineLimit(1...6)
                    .padding(.horizontal, 15).padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 22).fill(T.card))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(T.border, lineWidth: 1))
                if busy {
                    Button { store.stop(sessionId) } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 32)).foregroundColor(T.red)
                    }.transition(.scale)
                } else {
                    Button { send() } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                            .foregroundColor(draft.trimmingCharacters(in: .whitespaces).isEmpty ? T.subtext : T.accent)
                    }.disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
        }
        .background(T.bg)
        .animation(.easeInOut(duration: 0.15), value: busy)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.send(sessionId, text); draft = ""; focused = false
    }
}

// MARK: - One message (user bubble vs. document-style assistant turn)

private struct MessageView: View {
    let message: ChatMessage
    let streaming: Bool
    var body: some View {
        switch message.role {
        case .user:
            HStack { Spacer(minLength: 44)
                Text(message.text).font(.claude(15.5)).foregroundColor(T.bg)
                    .padding(.horizontal, 15).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(T.accent))
                    .textSelection(.enabled)
            }
        case .error:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundColor(T.red)
                Text(message.text).font(.claude(14)).foregroundColor(T.red)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(T.red.opacity(0.10)))
        case .assistant:
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Image(systemName: "bird.fill").font(.system(size: 11)).foregroundColor(T.accent)
                    Text("Claude").font(.claude(11, .semibold)).tracking(0.4).foregroundColor(T.subtext)
                    if streaming { BlinkingCursor() }
                }
                if message.text.isEmpty && streaming {
                    ThinkingDots()
                } else {
                    MarkdownView(text: message.text)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contextMenu {
                Button { UIPasteboard.general.string = message.text } label: { Label("Copy", systemImage: "doc.on.doc") }
            }
        }
    }
}

private struct ThinkingRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "bird.fill").font(.system(size: 11)).foregroundColor(T.accent)
                Text("Claude").font(.claude(11, .semibold)).tracking(0.4).foregroundColor(T.subtext)
            }
            ThinkingDots()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Markdown renderer (block-level)

private enum MDBlock { case heading(Int, String), paragraph(String), bullets([String]),
                       numbered([(String, String)]), code(String, String), quote(String), rule, tool(String) }

private struct MarkdownView: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let blocks = parseMarkdown(text)
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                block(b)
            }
        }
    }

    @ViewBuilder private func block(_ b: MDBlock) -> some View {
        switch b {
        case .heading(let lvl, let t):
            let size: CGFloat = lvl == 1 ? 20 : lvl == 2 ? 17.5 : 15.5
            Text(inlineMD(t, size: size, weight: .bold)).foregroundColor(T.text)
                .padding(.top, 3).fixedSize(horizontal: false, vertical: true)
        case .paragraph(let t):
            Text(inlineMD(t)).foregroundColor(T.text).lineSpacing(3.5)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text("•").font(.claude(15)).foregroundColor(T.accent)
                        Text(inlineMD(it)).foregroundColor(T.text).lineSpacing(2.5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .numbered(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text(it.0 + ".").font(.claude(14.5, .semibold)).foregroundColor(T.accent)
                            .frame(minWidth: 19, alignment: .trailing)
                        Text(inlineMD(it.1)).foregroundColor(T.text).lineSpacing(2.5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .code(let lang, let body):
            CodeBlock(lang: lang, code: body)
        case .quote(let t):
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2).fill(T.accent.opacity(0.55)).frame(width: 3)
                Text(inlineMD(t)).foregroundColor(T.subtext).italic().lineSpacing(2.5)
                    .padding(.leading, 11).fixedSize(horizontal: false, vertical: true)
            }
        case .rule:
            Rectangle().fill(T.border).frame(height: 1).padding(.vertical, 4)
        case .tool(let name):
            HStack(spacing: 6) {
                Image(systemName: toolIcon(name)).font(.system(size: 11, weight: .medium))
                Text(toolLabel(name)).font(.claude(12.5))
            }
            .foregroundColor(T.subtext)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(T.card)).overlay(Capsule().stroke(T.border, lineWidth: 1))
        }
    }
}

private struct CodeBlock: View {
    let lang: String
    let code: String
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(lang.isEmpty ? "code" : lang).font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(T.subtext)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium)).foregroundColor(copied ? T.green : T.subtext)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Color.black.opacity(0.22))
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(size: 12.5, design: .monospaced)).foregroundColor(T.text)
                    .textSelection(.enabled).padding(12)
            }
        }
        .background(Color.black.opacity(0.32))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(T.border, lineWidth: 1))
    }
}

// MARK: - markdown parsing helpers

/// Memoize the last few parses so SwiftUI's redundant re-renders of the same message
/// text (common during streaming) don't re-parse. Body runs on the main thread only,
/// so this static cache is race-free.
private enum MDMemo { static var cache: [(text: String, blocks: [MDBlock])] = [] }

private func parseMarkdown(_ text: String) -> [MDBlock] {
    if let hit = MDMemo.cache.first(where: { $0.text == text }) { return hit.blocks }
    var blocks: [MDBlock] = []
    let lines = text.components(separatedBy: "\n")
    var i = 0
    func trimmed(_ n: Int) -> String { lines[n].trimmingCharacters(in: .whitespaces) }
    while i < lines.count {
        let line = trimmed(i)
        if line.hasPrefix("```") {                                   // fenced code (robust to unclosed during streaming)
            let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            var body: [String] = []; i += 1
            while i < lines.count && !trimmed(i).hasPrefix("```") { body.append(lines[i]); i += 1 }
            i += 1
            blocks.append(.code(lang, body.joined(separator: "\n"))); continue
        }
        if line.hasPrefix("⚙ ") {                                    // tool marker from the Mac stream
            blocks.append(.tool(String(line.dropFirst(2)).replacingOccurrences(of: "…", with: "").trimmingCharacters(in: .whitespaces)))
            i += 1; continue
        }
        if line == "---" || line == "***" || line == "___" { blocks.append(.rule); i += 1; continue }
        if line.hasPrefix("#") {                                      // heading
            let hashes = line.prefix(while: { $0 == "#" }).count
            if hashes <= 6 && line.dropFirst(hashes).hasPrefix(" ") {
                blocks.append(.heading(min(hashes, 3), String(line.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)))
                i += 1; continue
            }
        }
        if line.hasPrefix(">") {                                      // blockquote
            var q: [String] = []
            while i < lines.count && trimmed(i).hasPrefix(">") {
                q.append(String(trimmed(i).dropFirst()).trimmingCharacters(in: .whitespaces)); i += 1
            }
            blocks.append(.quote(q.joined(separator: "\n"))); continue
        }
        if isBullet(line) {                                           // bullet list
            var items: [String] = []
            while i < lines.count && isBullet(trimmed(i)) { items.append(bulletText(trimmed(i))); i += 1 }
            blocks.append(.bullets(items)); continue
        }
        if numbered(line) != nil {                                    // numbered list
            var items: [(String, String)] = []
            while i < lines.count, let n = numbered(trimmed(i)) { items.append(n); i += 1 }
            blocks.append(.numbered(items)); continue
        }
        if line.isEmpty { i += 1; continue }
        var para: [String] = []                                       // paragraph (gather until a special line/blank)
        while i < lines.count {
            let l = trimmed(i)
            if l.isEmpty || l.hasPrefix("```") || l.hasPrefix("#") || l.hasPrefix(">") || l.hasPrefix("⚙ ")
                || isBullet(l) || numbered(l) != nil || l == "---" || l == "***" || l == "___" { break }
            para.append(lines[i]); i += 1
        }
        if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))) }
    }
    MDMemo.cache.append((text, blocks))
    if MDMemo.cache.count > 4 { MDMemo.cache.removeFirst() }   // small LRU across visible messages
    return blocks
}

private func isBullet(_ s: String) -> Bool {
    (s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("+ ")) && s.count > 2
}
private func bulletText(_ s: String) -> String { String(s.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
private func numbered(_ s: String) -> (String, String)? {
    let digits = s.prefix(while: { $0.isNumber })
    guard !digits.isEmpty, digits.count <= 3 else { return nil }
    let rest = s.dropFirst(digits.count)
    guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
    return (String(digits), String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces))
}

private func inlineMD(_ s: String, size: CGFloat = 15.5, weight: Font.Weight = .regular) -> AttributedString {
    var a = (try? AttributedString(markdown: s, options: .init(
        interpretedSyntax: .inlineOnlyPreservingWhitespace,
        failurePolicy: .returnPartiallyParsedIfPossible))) ?? AttributedString(s)
    a.font = .claude(size, weight)
    for run in a.runs {
        if run.inlinePresentationIntent?.contains(.code) == true {
            a[run.range].font = .system(size: size - 1.5, design: .monospaced)
            a[run.range].foregroundColor = T.accent
        } else if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
            a[run.range].font = .claude(size, .bold)
        }
        if run.link != nil { a[run.range].foregroundColor = T.accent; a[run.range].underlineStyle = .single }
    }
    return a
}

private func toolIcon(_ name: String) -> String {
    let n = name.lowercased()
    if n.contains("bash") || n.contains("shell") { return "terminal" }
    if n.contains("edit") || n.contains("write") { return "pencil" }
    if n.contains("read") { return "doc.text" }
    if n.contains("grep") || n.contains("glob") || n.contains("search") { return "magnifyingglass" }
    if n.contains("web") || n.contains("fetch") { return "globe" }
    if n.contains("task") || n.contains("agent") { return "sparkles" }
    return "gearshape"
}
private func toolLabel(_ name: String) -> String {
    let n = name.lowercased()
    if n.contains("bash") { return "Ran a command" }
    if n.contains("edit") || n.contains("write") { return "Edited a file" }
    if n.contains("read") { return "Read a file" }
    if n.contains("grep") || n.contains("glob") || n.contains("search") { return "Searched the code" }
    if n.contains("web") || n.contains("fetch") { return "Browsed the web" }
    return "Used \(name)"
}

// MARK: - streaming indicators

private struct BlinkingCursor: View {
    @State private var on = true
    var body: some View {
        RoundedRectangle(cornerRadius: 1).fill(T.accent).frame(width: 7, height: 11)
            .opacity(on ? 1 : 0.15)
            .onAppear { withAnimation(.easeInOut(duration: 0.55).repeatForever()) { on.toggle() } }
    }
}

private struct ThinkingDots: View {
    @State private var phase = 0.0
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle().fill(T.subtext).frame(width: 7, height: 7)
                    .opacity(0.3 + 0.7 * abs(sin(phase + Double(i) * 0.5)))
            }
        }
        .onAppear { withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) { phase = .pi * 2 } }
    }
}
