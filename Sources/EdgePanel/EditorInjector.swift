// EditorInjector — deliver a phone message into the LIVE Claude Code session open in
// VS Code / Cursor, instead of forking a separate `claude --resume` process (which
// clashes with a session that's actively in use). It focuses the editor's Claude Code
// chat input (the extension's `claude-vscode.focus` command, bound to Cmd+Escape),
// pastes the text, and hits Return — so the message lands in the running chat exactly
// like you typed it (queued if a turn is mid-flight, submitted if idle).
//
// Keystrokes go through System Events (AppleScript / Accessibility) as PRIMARY — the
// Claude Code input is an Electron/Chromium webview that honors raw CGEvents (cliclick)
// inconsistently, but honors the Accessibility path reliably. cliclick is the fallback.

import AppKit

final class EditorInjector: @unchecked Sendable {
    static let shared = EditorInjector()

    // Bundle ids of editors whose Claude Code extension uses Cmd+Escape to focus input.
    private let editorBundles = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
        "com.vscodium.codium", "com.todesktop.230313mzl4w4u92",   // Cursor
    ]

    private static let cliclickPaths = ["/opt/homebrew/bin/cliclick", "/usr/local/bin/cliclick"]
    private static var cliclick: String? { cliclickPaths.first { FileManager.default.isExecutableFile(atPath: $0) } }

    /// The editor to inject into — prefer the one you're actually looking at (frontmost),
    /// then any running editor. (List order alone could target VS Code while you're in Cursor.)
    private func runningEditor() -> NSRunningApplication? {
        if let front = NSWorkspace.shared.frontmostApplication,
           let id = front.bundleIdentifier, editorBundles.contains(id) { return front }
        for id in editorBundles {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first { return app }
        }
        return nil
    }

    /// Can we deliver to the live editor session right now? (an editor is running.)
    var available: Bool { runningEditor() != nil }

    /// Run AppKit work on the main thread (inject/interrupt are dispatched off the server
    /// thread by the caller, so a sync hop here is safe and non-deadlocking).
    private func onMain<T>(_ work: @escaping () -> T) -> T {
        Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }

    /// Type `text` into the live Claude Code chat in the frontmost editor, and CONFIRM it
    /// landed by watching the session transcript for the new typed prompt — retrying if the
    /// first focus/paste didn't take (the extension's Cmd+Esc focus can toggle the input off
    /// when it's already focused, so a single blind paste isn't reliable). Returns true only
    /// when the message is verified in the transcript. MUST be called off the main thread.
    @discardableResult
    func inject(text: String, sessionId: String, cwd: String) -> Bool {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        let pb = NSPasteboard.general
        // AppKit (find editor, set clipboard, activate) on main — snapshot the user's
        // clipboard so we can restore it after the paste (don't destroy their copied text).
        let saved: String? = onMain {
            guard let app = self.runningEditor() else { return nil }
            let prior = pb.string(forType: .string)
            pb.clearContents(); pb.setString(text, forType: .string)
            app.activate(options: [.activateIgnoringOtherApps])
            return prior ?? ""        // "" sentinel = editor found (nil only when none)
        }
        guard saved != nil else { return false }
        usleep(650_000)                                  // let the editor come forward

        var landed = false
        for attempt in 0..<3 {
            // A slow transcript flush from a PRIOR attempt may have already delivered the
            // message — re-check before pasting again so we never double-submit.
            if attempt > 0 {
                if UsageLoader.typedPromptLanded(sessionId: sessionId, cwd: cwd, needle: needle) { landed = true; break }
                _ = onMain { self.runningEditor()?.activate(options: [.activateIgnoringOtherApps]); return 0 }
                usleep(400_000)
            }
            pasteAndSubmit()
            // Verify: watch the transcript for the typed prompt to appear (submitted = a user
            // record, queued mid-turn = a queued_command attachment — both count).
            let deadline = Date().addingTimeInterval(4)
            while Date() < deadline {
                usleep(400_000)
                if UsageLoader.typedPromptLanded(sessionId: sessionId, cwd: cwd, needle: needle) { landed = true; break }
            }
            if landed { break }
        }

        // Restore the user's clipboard once we're done — but only if our text is still there
        // (don't clobber something they copied in the meantime).
        if let prior = saved, !prior.isEmpty {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                self.onMain { if pb.string(forType: .string) == text { pb.clearContents(); pb.setString(prior, forType: .string) } }
            }
        }
        return landed
    }

    /// One focus → paste → submit pass. PRIMARY: System Events (Accessibility) — Electron/
    /// Chromium honors these synthetic events far more reliably than raw CGEvents (cliclick).
    private func pasteAndSubmit() {
        let typed = runOsascript("""
        tell application "System Events"
          key code 53 using command down
          delay 0.45
          keystroke "v" using command down
          delay 0.6
          key code 36
        end tell
        """, timeout: 6)
        if !typed, let cli = Self.cliclick {             // fallback: cliclick CGEvents
            run(cli, ["kd:cmd", "kp:esc", "ku:cmd"]); usleep(500_000)
            run(cli, ["kd:cmd", "t:v", "ku:cmd"]); usleep(900_000)
            run(cli, ["kp:return"])
        }
    }

    /// Interrupt the running turn in the live editor session (Escape stops generation).
    /// MUST be called off the main thread.
    @discardableResult
    func interrupt() -> Bool {
        let found: Bool = onMain {
            guard let app = self.runningEditor() else { return false }
            app.activate(options: [.activateIgnoringOtherApps]); return true
        }
        guard found else { return false }
        usleep(450_000)
        let ok = runOsascript("""
        tell application "System Events"
          key code 53 using command down
          delay 0.3
          key code 53
        end tell
        """, timeout: 5)
        if !ok, let cli = Self.cliclick { run(cli, ["kd:cmd","kp:esc","ku:cmd"]); usleep(250_000); run(cli, ["kp:esc"]) }
        return true
    }

    /// Run an AppleScript, killing it if it exceeds `timeout` so a first-run Automation
    /// permission prompt can't hang the HTTP request. Returns true on clean exit (granted).
    @discardableResult
    private func runOsascript(_ script: String, timeout: TimeInterval) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        p.standardError = Pipe(); p.standardOutput = Pipe()
        do { try p.run() } catch { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(100_000) }
        if p.isRunning { p.terminate(); return false }
        return p.terminationStatus == 0
    }

    private func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }
}
