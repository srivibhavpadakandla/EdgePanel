import SwiftUI

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
    @Published var busy: Set<String> = []        // session ids awaiting a reply
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
        busy.insert(threadId); save()
        let cwd = threads[i].cwd, resume = threads[i].resumeId

        Task {
            guard let jobId = await EdgeClient.shared.sendChat(cwd: cwd, sessionId: resume, message: text) else {
                finish(threadId, .error, "Couldn’t reach your Mac — is EdgePanel running?"); return
            }
            busyJob[threadId] = jobId
            await streamJob(jobId, into: threadId)
        }
    }

    /// Stop the running turn for a thread (terminates `claude` on the Mac).
    func stop(_ id: String) {
        guard let job = busyJob[id] else { return }
        EdgeClient.shared.cancelChat(jobId: job)
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
        var streamId: UUID?
        for _ in 0..<1400 {                       // ~12 min at 0.5s
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let job = await EdgeClient.shared.pollChat(jobId) else { continue }
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

    private func save() { try? JSONEncoder().encode(threads).write(to: url) }
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
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { AutonomyToggle().environmentObject(client) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNew = true } label: { Image(systemName: "plus.circle.fill").font(.system(size: 19, weight: .semibold)) }
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
    private var on: Bool { client.snapshot?.autoApprove ?? false }
    var body: some View {
        Button { client.setAutoApprove(!on) } label: {
            HStack(spacing: 5) {
                Image(systemName: on ? "bolt.fill" : "bolt.slash.fill")
                Text(on ? "Autonomous" : "Manual").font(.claude(12, .semibold))
            }
            .foregroundColor(on ? T.accent : T.subtext)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Capsule().fill(on ? T.accent.opacity(0.15) : T.track))
        }
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

// MARK: - One thread (real session)

struct ChatThreadView: View {
    @ObservedObject private var store = ChatStore.shared
    let sessionId: String
    let project: String
    let cwd: String
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var thread: ChatThread? { store.thread(sessionId) }
    private var busy: Bool { store.busy.contains(sessionId) }

    var body: some View {
        ZStack {
            T.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(thread?.messages ?? []) { Bubble(m: $0) }
                            // Dots only until the streamed reply starts arriving (then the
                            // growing assistant bubble is the live indicator).
                            if busy && thread?.messages.last?.role == .user { TypingDots().id("typing") }
                        }.padding(14)
                    }
                    .onChange(of: thread?.messages.count ?? 0) { _, _ in
                        if let last = thread?.messages.last?.id { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
                    }
                    .onChange(of: busy) { _, b in if b { withAnimation { proxy.scrollTo("typing", anchor: .bottom) } } }
                }
                composer
            }
        }
        .navigationTitle(project)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // New WORKING NOW session → create + load history; an existing thread (incl. a
            // new task that has adopted its real session id) → just refresh its history.
            if store.thread(sessionId) == nil { store.open(sessionId: sessionId, project: project, cwd: cwd) }
            else { store.refreshHistory(sessionId) }
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Message this chat…", text: $draft, axis: .vertical)
                .focused($focused).lineLimit(1...5)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 18).fill(T.track))
                .foregroundColor(T.text)
            if busy {
                Button { store.stop(sessionId) } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 30)).foregroundColor(T.red)
                }
            } else {
                Button {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    store.send(sessionId, text); draft = ""; focused = false
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                        .foregroundColor(draft.isEmpty ? T.subtext : T.accent)
                }.disabled(draft.isEmpty)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(T.bg)
    }
}

private struct Bubble: View {
    let m: ChatMessage
    var body: some View {
        HStack {
            if m.role == .user { Spacer(minLength: 40) }
            Group {
                if m.role == .assistant {
                    MarkdownText(text: m.text)                 // code blocks + inline formatting
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(m.text).font(.claude(14)).foregroundColor(color).textSelection(.enabled)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 14).fill(bg))
            if m.role != .user { Spacer(minLength: 40) }
        }
    }
    private var color: Color { m.role == .user ? .black : (m.role == .error ? T.red : T.text) }
    private var bg: Color { m.role == .user ? T.accent : (m.role == .error ? T.red.opacity(0.14) : T.track) }
}

/// Lightweight markdown for chat replies: fenced ``` code blocks render in a mono
/// box (horizontally scrollable); everything else renders with inline markdown
/// (bold/italic/`code`/links) while preserving line breaks. Robust to a half-streamed
/// code fence (an unclosed ``` just renders the tail as code).
private struct MarkdownText: View {
    let text: String
    private enum Seg: Identifiable { case text(String), code(String); var id: String { switch self { case .text(let t): return "t"+t; case .code(let c): return "c"+c } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(segments().enumerated()), id: \.offset) { _, seg in
                switch seg {
                case .code(let code):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code).font(.system(size: 12.5, weight: .regular, design: .monospaced))
                            .foregroundColor(T.text).textSelection(.enabled)
                            .padding(10)
                    }
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.30)))
                case .text(let md):
                    Text(inline(md)).font(.claude(14)).foregroundColor(T.text).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func segments() -> [Seg] {
        let parts = text.components(separatedBy: "```")
        var out: [Seg] = []
        for (i, part) in parts.enumerated() {
            if i % 2 == 1 {
                var code = part
                // drop an optional language hint on the fence's first line
                if let nl = code.firstIndex(of: "\n") {
                    let lang = code[code.startIndex..<nl].trimmingCharacters(in: .whitespaces)
                    if lang.count < 16 && !lang.contains(" ") { code = String(code[code.index(after: nl)...]) }
                }
                let c = code.trimmingCharacters(in: .newlines)
                if !c.isEmpty { out.append(.code(c)) }
            } else {
                let t = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(.text(t)) }
            }
        }
        return out.isEmpty ? [.text(text)] : out
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

private struct TypingDots: View {
    @State private var on = false
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle().fill(T.subtext).frame(width: 7, height: 7).opacity(on ? 1 : 0.3)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.2), value: on)
            }
            Spacer()
        }.onAppear { on = true }
    }
}
