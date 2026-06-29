// ChatRunner — "talk to Claude Code from your phone". Each message the phone sends
// spawns `claude -p <msg> --output-format json [--resume <id>]` in the project dir
// with permissions bypassed (full autonomy), and the JSON result (reply + the
// session_id to continue the thread) is stashed under a jobId the phone polls —
// so a multi-minute turn doesn't block the HTTP request.

import Foundation

final class ChatRunner: @unchecked Sendable {
    static let shared = ChatRunner()

    struct Job: Codable {
        var status: String        // "running" | "done" | "error"
        var result: String?       // assistant reply (done)
        var sessionId: String?    // session to --resume next turn
        var error: String?
    }

    /// Result of kicking off a turn: a job to poll, the session is already busy, or
    /// the claude CLI couldn't be found.
    enum StartResult { case started(String); case busy; case unavailable }

    private var jobs: [String: Job] = [:]
    private var procs: [String: Process] = [:]   // running process per job, so it can be stopped
    private var jobSession: [String: String] = [:]   // jobId → resume sessionId (to release the in-flight lock)
    private var resuming: Set<String> = []           // sessionIds with a turn in flight (guard --resume races)
    private var cancelIntent: Set<String> = []       // jobs asked to cancel before their process was tracked
    private let lock = NSLock()
    private var counter = 0
    private let maxRuntime: TimeInterval = 600   // 10 min hard cap per turn

    private static let claudePaths = [
        NSHomeDirectory() + "/.local/bin/claude",
        "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
        NSHomeDirectory() + "/.claude/local/claude"]
    private static var resolvedClaude: String? {
        claudePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    var available: Bool { Self.resolvedClaude != nil }

    /// Kick off a chat turn; returns a jobId to poll, `.busy` if a turn for the same
    /// resume-session is already running, or `.unavailable` if claude isn't found.
    func start(cwd: String, sessionId: String?, message: String) -> StartResult {
        guard let claude = Self.resolvedClaude else { return .unavailable }
        let resumeId = (sessionId?.isEmpty == false) ? sessionId : nil
        lock.lock()
        // Two `claude -p --resume <same id>` running at once would interleave writes
        // into the same session JSONL and corrupt the thread — refuse the second.
        if let sid = resumeId, resuming.contains(sid) { lock.unlock(); return .busy }
        counter += 1; let jid = "c\(counter)"; jobs[jid] = Job(status: "running")
        if let sid = resumeId { resuming.insert(sid); jobSession[jid] = sid }
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [maxRuntime] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: claude)
            // stream-json + partial messages → token-by-token output we relay live to
            // the phone (job.result grows while status stays "running").
            var args = ["-p", message, "--output-format", "stream-json", "--verbose",
                        "--include-partial-messages", "--permission-mode", "bypassPermissions"]
            if let sid = sessionId, !sid.isEmpty { args += ["--resume", sid] }
            p.arguments = args
            let dir = cwd.isEmpty ? NSHomeDirectory() : (cwd as NSString).expandingTildeInPath
            p.currentDirectoryURL = URL(fileURLWithPath: dir)
            // Give the agent's tools a real PATH (GUI apps launch with a minimal one).
            var env = ProcessInfo.processInfo.environment
            let extra = "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            env["PATH"] = env["PATH"].map { "\($0):\(extra)" } ?? extra
            p.environment = env

            let out = Pipe(); let err = Pipe()
            p.standardOutput = out; p.standardError = err
            do { try p.run() } catch {
                self.finish(jid, Job(status: "error", error: "couldn't launch claude: \(error.localizedDescription)")); return
            }
            // Track for /chat/cancel; if a cancel arrived during the launch window, honor it now.
            self.lock.lock(); self.procs[jid] = p
            let cancelNow = self.cancelIntent.remove(jid) != nil
            self.lock.unlock()
            if cancelNow { p.terminate() }
            // Hard cap the turn; terminating EOFs the pipe so the read loop below exits. Also
            // close the stdout read end so a leaked tool child that inherited the write end (and
            // exited claude already, so p.isRunning is false) can't pin the read loop forever —
            // closing forces availableData to return empty, the loop breaks, finish() runs and
            // releases the per-session in-flight lock instead of wedging the session.
            let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() }; try? out.fileHandleForReading.close() }
            DispatchQueue.global().asyncAfter(deadline: .now() + maxRuntime, execute: watchdog)
            // Drain stderr concurrently (surfaces a real failure reason on the phone).
            var errData = Data(); let errSem = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .utility).async { errData = err.fileHandleForReading.readDataToEndOfFile(); errSem.signal() }

            var accumulated = "", capturedSession: String?, finalResult: String?
            var isError = false, sawResult = false
            func handleLine(_ line: Data) {
                guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      let type = o["type"] as? String else { return }
                switch type {
                case "system":
                    if capturedSession == nil { capturedSession = o["session_id"] as? String }
                case "stream_event":
                    guard let ev = o["event"] as? [String: Any], let et = ev["type"] as? String else { return }
                    if et == "content_block_delta", let d = ev["delta"] as? [String: Any],
                       (d["type"] as? String) == "text_delta", let t = d["text"] as? String {
                        accumulated += t
                        self.update(jid, partial: accumulated, sessionId: capturedSession)
                    } else if et == "content_block_start", let cb = ev["content_block"] as? [String: Any],
                              (cb["type"] as? String) == "tool_use", let name = cb["name"] as? String {
                        accumulated += (accumulated.isEmpty ? "" : "\n") + "⚙ \(name)…\n"
                        self.update(jid, partial: accumulated, sessionId: capturedSession)
                    }
                case "result":
                    sawResult = true
                    isError = (o["is_error"] as? Bool) ?? false
                    if let sid = o["session_id"] as? String { capturedSession = sid }
                    finalResult = o["result"] as? String
                default: break
                }
            }
            // Read stdout line-by-line as it streams (availableData blocks until data/EOF).
            let handle = out.fileHandleForReading
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.subdata(in: buffer.startIndex..<nl)
                    buffer.removeSubrange(buffer.startIndex...nl)
                    if !line.isEmpty { handleLine(line) }
                }
            }
            if !buffer.isEmpty { handleLine(buffer) }
            p.waitUntilExit()
            watchdog.cancel()
            // Only read errData once the reader has finished (avoid racing it). If it's
            // still blocked in readDataToEndOfFile because an orphaned tool child inherited
            // the stderr write-end, CLOSE the read handle so the reader thread unblocks and
            // the pipe/thread are reclaimed instead of leaking for the rest of the session.
            let gotErr = errSem.wait(timeout: .now() + 2) == .success
            if !gotErr { try? err.fileHandleForReading.close() }
            let stderr = gotErr ? (String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") : ""

            let streamed = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalText = !streamed.isEmpty ? accumulated : (finalResult ?? "")
            if isError {
                let msg = !(finalResult ?? "").isEmpty ? finalResult! : (!stderr.isEmpty ? stderr : "claude returned an error")
                self.finish(jid, Job(status: "error", error: msg))
            } else if sawResult || !finalText.isEmpty {
                self.finish(jid, Job(status: "done", result: finalText, sessionId: capturedSession))
            } else {
                let code = p.terminationStatus
                let detail = !stderr.isEmpty ? stderr : "no output (exit \(code))"
                self.finish(jid, Job(status: "error", error: "claude exited \(code): \(String(detail.prefix(300)))"))
            }
        }
        return .started(jid)
    }

    func poll(_ jid: String) -> Job? { lock.lock(); defer { lock.unlock() }; return jobs[jid] }

    /// Stop a running turn (from the phone). Terminating the process EOFs its pipe, so
    /// the read loop finishes and reports whatever streamed so far + a "stopped" note.
    @discardableResult
    func cancel(_ jid: String) -> Bool {
        lock.lock()
        let p = procs[jid]; let running = jobs[jid]?.status == "running"
        // Running but not yet tracked (it's still in the launch→track window) → record intent
        // so the spawn terminates it the moment it's tracked, instead of slipping past Stop.
        if running && p == nil { cancelIntent.insert(jid) }
        lock.unlock()
        guard let p, running else { return running }   // report success when intent was queued
        p.terminate()
        return true
    }

    /// Terminate EVERY running turn (Panic Stop). Returns how many were killed.
    @discardableResult
    func cancelAll() -> Int {
        lock.lock()
        let running = procs.values.filter { $0.isRunning }
        for (jid, job) in jobs where job.status == "running" && procs[jid] == nil { cancelIntent.insert(jid) }
        lock.unlock()
        running.forEach { $0.terminate() }
        return running.count
    }

    private func finish(_ jid: String, _ job: Job) {
        lock.lock(); jobs[jid] = job; procs[jid] = nil
        if let sid = jobSession.removeValue(forKey: jid) { resuming.remove(sid) }   // release the in-flight lock
        // Evict old jobs so the map doesn't grow unbounded over a long session.
        if jobs.count > 24 {
            let keep = Set((max(1, counter - 23)...counter).map { "c\($0)" })
            jobs = jobs.filter { keep.contains($0.key) }
        }
        lock.unlock()
    }
    /// Live-update the running job's partial reply (the phone polls and renders it as it streams).
    private func update(_ jid: String, partial: String, sessionId: String?) {
        lock.lock(); defer { lock.unlock() }
        guard var j = jobs[jid], j.status == "running" else { return }
        j.result = partial; j.sessionId = sessionId; jobs[jid] = j
    }
}
