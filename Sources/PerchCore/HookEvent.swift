import Foundation

/// A decoded Claude Code hook payload. Only `Sendable` value types are stored.
public struct HookEvent: Sendable {
    // Common fields (present on every event).
    public let eventName: String?      // hook_event_name
    public let sessionID: String?
    public let transcriptPath: String?
    public let cwd: String?
    public let permissionMode: String?

    // Tool events.
    public let toolName: String?
    public let toolInputSummary: String?   // one-line digest

    // Extracted tool_input fields (for risk parsing + diff/command preview).
    public let command: String?            // Bash
    public let filePath: String?           // Read/Write/Edit/...
    public let oldString: String?          // Edit
    public let newString: String?          // Edit
    public let content: String?            // Write
    public let url: String?                // WebFetch
    public let fileOffset: Int?            // Read (1-based start line)

    public let endpoint: String
    public let prettyJSON: String

    public var projectLabel: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return (cwd as NSString).lastPathComponent
    }

    public init(data: Data, endpoint: String) {
        self.endpoint = endpoint
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        self.eventName = object?["hook_event_name"] as? String
        self.sessionID = object?["session_id"] as? String
        self.transcriptPath = object?["transcript_path"] as? String
        self.cwd = object?["cwd"] as? String
        self.permissionMode = object?["permission_mode"] as? String
        self.toolName = object?["tool_name"] as? String

        let input = object?["tool_input"] as? [String: Any]
        self.command = input?["command"] as? String
        self.filePath = (input?["file_path"] as? String) ?? (input?["path"] as? String) ?? (input?["notebook_path"] as? String)
        self.oldString = input?["old_string"] as? String
        self.newString = input?["new_string"] as? String
        self.content = input?["content"] as? String
        self.url = input?["url"] as? String
        let off = input?["offset"]
        self.fileOffset = (off as? Int) ?? (off as? NSNumber)?.intValue

        if let input {
            self.toolInputSummary = Self.summarize(input)
        } else {
            self.toolInputSummary = nil
        }

        if let object,
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: pretty, encoding: .utf8) {
            self.prettyJSON = text
        } else {
            self.prettyJSON = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
        }
    }

    private static func summarize(_ input: [String: Any]) -> String {
        let priorityKeys = ["command", "file_path", "path", "pattern", "url", "query", "prompt"]
        for key in priorityKeys {
            if let value = input[key] as? String, !value.isEmpty {
                return value.replacingOccurrences(of: "\n", with: " ").trimmed(to: 160)
            }
        }
        let keys = input.keys.sorted().prefix(4).joined(separator: ", ")
        return keys.isEmpty ? "(no input)" : "{\(keys)}"
    }
}

extension String {
    func trimmed(to max: Int) -> String {
        count <= max ? self : String(prefix(max - 1)) + "…"
    }
}
