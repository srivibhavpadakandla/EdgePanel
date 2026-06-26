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

    private var jobs: [String: Job] = [:]
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

    /// Kick off a chat turn; returns a jobId to poll, or nil if claude isn't found.
    func start(cwd: String, sessionId: String?, message: String) -> String? {
        guard let claude = Self.resolvedClaude else { return nil }
        lock.lock(); counter += 1; let jid = "c\(counter)"; jobs[jid] = Job(status: "running"); lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [maxRuntime] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: claude)
            var args = ["-p", message, "--output-format", "json", "--permission-mode", "bypassPermissions"]
            if let sid = sessionId, !sid.isEmpty { args += ["--resume", sid] }
            p.arguments = args
            let dir = cwd.isEmpty ? NSHomeDirectory() : (cwd as NSString).expandingTildeInPath
            p.currentDirectoryURL = URL(fileURLWithPath: dir)
            // Give the agent's tools a real PATH (GUI apps launch with a minimal one).
            var env = ProcessInfo.processInfo.environment
            let extra = "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            env["PATH"] = env["PATH"].map { "\($0):\(extra)" } ?? extra
            p.environment = env

            // Capture stderr too — so a real failure (resume conflict, bad cwd, auth)
            // surfaces a reason on the phone instead of a blank "doesn't send". Both
            // pipes are drained concurrently to avoid a full-buffer deadlock.
            let out = Pipe(); let err = Pipe()
            p.standardOutput = out; p.standardError = err
            do { try p.run() } catch {
                self.finish(jid, Job(status: "error", error: "couldn't launch claude: \(error.localizedDescription)")); return
            }
            let sem = DispatchSemaphore(value: 0), errSem = DispatchSemaphore(value: 0)
            var data = Data(), errData = Data()
            DispatchQueue.global(qos: .utility).async { data = out.fileHandleForReading.readDataToEndOfFile(); sem.signal() }
            DispatchQueue.global(qos: .utility).async { errData = err.fileHandleForReading.readDataToEndOfFile(); errSem.signal() }
            if sem.wait(timeout: .now() + maxRuntime) == .timedOut {
                p.terminate()
                self.finish(jid, Job(status: "error", error: "timed out after \(Int(maxRuntime))s — the session may be busy on your Mac")); return
            }
            p.waitUntilExit()
            _ = errSem.wait(timeout: .now() + 2)
            let stderr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let result = (obj["result"] as? String) ?? ""
                let sid = obj["session_id"] as? String
                let isErr = (obj["is_error"] as? Bool) ?? false
                let errMsg = !result.isEmpty ? result : (!stderr.isEmpty ? stderr : "claude returned an error")
                self.finish(jid, Job(status: isErr ? "error" : "done",
                                     result: isErr ? nil : result, sessionId: sid,
                                     error: isErr ? errMsg : nil))
            } else {
                let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let code = p.terminationStatus
                let ok = code == 0 && !raw.isEmpty
                let detail = !stderr.isEmpty ? stderr : (raw.isEmpty ? "no output" : raw)
                self.finish(jid, Job(status: ok ? "done" : "error",
                                     result: ok ? raw : nil,
                                     error: ok ? nil : "claude exited \(code): \(String(detail.prefix(300)))"))
            }
        }
        return jid
    }

    func poll(_ jid: String) -> Job? { lock.lock(); defer { lock.unlock() }; return jobs[jid] }
    private func finish(_ jid: String, _ job: Job) { lock.lock(); jobs[jid] = job; lock.unlock() }
}
