import Foundation

/// Writes Claude Code's reasoning-effort level into a project's (or the global)
/// `.claude/settings.json` under the `effortLevel` key — the same key `UsageLoader.currentEffort`
/// reads back. The phone drives this via the LAN `/effort` route so a chat's effort can be
/// changed remotely. Mirrors `AllowlistWriter`'s atomic, locked read-modify-write so a concurrent
/// tap can't clobber the file or drop unrelated keys.
enum EffortWriter {
    /// Claude Code's five effort levels. This is the ONLY accepted set — input is validated
    /// strictly (case-insensitive) against it, not fuzzily normalized, so a bad value is rejected
    /// with a 400 rather than silently coerced.
    static let validEfforts: Set<String> = ["low", "medium", "high", "xhigh", "max"]

    /// Serializes the read-modify-write so two concurrent `/effort` calls can't clobber each other.
    private static let lock = NSLock()

    /// Validate an effort string against the accepted set. Returns the canonical lowercase form,
    /// or nil if it isn't one of the five levels.
    static func normalize(_ effort: String?) -> String? {
        let e = (effort ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return validEfforts.contains(e) ? e : nil
    }

    /// The settings.json file to write for a given cwd: the project's own `.claude/settings.json`
    /// when a cwd is supplied, else the global `~/.claude/settings.json`. Writing `effortLevel` here
    /// makes `currentEffort(cwd:)` (which checks the project dir first, then home) read it back.
    static func settingsURL(cwd: String) -> URL {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty
            ? URL(fileURLWithPath: NSHomeDirectory())
            : URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        return base.appendingPathComponent(".claude/settings.json")
    }

    /// Pure merge: return a new settings object with `effortLevel` set, preserving every other key
    /// of `existing` (including a pre-existing `permissions` block etc.). Kept separate from I/O so
    /// the merge is unit-testable without touching the filesystem.
    static func merged(into existing: [String: Any]?, effort: String) -> [String: Any] {
        var obj = existing ?? [:]
        obj["effortLevel"] = effort
        return obj
    }

    /// Validate `effort`, then atomically write it into the cwd's (or global) settings.json,
    /// preserving other keys. Returns false on invalid effort or any I/O/serialization failure.
    @discardableResult
    static func write(cwd: String, effort: String) -> Bool {
        guard let level = normalize(effort) else {
            NSLog("EdgePanel effort → rejected invalid level: \(effort)")
            return false
        }
        let url = settingsURL(cwd: cwd)
        lock.lock()
        defer { lock.unlock() }
        // Read the existing settings if present (preserve every other key); an absent or
        // unreadable/invalid file starts from an empty object so we still write the level.
        let existing = (FileManager.default.contents(atPath: url.path))
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        let obj = merged(into: existing, effort: level)
        guard let out = try? JSONSerialization.data(withJSONObject: obj,
                                                    options: [.prettyPrinted, .withoutEscapingSlashes]) else {
            NSLog("EdgePanel effort FAILED (serialize) — level not written: \(level)")
            return false
        }
        do {
            // Ensure the .claude dir exists (a fresh project may not have one yet).
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try out.write(to: url, options: .atomic)
            NSLog("EdgePanel effort → set \(level) in \(url.path)")
            return true
        } catch {
            NSLog("EdgePanel effort FAILED (write: \(error.localizedDescription)) — level not written: \(level)")
            return false
        }
    }
}
