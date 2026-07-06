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
    var title: String?          // optional user-given name (falls back to project)
    var displayName: String { title?.isEmpty == false ? title! : project }
    /// What to pass as --resume; nil = start a fresh session (a new task not yet adopted).
    var resumeId: String? { sessionId ?? (id.hasPrefix("new-") ? nil : id) }
}

@MainActor
final class ChatStore: ObservableObject {
    static let shared = ChatStore()
    @Published var threads: [ChatThread] = []
    @Published var busy: Set<String> = []        // thread ids awaiting a reply
    @Published var busyJob: [String: String] = [:]   // thread id → running jobId (for Stop / reattach)
    @Published var reconnecting: Set<String> = []    // threads whose Mac link dropped (UI hint)
    @Published var delivered: Set<String> = []       // editor threads whose message landed in the chat
    private var stopping: Set<String> = []           // threads the user asked to stop (streamJob bails next tick)
    private var activeStreams: [String: UUID] = [:]  // thread id → live poll loop's ownership token (no double-pollers)

    private let url: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chats.json")
    }()
    init() { load() }

    // Match by stable id OR adopted sessionId: a new-task thread keeps id "new-…" but adopts
    // the real session id, so opening it from WORKING NOW (keyed by session id) must find it
    // instead of spawning a duplicate.
    func thread(_ id: String) -> ChatThread? { threads.first { $0.id == id || $0.sessionId == id } }

    /// Open (or create) the thread for a real session and pull its live history
    /// from the Mac so you see the conversation that's on your PC.
    func open(sessionId: String, project: String, cwd: String) {
        if let i = threads.firstIndex(where: { $0.id == sessionId || $0.sessionId == sessionId }) {
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
            // Match by id OR sessionId — the SAME rule thread(threadId) used above. Opening a
            // phone-started task from WORKING NOW passes the real session id, which is the thread's
            // sessionId (not its stable id); an id-only firstIndex missed it, so that thread never
            // reconciled against the Mac transcript (dropped turns run on the PC).
            guard !hist.isEmpty, !busy.contains(threadId),
                  let i = threads.firstIndex(where: { $0.id == threadId || $0.sessionId == threadId }) else { return }
            // A trailing local .error marker ("■ Stopped"/failure) is device-only — the
            // transcript never has it. Exclude it from the "is the device ahead?" comparison
            // so it doesn't inflate the count it's measured against (which would FREEZE future
            // refreshes until the server grew by 2), and don't clobber real local content.
            let hasMarker = threads[i].messages.last?.role == .error
            let localContent = threads[i].messages.count - (hasMarker ? 1 : 0)
            guard hist.count >= localContent else { return }
            // Re-attach the marker only at the equal boundary AND only when the transcript did
            // NOT land a real reply past it — otherwise that recovered assistant turn IS the
            // answer and re-appending the stale "Stopped" would shadow it + show a bogus Retry.
            let trailingMarker = (hasMarker && hist.count == localContent && hist.last?.role != "assistant")
                ? threads[i].messages.last : nil
            threads[i].messages = hist.map {
                ChatMessage(role: $0.role == "assistant" ? .assistant : .user, text: $0.text)
            }
            if let m = trailingMarker { threads[i].messages.append(m) }
            save()
        }
    }

    func send(_ threadId: String, _ text: String) {
        guard let i = threads.firstIndex(where: { $0.id == threadId }) else { return }
        threads[i].messages.append(ChatMessage(role: .user, text: text))
        threads[i].updatedAt = Date()
        let cwd = threads[i].cwd, resume = threads[i].resumeId   // capture before the sort changes indices
        threads.sort { $0.updatedAt > $1.updatedAt }             // float this thread to the top now, not only on completion
        busy.insert(threadId); delivered.remove(threadId)
        stopping.remove(threadId)   // a fresh turn must not inherit a pending Stop from a prior one
        save()

        Task {
            guard let jobId = await EdgeClient.shared.sendChat(cwd: cwd, sessionId: resume, message: text) else {
                finish(threadId, .error, "Couldn’t reach your Mac — is EdgePanel running?"); return
            }
            busyJob[threadId] = jobId; save()   // persist so a kill/relaunch can reattach to this turn
            await streamJob(jobId, into: threadId)
        }
    }

    /// Resend the last user message after a failed turn: drop trailing error/"Stopped"
    /// bubbles, then re-run that prompt. No-op if the thread is busy or has no user turn.
    func retryLast(_ threadId: String) {
        guard !busy.contains(threadId), let i = threads.firstIndex(where: { $0.id == threadId }) else { return }
        while threads[i].messages.last?.role == .error { threads[i].messages.removeLast() }
        guard let lastUser = threads[i].messages.last(where: { $0.role == .user })?.text else { return }
        // Strip everything after that user turn (a partial assistant reply) so the resend is clean.
        if let lu = threads[i].messages.lastIndex(where: { $0.role == .user }) {
            threads[i].messages.removeSubrange((lu + 1)...)
        }
        threads[i].messages.removeLast()   // send() re-appends the user bubble
        send(threadId, lastUser)
    }

    /// Stop the running turn — terminates the `claude` process on the Mac AND settles
    /// the thread locally right away, so the UI never sits stuck "thinking" if the
    /// cancel races the poll or the Mac is briefly unreachable. streamJob sees
    /// `stopping` and bails on its next tick without overwriting the stopped state.
    func stop(_ id: String) {
        if let job = busyJob[id] { EdgeClient.shared.cancelChat(jobId: job) }
        // Only arm the bail flag if a loop can actually consume it — a live streamJob
        // (activeStreams) or the send→streamJob await window (busy). Otherwise it would leak
        // an entry in `stopping` that nothing ever removes.
        if activeStreams[id] != nil || busy.contains(id) { stopping.insert(id) }
        activeStreams[id] = nil   // free the stream slot NOW so a quick Retry isn't dropped by the activeStreams guard
        busy.remove(id); busyJob[id] = nil; delivered.remove(id)
        if let i = threads.firstIndex(where: { $0.id == id }),
           threads[i].messages.last?.role != .assistant {
            // Nothing streamed yet → leave a clear marker instead of a silent stop.
            threads[i].messages.append(ChatMessage(role: .error, text: "■ Stopped"))
        }
        save()
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
            busyJob[tempId] = jobId; save()   // persist so a kill/relaunch can reattach to this turn
            await streamJob(jobId, into: tempId)
        }
        return tempId
    }

    /// Shared streaming poll loop: render the reply token-by-token, adopt the real
    /// session id when it appears, and settle on done/error.
    /// Poll a running turn to completion, streaming the reply live. RESILIENT: a dropped
    /// network connection is tolerated (kept "reconnecting", not abandoned), and whenever the
    /// live job can't deliver — Mac restarted, job evicted, or the app was backgrounded past a
    /// timeout — the reply is RECOVERED from the session transcript (the source of truth).
    private func streamJob(_ jobId: String, into threadId: String) async {
        guard activeStreams[threadId] == nil else { return }   // already streaming this thread
        let streamToken = UUID()
        activeStreams[threadId] = streamToken
        // Only clear the slot if WE still own it: a stopped-then-retried stream's defer must
        // not evict the replacement stream's slot (which would let reconnectInFlight spawn a
        // second concurrent poller for the same thread). Ownership token closes that race.
        defer { if activeStreams[threadId] == streamToken { activeStreams[threadId] = nil } }
        busyJob[threadId] = jobId; busy.insert(threadId)
        // Reattach to the in-progress bubble if one already exists (reconnect after foreground).
        var streamId: UUID? = inProgressBubbleId(threadId)
        var netFails = 0
        let deadline = Date().addingTimeInterval(15 * 60)         // generous hard cap
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            // user hit Stop → SELF-settle (don't trust stop() to have done it: a Stop during
            // send()'s pre-stream await cleared busy then send() re-set busyJob, so this loop
            // must clear them or the thread leaks a "busy" job that nothing settles).
            if stopping.contains(threadId) { stopping.remove(threadId); settleStopped(threadId, streamToken); return }
            guard let job = await EdgeClient.shared.pollChat(jobId) else {
                netFails += 1
                if netFails == 6 { setReconnecting(threadId, true) }   // ~3s offline → show "reconnecting"
                if netFails >= 40 {                                    // ~20s offline → try the transcript
                    if await recoverFromTranscript(threadId, streamToken) { return }
                    netFails = 6                                       // still running → keep trying, stay reconnecting
                }
                continue
            }
            // Stop landed DURING this poll await → self-settle, don't resurrect the reply.
            if stopping.contains(threadId) { stopping.remove(threadId); settleStopped(threadId, streamToken); return }
            // A Stop-then-Retry reassigned this thread's slot to a newer stream → this loop is
            // stale; exit without touching the new loop's state.
            if activeStreams[threadId] != streamToken { return }
            if netFails > 0 { netFails = 0; setReconnecting(threadId, false) }
            if let sid = job.sessionId, !sid.isEmpty { adopt(threadId, sessionId: sid) }
            if job.delivered == true, !delivered.contains(threadId) { delivered.insert(threadId) }
            switch job.status {
            case "running":
                if let partial = job.result, !partial.isEmpty { streamId = upsertStream(threadId, streamId, partial) }
            case "done":
                finalize(threadId, streamId, job.result ?? "(no reply)", .assistant); return
            case "gone":   // Mac restarted / job evicted → the finished reply lives in the transcript
                if await recoverFromTranscript(threadId, streamToken) { return }
                finalize(threadId, streamId, "Lost track of this turn on your Mac — it may still be running. Pull to refresh.", .error); return
            case "error":
                finalize(threadId, streamId, job.error ?? "Something went wrong.", .error); return
            default: break
            }
        }
        if await recoverFromTranscript(threadId, streamToken) { return }
        // Don't clobber visible streamed text with the timeout error — if the bubble already
        // holds a real partial answer, keep it and append a separate marker (as stop() does);
        // only reuse the bubble if it's empty.
        let keepPartial = streamId.flatMap { sid in
            thread(threadId)?.messages.first(where: { $0.id == sid })?.text.isEmpty == false
        } ?? false
        finalize(threadId, keepPartial ? nil : streamId, "Timed out waiting for a reply.", .error)
    }

    /// Recover a turn's reply from the session transcript when the live stream couldn't deliver.
    /// Returns true if the turn is finished there (transcript ends with an assistant reply).
    /// Settle a thread that the user stopped: clear busy/job/reconnecting (and our slot if we
    /// still own it). Needed because a Stop during send()'s pre-stream await clears busy, then
    /// send() re-sets busyJob, so the bailing stream must clear it again.
    private func settleStopped(_ threadId: String, _ streamToken: UUID) {
        busy.remove(threadId); busyJob[threadId] = nil; reconnecting.remove(threadId); delivered.remove(threadId)
        if activeStreams[threadId] == streamToken { activeStreams[threadId] = nil }
        save()
    }

    @discardableResult
    private func recoverFromTranscript(_ threadId: String, _ streamToken: UUID) async -> Bool {
        guard let t = thread(threadId), let resume = t.resumeId else { return false }
        let hist = await EdgeClient.shared.fetchHistory(sessionId: resume, cwd: t.cwd)
        // A Stop-then-Retry (or any takeover) reassigned this thread to a newer stream during the
        // fetch await → don't clobber the new turn with this stale loop's recovered history.
        guard activeStreams[threadId] == streamToken else { return true }
        guard hist.last?.role == "assistant",                      // turn finished iff it ends with a reply
              let i = threads.firstIndex(where: { $0.id == threadId }) else { return false }
        // Don't clobber a longer local thread, and only treat THIS turn as finished if the
        // transcript's last prompt is the one we sent — otherwise we'd drop a just-queued local
        // user message and surface a stale prior reply as if it were the new one.
        guard hist.count >= threads[i].messages.count else { return false }
        let localLastUser = threads[i].messages.last(where: { $0.role == .user })?.text
        let histLastUser = hist.last(where: { $0.role == "user" })?.text
        guard localLastUser == nil || localLastUser == histLastUser else { return false }
        threads[i].messages = hist.map { ChatMessage(role: $0.role == "assistant" ? .assistant : .user, text: $0.text) }
        threads[i].updatedAt = Date(); threads.sort { $0.updatedAt > $1.updatedAt }
        busy.remove(threadId); busyJob[threadId] = nil; reconnecting.remove(threadId); delivered.remove(threadId); save()
        return true
    }

    private func setReconnecting(_ id: String, _ on: Bool) {
        if on { reconnecting.insert(id) } else { reconnecting.remove(id) }
    }
    /// The in-progress assistant bubble for a busy thread (its trailing assistant message), if any.
    private func inProgressBubbleId(_ threadId: String) -> UUID? {
        guard let last = thread(threadId)?.messages.last, last.role == .assistant else { return nil }
        return last.id
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
        busy.remove(id); busyJob[id] = nil; reconnecting.remove(id); delivered.remove(id); save()
    }

    private func finish(_ id: String, _ role: ChatMessage.Role, _ text: String) {
        finalize(id, nil, text, role)
    }
    func delete(_ id: String) {
        if let job = busyJob[id] { EdgeClient.shared.cancelChat(jobId: job) }   // kill the Mac claude process
        if activeStreams[id] != nil || busy.contains(id) { stopping.insert(id) }  // arm bail only if a loop consumes it
        activeStreams[id] = nil                                                  // streamJob loop bails next tick
        threads.removeAll { $0.id == id }
        busy.remove(id); busyJob[id] = nil                                       // drop the orphan job before save()
        save()
    }
    func rename(_ id: String, to title: String) {
        guard let i = threads.firstIndex(where: { $0.id == id }) else { return }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        threads[i].title = t.isEmpty ? nil : t; save()
    }

    private var pendingSave: Task<Void, Never>?
    private let busyKey = "edgepanel.busyJobs"
    /// Debounced, off-main persistence — was a synchronous main-actor disk write on every
    /// streamed token (a write storm). Coalesce: capture state now, write ~0.6s later.
    /// busyJob is persisted too (synchronously, it's tiny) so a relaunch can reattach to an
    /// in-flight turn instead of losing the reply.
    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(busyJob), forKey: busyKey)
        pendingSave?.cancel()
        let snapshot = threads, u = url
        pendingSave = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 600_000_000)
            if Task.isCancelled { return }
            try? JSONEncoder().encode(snapshot).write(to: u, options: .atomic)   // no torn write if two saves race
        }
    }
    private func load() {
        if let d = try? Data(contentsOf: url), let t = try? JSONDecoder().decode([ChatThread].self, from: d) {
            threads = t.sorted { $0.updatedAt > $1.updatedAt }
        }
        if let d = UserDefaults.standard.data(forKey: busyKey),
           let b = try? JSONDecoder().decode([String: String].self, from: d) {
            // Reattach to turns that were in flight when the app was last killed.
            busyJob = b.filter { kv in threads.contains { $0.id == kv.key } }
            busy = Set(busyJob.keys)
        }
    }

    /// Re-attach to every in-flight turn (after a relaunch or returning to the foreground):
    /// resume polling its job, and if the job is gone, recover the reply from the transcript.
    func reconnectInFlight() {
        for (threadId, jobId) in busyJob where activeStreams[threadId] == nil {
            Task { await streamJob(jobId, into: threadId) }
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
    @State private var pendingOpenId: String?
    @State private var renameId: String?
    @State private var renameText = ""

    // The live editor session (the chat open in VS Code/Cursor on your Mac) — typing here
    // types into it. It's pinned as a hero card and excluded from the regular thread list.
    private var editorId: String? {
        let id = client.snapshot?.editorSessionId
        return (id?.isEmpty == false) ? id : nil
    }
    private var editorBusy: Bool {
        guard let s = client.snapshot else { return false }
        return s.working.contains { $0.isEditor || $0.id == editorId }
    }
    /// Every OTHER chat currently running on the Mac (not the editor hero) — so two (or more)
    /// working chats all appear and are tappable, even ones you haven't opened as a thread yet.
    private var workingRemote: [EdgeSnapshot.Working] {
        var seen = Set<String>()
        return (client.snapshot?.working ?? []).filter { w in
            guard !w.isEditor, w.id != editorId, !seen.contains(w.id) else { return false }
            seen.insert(w.id); return true   // dedupe: a duplicate id would break the ForEach
        }
    }
    private var excludedIds: Set<String> {
        var s = Set(workingRemote.map { $0.id }); if let e = editorId { s.insert(e) }; return s
    }
    /// The full history of your chats — every recent Claude Code session on the Mac, newest
    /// first, so you can jump into any of them. (Excludes the editor hero + what's running.)
    private var historyChats: [EdgeSnapshot.Chat] {
        let excl = excludedIds
        var seen = Set<String>()
        return (client.snapshot?.chats ?? []).filter { c in
            guard !excl.contains(c.id), seen.insert(c.id).inserted else { return false }; return true
        }
    }
    /// Phone-side chats (new tasks you started here) that aren't in the Mac's recent list yet.
    private var extraThreads: [ChatThread] {
        let inHistory = Set((client.snapshot?.chats ?? []).map { $0.id })
        let excl = excludedIds
        return store.threads.filter {
            !inHistory.contains($0.id) && !inHistory.contains($0.sessionId ?? "")
                && !excl.contains($0.id) && !excl.contains($0.sessionId ?? "")
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                T.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 12) {
                        // PINNED: your live editor session — type here, it types into your Mac.
                        if let eid = editorId {
                            NavigationLink {
                                ChatThreadView(sessionId: eid,
                                               project: client.snapshot?.editorProject ?? "Editor",
                                               cwd: client.snapshot?.editorCwd ?? "")
                            } label: {
                                EditorHeroCard(project: client.snapshot?.editorProject ?? "Editor",
                                               cwd: client.snapshot?.editorCwd ?? "",
                                               mode: client.snapshot?.mode ?? "ask",
                                               busy: editorBusy,
                                               mascotAnim: client.snapshot?.mascotAnim ?? "idle_blink",
                                               lastPrompt: client.snapshot?.promptHistory?.first?.text)
                            }.buttonStyle(.plain)
                        }

                        if !workingRemote.isEmpty {
                            HStack {
                                Text("RUNNING NOW").font(.claude(10, .semibold)).tracking(0.8).foregroundColor(T.green)
                                Spacer()
                                Text("\(workingRemote.count)").font(.claude(10, .semibold)).foregroundColor(T.green)
                            }.padding(.top, 4)
                            ForEach(workingRemote) { w in
                                NavigationLink {
                                    ChatThreadView(sessionId: w.id, project: w.project, cwd: w.cwd)
                                } label: { RunningRow(w: w) }.buttonStyle(.plain)
                            }
                        }

                        if !historyChats.isEmpty || !extraThreads.isEmpty {
                            HStack {
                                Text("HISTORY").font(.claude(10, .semibold)).tracking(0.8).foregroundColor(T.subtext)
                                Spacer()
                                Text("\(historyChats.count + extraThreads.count)").font(.claude(10, .semibold)).foregroundColor(T.subtext)
                            }.padding(.top, 6)
                            ForEach(extraThreads) { t in
                                NavigationLink {
                                    ChatThreadView(sessionId: t.id, project: t.project, cwd: t.cwd)
                                } label: { ThreadRow(t: t, busy: store.busy.contains(t.id)) }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button { renameId = t.id; renameText = t.displayName } label: { Label("Rename", systemImage: "pencil") }
                                        Button(role: .destructive) { store.delete(t.id) } label: { Label("Delete", systemImage: "trash") }
                                    }
                            }
                            ForEach(historyChats) { c in
                                NavigationLink {
                                    ChatThreadView(sessionId: c.id, project: c.project, cwd: c.cwd ?? "")
                                } label: { HistoryRow(chat: c) }.buttonStyle(.plain)
                                    .contextMenu {
                                        Button { client.openChat(c) } label: {
                                            Label("Open on Mac (reliable for big chats)", systemImage: "macwindow")
                                        }
                                    }
                            }
                        }

                        if editorId == nil && historyChats.isEmpty && extraThreads.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 34)).foregroundColor(T.accent2)
                                Text("Drive Claude Code from here").font(.claude(15, .semibold)).foregroundColor(T.text)
                                Text("Open Claude Code in VS Code or Cursor on your Mac and it appears here as your Editor — type on your phone and it types into it. Or tap ＋ to start a new autonomous task.")
                                    .font(.claude(12)).foregroundColor(T.subtext).multilineTextAlignment(.center).padding(.horizontal, 26)
                                Button { showNew = true } label: {
                                    Label("New Task", systemImage: "plus.circle.fill").font(.claude(14, .semibold))
                                }.buttonStyle(.borderedProminent).tint(T.accent).padding(.top, 4)
                            }.padding(.top, 70)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Command")
            .confirmationDialog("Stop everything?", isPresented: $showPanic, titleVisibility: .visible) {
                Button("Stop all & disarm", role: .destructive) { client.panic() }
            } message: { Text("Kills every running task, turns Autonomous off, and denies pending permissions.") }
            .alert("Rename chat", isPresented: Binding(get: { renameId != nil }, set: { if !$0 { renameId = nil } })) {
                TextField("Name", text: $renameText)
                Button("Save") { if let id = renameId { store.rename(id, to: renameText) }; renameId = nil }
                Button("Cancel", role: .cancel) { renameId = nil }
            }
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
        // Open the new thread in onDismiss — i.e. AFTER the sheet is fully gone — so the
        // navigation push can't race the sheet's dismissal and silently no-op (which looked
        // like "starting a new chat does nothing"). The thread is already created, so even if
        // anything went wrong it's still visible at the top of the list.
        .sheet(isPresented: $showNew, onDismiss: {
            if let id = pendingOpenId { pendingOpenId = nil; openId = id }
        }) {
            NewTaskSheet { id in
                pendingOpenId = id
                showNew = false
            }.environmentObject(client)
        }
    }
}

/// Toolbar control for Autonomous (auto-approve) mode — flip it on and the Mac
/// auto-allows every permission so work runs hands-off.
private struct AutonomyToggle: View {
    @EnvironmentObject var client: EdgeClient
    @State private var pending: Bool?      // optimistic flip until the snapshot reconciles
    @State private var reconcile: Task<Void, Never>?
    private var on: Bool { pending ?? client.snapshot?.autoApprove ?? false }
    var body: some View {
        Button {
            let next = !on; pending = next; client.setAutoApprove(next)   // flip instantly
            // Fall back to server truth after a moment — covers the case where the
            // snapshot already equals `next` (onChange wouldn't fire) or the Mac never
            // confirms, so the toggle can't get wedged showing a stale optimistic value.
            reconcile?.cancel()
            reconcile = Task { try? await Task.sleep(nanoseconds: 4_000_000_000)
                               if !Task.isCancelled { pending = nil } }
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
    @State private var loaded = false      // distinguish "still loading" from "loaded, none found"
    @FocusState private var focused: Bool

    private var canStart: Bool { picked != nil && !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            ZStack {
                T.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("PROJECT").font(.claude(11, .semibold)).foregroundColor(T.subtext)
                        if !loaded {
                            HStack { ProgressView().tint(T.accent); Text("Loading projects…").font(.claude(12)).foregroundColor(T.subtext) }
                        } else if projects.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("No projects found — is EdgePanel running on your Mac?")
                                    .font(.claude(12)).foregroundColor(T.subtext)
                                Button { Task { await loadProjects() } } label: {
                                    Label("Retry", systemImage: "arrow.clockwise").font(.claude(12, .semibold))
                                }.tint(T.accent)
                            }
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
            .task { await loadProjects() }
        }
        .tint(T.accent)
    }

    private func loadProjects() async {
        loaded = false
        projects = await client.fetchProjects()
        if picked == nil { picked = projects.first }
        loaded = true
    }
}

/// The hero card for your live editor session — the chat open in VS Code/Cursor on your
/// Mac. Distinct, alive, and the centerpiece: tap in and what you type types into it.
private struct EditorHeroCard: View {
    let project: String
    let cwd: String
    let mode: String
    let busy: Bool
    var mascotAnim: String = "idle_blink"
    let lastPrompt: String?

    private var modeLabel: String {
        switch mode { case "bypass": return "Bypass"; case "edit": return "Edit"; case "plan": return "Plan"
        case "auto": return "Auto"; default: return "Ask" }
    }
    private var modeColor: Color {
        switch mode { case "bypass": return T.red; case "edit": return T.amber; case "auto": return T.accent; default: return T.accent2 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                PulsingDot()
                Text("YOUR EDITOR").font(.claude(10, .semibold)).tracking(1.0).foregroundColor(T.green)
                Spacer()
                Text(modeLabel).font(.claude(10, .semibold)).foregroundColor(modeColor)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(modeColor.opacity(0.16)))
            }
            HStack(spacing: 10) {
                AnimatedMascot(name: mascotAnim, cell: 1.7, fill: modeColor, eye: T.bg, crop: true)
                    .frame(width: 30, height: 30)
                    .animation(.easeInOut(duration: 0.4), value: mascotAnim)
                Text(project).font(.claude(20, .bold)).foregroundColor(T.text).lineLimit(1)
                Spacer(minLength: 0)
            }
            if busy {
                HStack(spacing: 7) {
                    ThinkingDots()
                    Text("Claude is working in your editor…").font(.claude(12.5, .medium)).foregroundColor(T.accent)
                }
            } else if let p = lastPrompt, !p.isEmpty {
                Text(p).font(.claude(12.5)).foregroundColor(T.subtext).lineLimit(1)
            } else {
                Text("Ready — open the chat and type").font(.claude(12.5)).foregroundColor(T.subtext)
            }
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold))
                Text("Type here → types into Claude Code on your Mac").font(.claude(11, .medium))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(T.accent2)
            .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [T.accent.opacity(0.16), T.cardTop, T.cardBot],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(LinearGradient(colors: [T.accent.opacity(0.5), T.border], startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
        )
        .shadow(color: T.accent.opacity(0.18), radius: 16, x: 0, y: 6)
    }
}

/// One past chat in the history — its name, project, and when it was last active. Tap to
/// open it (loads the real transcript) and pick up the conversation.
private struct HistoryRow: View {
    let chat: EdgeSnapshot.Chat
    var body: some View {
        Card {
            HStack(spacing: 11) {
                Image(systemName: "bubble.left.and.text.bubble.right").foregroundColor(T.accent2).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.name).font(.claude(15, .semibold)).foregroundColor(T.text).lineLimit(1)
                    Text(chat.project).font(.claude(11)).foregroundColor(T.subtext).lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(chat.lastActive, style: .relative).font(.claude(10)).foregroundColor(T.subtext)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundColor(T.subtext)
            }
        }
    }
}

/// A chat currently running on the Mac (other than your editor) — live status + timer.
private struct RunningRow: View {
    let w: EdgeSnapshot.Working
    var body: some View {
        Card {
            HStack(spacing: 11) {
                PulsingDot()
                VStack(alignment: .leading, spacing: 2) {
                    Text(w.project).font(.claude(15, .semibold)).foregroundColor(T.text).lineLimit(1)
                    Text("\u{201C}\(w.display)\u{201D}").font(.claude(11)).italic().foregroundColor(T.subtext).lineLimit(1)
                }
                Spacer(minLength: 6)
                if let at = w.promptAt {
                    Text(at, style: .timer).font(.claude(13, .semibold)).foregroundColor(T.green).monospacedDigit()
                }
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundColor(T.subtext)
            }
        }
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
                    Text(t.displayName).font(.claude(15, .semibold)).foregroundColor(T.text).lineLimit(1)
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
    @EnvironmentObject var client: EdgeClient
    let sessionId: String
    let project: String
    let cwd: String
    @State private var draft = ""
    @State private var atBottom = true
    @State private var justSentToEditor = false
    @FocusState private var focused: Bool

    private var thread: ChatThread? { store.thread(sessionId) }
    private var busy: Bool { store.busy.contains(sessionId) }
    private var messages: [ChatMessage] { thread?.messages ?? [] }
    private var thinking: Bool { busy && messages.last?.role == .user }   // sent, nothing back yet
    /// This thread IS the live editor session — sends type straight into Claude Code on the Mac.
    private var isEditor: Bool { sessionId == client.snapshot?.editorSessionId }
    /// Editor delivery state for the waiting row: "Sending…" until the Mac verifies the message
    /// landed in the chat input, then "✓ Sent to your editor".
    private var editorWaitLabel: String? {
        guard isEditor else { return nil }
        return store.delivered.contains(sessionId) ? "Sent to your editor · waiting for Claude…"
                                                   : "Sending to your editor…"
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            T.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                if isEditor {
                    HStack(spacing: 7) {
                        Circle().fill(T.green).frame(width: 7, height: 7)
                        Text("Live — what you type types into Claude Code on your Mac")
                            .font(.claude(11, .medium)).foregroundColor(T.green)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .background(T.green.opacity(0.08))
                    .overlay(Rectangle().fill(T.border).frame(height: 1), alignment: .bottom)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(messages) { m in
                                MessageView(message: m, streaming: busy && m.id == messages.last?.id && m.role == .assistant)
                                    .id(m.id)
                            }
                            if thinking { ThinkingRow(label: editorWaitLabel, check: isEditor && store.delivered.contains(sessionId)).id("thinking") }
                            Color.clear.frame(height: 1).id("bottom")
                                .onAppear { atBottom = true }.onDisappear { atBottom = false }
                        }
                        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: messages.last?.text) { _, _ in if atBottom { scrollToBottom(proxy) } }
                    .onChange(of: messages.count) { _, _ in if atBottom { scrollToBottom(proxy) } }
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
                if store.reconnecting.contains(sessionId) {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small).tint(T.amber)
                        Text("Reconnecting to your Mac… your reply is safe").font(.claude(12, .medium)).foregroundColor(T.amber)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .background(T.amber.opacity(0.10))
                }
                if !busy, messages.last?.role == .error {
                    Button { store.retryLast(sessionId) } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.claude(13, .semibold)).foregroundColor(T.accent)
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 11).fill(T.accent.opacity(0.12)))
                    }.padding(.horizontal, 16).padding(.bottom, 4)
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
                TextField(isEditor ? "Type into your editor…" : "Reply to Claude…", text: $draft, axis: .vertical)
                    .font(.claude(15.5)).foregroundColor(T.text)
                    .focused($focused).lineLimit(1...6)
                    .padding(.horizontal, 15).padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 22).fill(T.card))
                    .overlay(RoundedRectangle(cornerRadius: 22)
                        .stroke(focused ? T.accent.opacity(0.6) : T.border, lineWidth: 1))
                    .animation(.easeInOut(duration: 0.2), value: focused)
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
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
                Text(message.text).font(.claude(14)).foregroundColor(T.red).textSelection(.enabled)
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
    var label: String? = nil
    var check: Bool = false   // editor message confirmed delivered → green checkmark instead of dots
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "bird.fill").font(.system(size: 11)).foregroundColor(T.accent)
                Text("Claude").font(.claude(11, .semibold)).tracking(0.4).foregroundColor(T.subtext)
            }
            if let label {
                HStack(spacing: 7) {
                    if check {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundColor(T.green)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        ThinkingDots()
                    }
                    Text(label).font(.claude(12, .medium)).foregroundColor(check ? T.green : T.subtext)
                }
                .animation(.smooth(duration: 0.3), value: check)
            } else {
                ThinkingDots()
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Markdown renderer (block-level)

private enum MDBlock { case heading(Int, String), paragraph(String)
                       case bullets([(Int, String)])           // (depth, text) — supports nesting
                       case numbered([(Int, String, String)])  // (depth, number, text)
                       case table([String], [[String]])        // headers, rows
                       case code(String, String), quote(String), rule, tool(String) }

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
                        Text(it.0 == 0 ? "•" : "◦").font(.claude(15)).foregroundColor(T.accent)
                        Text(inlineMD(it.1)).foregroundColor(T.text).lineSpacing(2.5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(it.0) * 16)
                }
            }
        case .numbered(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text(it.1 + ".").font(.claude(14.5, .semibold)).foregroundColor(T.accent)
                            .frame(minWidth: 19, alignment: .trailing)
                        Text(inlineMD(it.2)).foregroundColor(T.text).lineSpacing(2.5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(it.0) * 16)
                }
            }
        case .table(let headers, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                    GridRow {
                        ForEach(Array(headers.enumerated()), id: \.offset) { _, h in
                            Text(inlineMD(h, size: 13.5, weight: .bold)).foregroundColor(T.text)
                        }
                    }
                    if !rows.isEmpty { Divider().background(T.border).gridCellColumns(max(headers.count, 1)) }
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                        GridRow {
                            ForEach(Array(r.enumerated()), id: \.offset) { _, c in
                                Text(inlineMD(c, size: 13.5)).foregroundColor(T.text)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(11)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(T.card))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(T.border, lineWidth: 1))
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
    // Leading-whitespace depth for nested lists (2 spaces or 1 tab per level, capped).
    func depth(_ n: Int) -> Int {
        var spaces = 0
        for ch in lines[n] { if ch == " " { spaces += 1 } else if ch == "\t" { spaces += 2 } else { break } }
        return min(spaces / 2, 4)
    }
    while i < lines.count {
        let line = trimmed(i)
        // GitHub table: a `| … |` header immediately followed by a `|---|---|` delimiter row.
        if line.contains("|"), i + 1 < lines.count, isTableDelimiter(trimmed(i + 1)),
           !tableCells(line).isEmpty {   // a bare "|" / "||" header → no columns → don't emit a 0-column Grid
            let headers = tableCells(line)
            i += 2
            var rows: [[String]] = []
            while i < lines.count, !trimmed(i).isEmpty, trimmed(i).contains("|") {
                rows.append(tableCells(trimmed(i))); i += 1
            }
            blocks.append(.table(headers, rows)); continue
        }
        if line.hasPrefix("```") {                                   // fenced code (robust to unclosed during streaming)
            let openTicks = line.prefix(while: { $0 == "`" }).count   // 3+ backticks
            let lang = String(line.dropFirst(openTicks)).trimmingCharacters(in: .whitespaces)
            var body: [String] = []; i += 1
            // Close only on an all-backtick line of >= the opening length (so ``` inside a
            // ~~~ block, or a code line starting with backticks, doesn't close early), and
            // only consume the closer if one actually exists (don't drop the next line when
            // the fence is still open mid-stream).
            func isCloser(_ s: String) -> Bool {
                let t = s.trimmingCharacters(in: .whitespaces)
                return t.count >= openTicks && t.allSatisfy { $0 == "`" }
            }
            while i < lines.count && !isCloser(trimmed(i)) { body.append(lines[i]); i += 1 }
            if i < lines.count { i += 1 }
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
        if isBullet(line) {                                           // bullet list (with nesting depth)
            var items: [(Int, String)] = []
            while i < lines.count && isBullet(trimmed(i)) { items.append((depth(i), bulletText(trimmed(i)))); i += 1 }
            blocks.append(.bullets(items)); continue
        }
        if numbered(line) != nil {                                    // numbered list (with nesting depth)
            var items: [(Int, String, String)] = []
            while i < lines.count, let n = numbered(trimmed(i)) { items.append((depth(i), n.0, n.1)); i += 1 }
            blocks.append(.numbered(items)); continue
        }
        if line.isEmpty { i += 1; continue }
        var para: [String] = []                                       // paragraph (gather until a special line/blank)
        while i < lines.count {
            let l = trimmed(i)
            if l.isEmpty || l.hasPrefix("```") || l.hasPrefix("#") || l.hasPrefix(">") || l.hasPrefix("⚙ ")
                || isBullet(l) || numbered(l) != nil || l == "---" || l == "***" || l == "___"
                || (l.contains("|") && i + 1 < lines.count && isTableDelimiter(trimmed(i + 1))) { break }
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
/// A GitHub table delimiter row, e.g. "|---|:--:|" or "--- | ---". Requires a pipe so a
/// bare "---" thematic break (after a line that merely contains a pipe) isn't misread as one.
private func isTableDelimiter(_ s: String) -> Bool {
    guard s.contains("-"), s.contains("|") else { return false }
    let body = s.trimmingCharacters(in: CharacterSet(charactersIn: "| "))
    guard !body.isEmpty else { return false }
    return body.allSatisfy { $0 == "-" || $0 == ":" || $0 == "|" || $0 == " " }
}
/// Split a table row "| a | b |" into trimmed cells, dropping the outer-pipe empties.
private func tableCells(_ s: String) -> [String] {
    var cells = s.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    if let f = cells.first, f.isEmpty { cells.removeFirst() }
    if let l = cells.last, l.isEmpty { cells.removeLast() }
    return cells
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
