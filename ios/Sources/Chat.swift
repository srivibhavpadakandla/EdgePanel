import SwiftUI

// MARK: - Model

struct ChatMessage: Codable, Identifiable {
    enum Role: String, Codable { case user, assistant, error }
    var id = UUID()
    var role: Role
    var text: String
    var at = Date()
}

struct ChatThread: Codable, Identifiable {
    var id = UUID()
    var title: String
    var project: String
    var cwd: String
    var sessionId: String?
    var messages: [ChatMessage] = []
    var updatedAt = Date()
}

@MainActor
final class ChatStore: ObservableObject {
    static let shared = ChatStore()
    @Published var threads: [ChatThread] = []
    @Published var busy: Set<UUID> = []          // threads awaiting a reply

    private let url: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("chats.json")
    }()

    init() { load() }

    @discardableResult
    func newThread(project: String, cwd: String) -> ChatThread {
        let t = ChatThread(title: "New chat", project: project, cwd: cwd)
        threads.insert(t, at: 0); save(); return t
    }

    func send(_ threadId: UUID, _ text: String) {
        guard let idx = threads.firstIndex(where: { $0.id == threadId }) else { return }
        threads[idx].messages.append(ChatMessage(role: .user, text: text))
        if threads[idx].title == "New chat" { threads[idx].title = String(text.prefix(40)) }
        threads[idx].updatedAt = Date()
        busy.insert(threadId); save()
        let cwd = threads[idx].cwd, sid = threads[idx].sessionId

        Task {
            guard let jobId = await EdgeClient.shared.sendChat(cwd: cwd, sessionId: sid, message: text) else {
                finish(threadId, .error, "Couldn’t reach your Mac — is EdgePanel running?"); return
            }
            for _ in 0..<400 {                    // ~10 min at 1.5s
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let job = await EdgeClient.shared.pollChat(jobId) else { continue }
                switch job.status {
                case "done":
                    if let s = job.sessionId { setSession(threadId, s) }
                    finish(threadId, .assistant, job.result ?? "(no reply)"); return
                case "error":
                    finish(threadId, .error, job.error ?? "Something went wrong."); return
                default: continue                  // still running
                }
            }
            finish(threadId, .error, "Timed out waiting for a reply.")
        }
    }

    private func finish(_ id: UUID, _ role: ChatMessage.Role, _ text: String) {
        if let idx = threads.firstIndex(where: { $0.id == id }) {
            threads[idx].messages.append(ChatMessage(role: role, text: text))
            threads[idx].updatedAt = Date()
            threads.sort { $0.updatedAt > $1.updatedAt }
        }
        busy.remove(id); save()
    }
    private func setSession(_ id: UUID, _ sid: String) {
        if let idx = threads.firstIndex(where: { $0.id == id }) { threads[idx].sessionId = sid; save() }
    }
    func delete(_ id: UUID) { threads.removeAll { $0.id == id }; busy.remove(id); save() }

    private func save() { try? JSONEncoder().encode(threads).write(to: url) }
    private func load() {
        if let d = try? Data(contentsOf: url), let t = try? JSONDecoder().decode([ChatThread].self, from: d) {
            threads = t.sorted { $0.updatedAt > $1.updatedAt }
        }
    }
}

// MARK: - Thread list

struct ChatListView: View {
    @StateObject private var store = ChatStore.shared
    @EnvironmentObject var client: EdgeClient
    @State private var newChat = false
    var body: some View {
        NavigationStack {
            ZStack {
                T.bg.ignoresSafeArea()
                if store.threads.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 34)).foregroundColor(T.accent2)
                        Text("Talk to Claude Code from your phone").font(.claude(15, .semibold)).foregroundColor(T.text)
                        Text("Start a chat in any of your projects — it runs on your Mac with full autonomy.")
                            .font(.claude(12)).foregroundColor(T.subtext).multilineTextAlignment(.center).padding(.horizontal, 40)
                        Button { newChat = true } label: {
                            Label("New chat", systemImage: "plus").font(.claude(14, .semibold))
                                .padding(.horizontal, 16).padding(.vertical, 9)
                                .background(Capsule().fill(T.accent)).foregroundColor(.black)
                        }.padding(.top, 6)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(store.threads) { t in
                                NavigationLink { ChatThreadView(threadId: t.id).environmentObject(store) } label: {
                                    ThreadRow(t: t, busy: store.busy.contains(t.id))
                                }.buttonStyle(.plain)
                            }
                        }.padding(16)
                    }
                }
            }
            .navigationTitle("Chat")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { newChat = true } label: { Image(systemName: "square.and.pencil") }
                }
            }
            .sheet(isPresented: $newChat) {
                NewChatSheet { project, cwd in
                    let t = store.newThread(project: project, cwd: cwd); newChat = false
                    openThread = t.id
                }.environmentObject(client)
            }
            .navigationDestination(item: $openThread) { id in
                ChatThreadView(threadId: id).environmentObject(store)
            }
        }
        .tint(T.accent)
    }
    @State private var openThread: UUID?
}

private struct ThreadRow: View {
    let t: ChatThread
    let busy: Bool
    var body: some View {
        Card {
            HStack(spacing: 11) {
                Image(systemName: "bubble.left.and.text.bubble.right").foregroundColor(T.accent2).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).font(.claude(15, .semibold)).foregroundColor(T.text).lineLimit(1)
                    Text(t.project).font(.claude(11)).foregroundColor(T.subtext).lineLimit(1)
                }
                Spacer(minLength: 6)
                if busy { ProgressView().tint(T.accent) }
                else { Text(t.updatedAt, style: .relative).font(.claude(10)).foregroundColor(T.subtext) }
            }
        }
    }
}

// MARK: - One thread

struct ChatThreadView: View {
    @EnvironmentObject var store: ChatStore
    let threadId: UUID
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var thread: ChatThread? { store.threads.first { $0.id == threadId } }
    private var busy: Bool { store.busy.contains(threadId) }

    var body: some View {
        ZStack {
            T.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(thread?.messages ?? []) { Bubble(m: $0) }
                            if busy { TypingDots().id("typing") }
                        }.padding(14)
                    }
                    .onChange(of: thread?.messages.count ?? 0) { _, _ in
                        if let last = thread?.messages.last?.id {
                            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
                    .onChange(of: busy) { _, b in
                        if b { withAnimation { proxy.scrollTo("typing", anchor: .bottom) } }
                    }
                }
                composer
            }
        }
        .navigationTitle(thread?.project ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Message Claude…", text: $draft, axis: .vertical)
                .focused($focused).lineLimit(1...5)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 18).fill(T.track))
                .foregroundColor(T.text)
            Button {
                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, !busy else { return }
                store.send(threadId, text); draft = ""; focused = false
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
            Text(m.text)
                .font(.claude(14)).foregroundColor(color)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 14).fill(bg))
                .textSelection(.enabled)
            if m.role != .user { Spacer(minLength: 40) }
        }
    }
    private var color: Color { m.role == .user ? .black : (m.role == .error ? T.red : T.text) }
    private var bg: Color { m.role == .user ? T.accent : (m.role == .error ? T.red.opacity(0.14) : T.track) }
}

private struct TypingDots: View {
    @State private var on = false
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle().fill(T.subtext).frame(width: 7, height: 7)
                    .opacity(on ? 1 : 0.3)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.2), value: on)
            }
            Spacer()
        }
        .onAppear { on = true }
    }
}

// MARK: - New chat (pick a project)

struct NewChatSheet: View {
    @EnvironmentObject var client: EdgeClient
    @Environment(\.dismiss) var dismiss
    let onPick: (String, String) -> Void
    @State private var customPath = ""

    private var projects: [(name: String, cwd: String)] {
        let chats = client.snapshot?.chats ?? []
        var seen = Set<String>(); var out: [(String, String)] = []
        for c in chats { if let cwd = c.cwd, !cwd.isEmpty, seen.insert(cwd).inserted { out.append((c.project, cwd)) } }
        return out
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Pick a project") {
                    if projects.isEmpty {
                        Text("No recent projects yet — enter a folder path below.").font(.footnote).foregroundColor(.secondary)
                    }
                    ForEach(projects, id: \.cwd) { p in
                        Button { onPick(p.name, p.cwd) } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(p.name).foregroundColor(.primary)
                                    Text(p.cwd).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                                }
                                Spacer(); Image(systemName: "chevron.right").foregroundColor(.secondary)
                            }
                        }
                    }
                }
                Section("Or a folder path on your Mac") {
                    HStack {
                        TextField("/Users/you/project", text: $customPath)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                        Button("Start") {
                            let p = customPath.trimmingCharacters(in: .whitespaces)
                            guard !p.isEmpty else { return }
                            onPick((p as NSString).lastPathComponent, p)
                        }.disabled(customPath.isEmpty)
                    }
                }
            }
            .navigationTitle("New chat")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
