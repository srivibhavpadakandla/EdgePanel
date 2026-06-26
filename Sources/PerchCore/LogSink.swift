import Foundation

/// Thread-safe logger that prints to stdout (visible under `swift run`) and
/// appends to a rotating-ish log file at `~/Library/Logs/Perch/perchd.log`,
/// which you can `tail -f` while testing the hook pipe.
public final class LogSink: @unchecked Sendable {
    public static let shared = LogSink()

    private let queue = DispatchQueue(label: "perch.log")
    private let fileURL: URL?
    private let dateFormatter: DateFormatter

    private init() {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Perch", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let logURL = dir.appendingPathComponent("perchd.log")
        // Don't let the log grow unbounded across launches.
        if let attrs = try? fm.attributesOfItem(atPath: logURL.path),
           let size = attrs[.size] as? Int, size > 5_000_000 {
            try? Data().write(to: logURL)
        }
        self.fileURL = logURL

        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        self.dateFormatter = df
    }

    public var logFilePath: String { fileURL?.path ?? "(none)" }

    public func info(_ message: String) {
        write("· \(message)")
    }

    /// Log a received hook event as a one-line summary. Full JSON is dumped only
    /// for permission decisions (small + useful); other events — especially
    /// PostToolUse carrying whole file contents — would bloat the log.
    public func event(_ event: HookEvent) {
        var header = "◆ \(event.endpoint)  event=\(event.eventName ?? "?")"
        if let project = event.projectLabel { header += "  project=\(project)" }
        if let session = event.sessionID { header += "  session=\(session.prefix(8))" }
        if let tool = event.toolName { header += "  tool=\(tool)" }
        if let summary = event.toolInputSummary { header += "  → \(summary)" }
        if event.endpoint == "/permission" {
            write(header + "\n" + indent(String(event.prettyJSON.prefix(1500))))
        } else {
            write(header)
        }
    }

    private func indent(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "    \($0)" }
            .joined(separator: "\n")
    }

    private func write(_ message: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let line = "[\(self.timestamp())] \(message)"
            print(line)
            fflush(stdout)
            if let url = self.fileURL, let data = (line + "\n").data(using: .utf8) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                } else {
                    try? data.write(to: url)
                }
            }
        }
    }

    private func timestamp() -> String {
        dateFormatter.string(from: Date())
    }
}
