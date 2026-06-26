import Foundation

/// Token usage for one prompt, summed from the transcript.
public struct PromptUsage: Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreation: Int
    public var cacheRead: Int

    /// Everything billed on the input side (fresh input + cache writes + cache reads).
    public var totalInput: Int { inputTokens + cacheCreation + cacheRead }
    public var total: Int { totalInput + outputTokens }

    public static let zero = PromptUsage(inputTokens: 0, outputTokens: 0, cacheCreation: 0, cacheRead: 0)
}

/// Computes per-prompt token usage from a Claude Code session transcript.
///
/// There is no "tokens for this prompt" field — we derive it from the `.jsonl`
/// at `transcript_path` per the verified algorithm: skip non user/assistant
/// records, find the last *real* user-turn boundary (a user record whose content
/// is text, not a tool-result continuation), then sum `message.usage` of the
/// assistant records after it, **deduplicating by `requestId`** (keeping the
/// record with the highest `output_tokens`, i.e. the final non-streaming one).
public enum TranscriptReader {

    public static func lastPromptUsage(path: String) -> PromptUsage? {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return nil }

        let objects: [[String: Any]] = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            }
        guard !objects.isEmpty else { return nil }

        // Last real user-turn boundary.
        var boundary = -1
        for (i, obj) in objects.enumerated() where isRealUserBoundary(obj) {
            boundary = i
        }
        guard boundary >= 0 else { return nil }

        // Dedupe assistant usage by requestId, keeping the max-output record.
        var byRequest: [String: PromptUsage] = [:]
        var anon = 0
        for obj in objects[(boundary + 1)...] {
            guard (obj["type"] as? String) == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }

            let entry = PromptUsage(
                inputTokens: intValue(usage["input_tokens"]),
                outputTokens: intValue(usage["output_tokens"]),
                cacheCreation: intValue(usage["cache_creation_input_tokens"]),
                cacheRead: intValue(usage["cache_read_input_tokens"])
            )

            let requestID = (obj["requestId"] as? String)
                ?? (message["id"] as? String)
                ?? { anon += 1; return "anon-\(anon)" }()

            if let existing = byRequest[requestID], existing.outputTokens >= entry.outputTokens {
                continue
            }
            byRequest[requestID] = entry
        }
        guard !byRequest.isEmpty else { return nil }

        return byRequest.values.reduce(.zero) { acc, u in
            PromptUsage(
                inputTokens: acc.inputTokens + u.inputTokens,
                outputTokens: acc.outputTokens + u.outputTokens,
                cacheCreation: acc.cacheCreation + u.cacheCreation,
                cacheRead: acc.cacheRead + u.cacheRead
            )
        }
    }

    private static func isRealUserBoundary(_ obj: [String: Any]) -> Bool {
        guard (obj["type"] as? String) == "user",
              let message = obj["message"] as? [String: Any] else { return false }
        let content = message["content"]
        if content is String { return true }
        if let blocks = content as? [[String: Any]] {
            // A genuine user turn has at least one text block; a list of only
            // tool_result blocks is a mid-turn continuation, not a boundary.
            return blocks.contains { ($0["type"] as? String) == "text" }
        }
        return false
    }

    private static func intValue(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let n = any as? NSNumber { return n.intValue }
        return 0
    }
}
