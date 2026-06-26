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

            let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
            do { try p.run() } catch {
                self.finish(jid, Job(status: "error", error: "couldn't launch claude")); return
            }
            let sem = DispatchSemaphore(value: 0)
            var data = Data()
            DispatchQueue.global(qos: .utility).async {
                data = out.fileHandleForReading.readDataToEndOfFile(); sem.signal()
            }
            if sem.wait(timeout: .now() + maxRuntime) == .timedOut {
                p.terminate()
                self.finish(jid, Job(status: "error", error: "timed out after \(Int(maxRuntime))s")); return
            }
            p.waitUntilExit()

            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let result = (obj["result"] as? String) ?? ""
                let sid = obj["session_id"] as? String
                let isErr = (obj["is_error"] as? Bool) ?? false
                self.finish(jid, Job(status: isErr ? "error" : "done",
                                     result: isErr ? nil : result, sessionId: sid,
                                     error: isErr ? (result.isEmpty ? "claude returned an error" : result) : nil))
            } else {
                let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                self.finish(jid, Job(status: raw.isEmpty ? "error" : "done",
                                     result: raw.isEmpty ? nil : raw,
                                     error: raw.isEmpty ? "no output from claude" : nil))
            }
        }
        return jid
    }

    func poll(_ jid: String) -> Job? { lock.lock(); defer { lock.unlock() }; return jobs[jid] }
    private func finish(_ jid: String, _ job: Job) { lock.lock(); jobs[jid] = job; lock.unlock() }
}
