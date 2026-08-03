import Foundation
import Testing
@testable import EdgePanel

// Locks EffortWriter's validation + settings.json merge: only the five real levels are accepted,
// and writing effortLevel must preserve every other key already in the file.

@Suite("EffortWriter · validation")
struct EffortWriterValidationTests {
    @Test("accepts the five levels case-insensitively", arguments: [
        "low", "medium", "high", "xhigh", "max", "HIGH", " Max ", "XHigh"
    ])
    func acceptsValid(_ raw: String) {
        #expect(EffortWriter.normalize(raw) != nil)
    }

    @Test("normalizes to canonical lowercase")
    func canonicalizes() {
        #expect(EffortWriter.normalize("HIGH") == "high")
        #expect(EffortWriter.normalize(" Max ") == "max")
        #expect(EffortWriter.normalize("xhigh") == "xhigh")
    }

    @Test("rejects anything outside the five levels", arguments: [
        "", "ultra", "extra", "medium-high", "none", "hi", "xhi", "maximum"
    ])
    func rejectsInvalid(_ raw: String) {
        #expect(EffortWriter.normalize(raw) == nil)
    }

    @Test("rejects nil")
    func rejectsNil() {
        #expect(EffortWriter.normalize(nil) == nil)
    }
}

@Suite("EffortWriter · settings merge")
struct EffortWriterMergeTests {
    @Test("sets effortLevel on an empty/absent settings object")
    func setsOnEmpty() {
        let out = EffortWriter.merged(into: nil, effort: "high")
        #expect(out["effortLevel"] as? String == "high")
        #expect(out.count == 1)
    }

    @Test("preserves all other keys when setting effortLevel")
    func preservesOtherKeys() {
        let existing: [String: Any] = [
            "permissions": ["allow": ["Bash(git *)"]],
            "model": "opus",
            "effortLevel": "low",   // pre-existing level must be overwritten
        ]
        let out = EffortWriter.merged(into: existing, effort: "max")
        #expect(out["effortLevel"] as? String == "max")
        #expect(out["model"] as? String == "opus")
        let perms = out["permissions"] as? [String: Any]
        #expect((perms?["allow"] as? [String]) == ["Bash(git *)"])
    }

    @Test("settingsURL points at project .claude when cwd given, home when empty")
    func settingsURLRouting() {
        let proj = EffortWriter.settingsURL(cwd: "/tmp/myproj")
        #expect(proj.path == "/tmp/myproj/.claude/settings.json")
        let global = EffortWriter.settingsURL(cwd: "")
        #expect(global.path == (NSHomeDirectory() as NSString).appendingPathComponent(".claude/settings.json"))
    }

    @Test("write round-trips: currentEffort reads back what was written")
    func writeRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("edgepanel-effort-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(EffortWriter.write(cwd: dir.path, effort: "xhigh"))
        #expect(UsageLoader.currentEffort(cwd: dir.path) == "xhigh")

        // Overwrite preserves an unrelated key added alongside it.
        let settings = dir.appendingPathComponent(".claude/settings.json")
        var obj = (try? JSONSerialization.jsonObject(with: Data(contentsOf: settings))) as? [String: Any] ?? [:]
        obj["model"] = "sonnet"
        try JSONSerialization.data(withJSONObject: obj).write(to: settings)

        #expect(EffortWriter.write(cwd: dir.path, effort: "low"))
        let after = (try? JSONSerialization.jsonObject(with: Data(contentsOf: settings))) as? [String: Any]
        #expect(after?["effortLevel"] as? String == "low")
        #expect(after?["model"] as? String == "sonnet")
    }

    @Test("write rejects an invalid level without creating a file")
    func writeRejectsInvalid() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("edgepanel-effort-bad-\(UUID().uuidString)")
        #expect(!EffortWriter.write(cwd: dir.path, effort: "ultra"))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(".claude/settings.json").path))
    }
}
