// PromptSummarizer — shortens a long user prompt to a glanceable label by
// shelling out to the local `claude` CLI (Haiku). Runs hooks-free and without
// session persistence, so it neither triggers the user's verify/notify hooks
// nor writes a transcript (which would otherwise show up as its own "working"
// chat). Results are cached by prompt content, so each prompt is summarized once.

import Foundation

final class PromptSummarizer {
    static let shared = PromptSummarizer()

    /// Prompts shorter than this are shown verbatim; longer ones get summarized.
    static let threshold = 70

    private static let claudePaths = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                                      (NSHomeDirectory() + "/.claude/local/claude")]

    private var cache: [String: String] = [:]
    private var inflight: Set<String> = []
    private let lock = NSLock()
    private let q = DispatchQueue(label: "edgepanel.summarize", qos: .utility, attributes: .concurrent)

    /// A cached short label, or nil while one is computed. `onReady` fires on the
    /// main thread when the async summary lands.
    func shortLabel(for prompt: String, onReady: @escaping (String) -> Void) -> String? {
        let key = String(prompt.hashValue)
        lock.lock()
        if let s = cache[key] { lock.unlock(); return s }
        if inflight.contains(key) { lock.unlock(); return nil }
        inflight.insert(key)
        lock.unlock()

        q.async { [weak self] in
            let summary = Self.runClaude(prompt) ?? Self.fallback(prompt)
            guard let self else { return }
            self.lock.lock()
            self.cache[key] = summary
            self.inflight.remove(key)
            self.lock.unlock()
            DispatchQueue.main.async { onReady(summary) }
        }
        return nil
    }

    private static func fallback(_ s: String) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
        return one.count <= 64 ? one : String(one.prefix(63)) + "…"
    }

    private static func runClaude(_ prompt: String) -> String? {
        guard let claude = claudePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        // haiku for speed/cost · no transcript · only project settings (skips the
        // user's global hooks) · run in a temp dir with no project to load.
        p.arguments = ["-p", "--model", "haiku", "--no-session-persistence", "--setting-sources", "project"]
        p.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())

        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }

        let instruction = """
        In 8 words or fewer, summarize what this Claude Code prompt asks for. \
        Reply with ONLY the summary — no quotes, no preamble, no trailing period:

        \(prompt)
        """
        stdin.fileHandleForWriting.write(Data(instruction.utf8))
        stdin.fileHandleForWriting.closeFile()

        let done = DispatchSemaphore(value: 0)
        var data = Data()
        DispatchQueue.global(qos: .utility).async {
            data = stdout.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + 25) == .timedOut { p.terminate(); return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }

        var out = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Strip wrapping quotes / trailing punctuation the model sometimes adds.
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "\"'.“”"))
        return out.isEmpty ? nil : String(out.prefix(64))
    }
}
