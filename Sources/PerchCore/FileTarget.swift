import Foundation

/// The file (and optionally line) Claude last touched, so the capsule can deep-
/// link the editor straight to it instead of just raising a window.
public struct FileTarget: Sendable, Equatable {
    public let path: String
    public let line: Int?
    public init(path: String, line: Int?) { self.path = path; self.line = line }
}

/// Pure helpers for turning a hook event into an editor deep link
/// (`vscode://file/<abs-path>:<line>`). No AppKit, no @MainActor — reusable and
/// testable, and safe to call from the loopback handler.
public enum EditorLink {
    /// Tools whose `file_path` is the thing the user is "working on".
    static let fileTools: Set<String> = ["Read", "Write", "Edit", "MultiEdit", "NotebookEdit"]

    /// The absolute file (and a line, free from Read's `offset`) for a tool event.
    public static func target(for event: HookEvent) -> FileTarget? {
        guard let tool = event.toolName, fileTools.contains(tool),
              let path = event.filePath, path.hasPrefix("/") else { return nil }
        // Read's `offset` is where Claude started paging — only treat it as a jump
        // target when it's a real offset (not line 1). Edits have no line field;
        // opening the right file at the top is good enough and avoids a file read.
        let line = (tool == "Read") ? event.fileOffset.flatMap { $0 > 1 ? $0 : nil } : nil
        return FileTarget(path: path, line: line)
    }

    /// URL scheme for a given editor bundle id. Defaults to plain VS Code.
    public static func scheme(forBundleID id: String) -> String {
        switch id {
        case "com.microsoft.VSCodeInsiders": return "vscode-insiders"
        case "com.todesktop.230313mzl4w4u92": return "cursor"   // Cursor
        case "com.vscodium.codium": return "vscodium"
        case "com.visualstudio.code.oss": return "code-oss"
        default: return "vscode"
        }
    }

    /// `scheme://file/<percent-encoded-abs-path>[:line]`. Keeps `/` literal but
    /// escapes spaces etc., which the handlers require.
    public static func deepLinkURL(scheme: String, path: String, line: Int?) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "/-._~")
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        var string = "\(scheme)://file\(encoded)"   // encoded keeps its leading "/"
        if let line { string += ":\(line)" }
        return URL(string: string)
    }
}
