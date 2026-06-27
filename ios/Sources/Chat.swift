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
    var id: String              // = session id
    var project: String
    var cwd: String
    var messages: [ChatMessage] = []
    var updatedAt = Date()
}

@MainActor
final class ChatStore: ObservableObject {
    static let shared = ChatStore()
    @Published var threads: [ChatThread] = []
    @Published var busy: Set<String> = []        // session ids awaiting a reply

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
        } else {
            threads.insert(ChatThread(id: sessionId, project: project, cwd: cwd), at: 0)
        }
        save()
        refreshHistory(sessionId)
    }

    /// Replace the thread's messages with the real transcript (the source of truth
    /// — includes turns you ran on the PC and from the phone). Skipped while a reply
    /// is in flight so we don't clobber the optimistic bubbles.
    func refreshHistory(_ sessionId: String) {
        guard let t = thread(sessionId) else { return }
        let cwd = t.cwd
        Task {
            let hist = await EdgeClient.shared.fetchHistory(sessionId: sessionId, cwd: cwd)
            guard !hist.isEmpty, !busy.contains(sessionId),
                  let i = threads.firstIndex(where: { $0.id == sessionId }) else { return }
            threads[i].messages = hist.map {
                ChatMessage(role: $0.role == "assistant" ? .assistant : .user, text: $0.text)
            }
            save()
        }
    }

    func send(_ sessionId: String, _ text: String) {
        guard let i = threads.firstIndex(where: { $0.id == sessionId }) else { return }
        threads[i].messages.append(ChatMessage(role: .user, text: text))
        threads[i].updatedAt = Date()
        busy.insert(sessionId); save()
        let cwd = threads[i].cwd

        Task {
            guard let jobId = await EdgeClient.shared.sendChat(cwd: cwd, sessionId: sessionId, message: text) else {
                finish(sessionId, .error, "Couldn’t reach your Mac — is EdgePanel running?"); return
            }
            // Poll fast and render the reply token-by-token as the Mac streams it.
            var streamId: UUID?
            for _ in 0..<1400 {                   // ~12 min at 0.5s
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let job = await EdgeClient.shared.pollChat(jobId) else { continue }
                if job.status == "running" {
                    if let partial = job.result, !partial.isEmpty {
                        streamId = upsertStream(sessionId, streamId, partial)
                    }
                    continue
                }
                if job.status == "done" {
                    finalize(sessionId, streamId, job.result ?? "(no reply)", .assistant); return
                }
                if job.status == "error" {
                    finalize(sessionId, streamId, job.error ?? "Something went wrong.", .error); return
                }
            }
            finalize(sessionId, streamId, "Timed out waiting for a reply.", .error)
        }
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
        busy.remove(id); save()
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
    var body: some View {
        NavigationStack {
            ZStack {
                T.bg.ignoresSafeArea()
                if store.threads.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 34)).foregroundColor(T.accent2)
                        Text("No chats yet").font(.claude(15, .semibold)).foregroundColor(T.text)
                        Text("Open a chat from WORKING NOW on the Usage tab to talk to a session running on your Mac. It’ll be saved here so you can go back to it.")
                            .font(.claude(12)).foregroundColor(T.subtext).multilineTextAlignment(.center).padding(.horizontal, 36)
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
            .navigationTitle("Chats")
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
        .onAppear { store.open(sessionId: sessionId, project: project, cwd: cwd) }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Message this chat…", text: $draft, axis: .vertical)
                .focused($focused).lineLimit(1...5)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 18).fill(T.track))
                .foregroundColor(T.text)
            Button {
                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, !busy else { return }
                store.send(sessionId, text); draft = ""; focused = false
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                    .foregroundColor(draft.isEmpty || busy ? T.subtext : T.accent)
            }.disabled(draft.isEmpty || busy)
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
