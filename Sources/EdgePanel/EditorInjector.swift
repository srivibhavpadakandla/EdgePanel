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
import ApplicationServices   // Accessibility (AXUIElement) — verify focus landed on a text input

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
    /// ONE injection machine-wide at a time — the clipboard and keystroke stream are process-global,
    /// so two concurrent injects (different sessions) would clobber each other's clipboard and
    /// interleave keystrokes. The per-session `resuming` guard doesn't cover cross-session.
    private static let injectLock = NSLock()

    @discardableResult
    func inject(text: String, sessionId: String, cwd: String) -> Bool {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        Self.injectLock.lock()
        defer { Self.injectLock.unlock() }
        let pb = NSPasteboard.general
        // AppKit (find editor, set clipboard, activate) on main — snapshot the user's
        // clipboard so we can restore it after the paste (don't destroy their copied text).
        // Snapshot the prior clipboard + the changeCount right after WE set it, so the restore
        // can tell "still our text" from "user copied something new" without comparing strings.
        let saved: (prior: String?, change: Int)? = onMain {
            guard let app = self.runningEditor() else { return nil }
            let prior = pb.string(forType: .string)
            pb.clearContents(); pb.setString(text, forType: .string)
            app.activate(options: [.activateIgnoringOtherApps])
            return (prior, pb.changeCount)
        }
        guard let saved else { return false }
        // Restore the user's clipboard, clearing our injected text — but only if they haven't copied
        // something new since (changeCount unchanged). Gating on changeCount (not string-equality)
        // also restores correctly when the prior clipboard was empty.
        func restoreClipboard() {
            onMain {
                guard pb.changeCount == saved.change else { return }   // user copied since → leave it
                pb.clearContents()
                if let p = saved.prior { pb.setString(p, forType: .string) }
            }
        }
        // Activation is ASYNC. ABORT if the editor never actually became frontmost — otherwise the
        // paste + Return would fire into whatever app IS frontmost (browser, terminal, a source
        // file). Better to fail the inject than type the message into the wrong window.
        guard waitFrontmost(timeout: 1.8) else {
            NSLog("EdgePanel inject ABORTED — editor never became frontmost; not typing into the wrong app")
            restoreClipboard()
            return false
        }
        focusChatInput()
        pasteOnce()
        submitReturn()

        var landed = false
        for _ in 0..<7 {
            // Verify: the typed prompt appears in the transcript (submitted = a user record,
            // queued mid-turn = a queued_command attachment — both count).
            let deadline = Date().addingTimeInterval(1.5)
            while Date() < deadline {
                usleep(330_000)
                if UsageLoader.typedPromptLanded(sessionId: sessionId, cwd: cwd, needle: needle) { landed = true; break }
            }
            if landed { break }
            // The draft is likely sitting in the input unsubmitted → re-submit (NO re-paste, so
            // it can't accumulate). Re-activate first in case another app stole focus.
            ensureFrontmost()
            submitReturn()
        }
        // The paste was consumed early (focus→paste→submit); by now the retry loop has waited
        // seconds, so restore synchronously (inside the lock) — a deferred restore could clobber
        // the NEXT injection's clipboard after the lock released.
        restoreClipboard()
        return landed
    }

    // MARK: - keystroke steps

    /// Focus the Claude Code chat input (Cmd+Esc). When Accessibility is granted, VERIFY a text
    /// field actually took focus — the extension's Cmd+Esc is a TOGGLE, so if it blurred (or
    /// landed on a button/tree) we issue it once more to land on the input.
    private func focusChatInput() {
        let ok = runOsascript("tell application \"System Events\" to key code 53 using command down", timeout: 5)
        if !ok, let cli = Self.cliclick { run(cli, ["kd:cmd", "kp:esc", "ku:cmd"]) }
        usleep(480_000)
        if AXIsProcessTrusted(), let el = focusedAXElement(), !isTextLike(el) {
            _ = runOsascript("tell application \"System Events\" to key code 53 using command down", timeout: 5)
            usleep(480_000)
        }
    }
    /// Paste the clipboard — exactly once (callers never call this twice → no accumulation).
    private func pasteOnce() {
        let ok = runOsascript("tell application \"System Events\" to keystroke \"v\" using command down", timeout: 5)
        if !ok, let cli = Self.cliclick { run(cli, ["kd:cmd", "t:v", "ku:cmd"]) }
        usleep(380_000)
    }
    /// Press Return to submit/queue whatever is already in the focused input — re-submitting on
    /// retry without pasting again (the first pasteOnce already put the text there).
    private func submitReturn() {
        let ok = runOsascript("tell application \"System Events\" to key code 36", timeout: 4)
        if !ok, let cli = Self.cliclick { run(cli, ["kp:return"]) }
    }

    /// SAFE diagnostic (no paste, no submit): activate the editor, focus the chat input, and
    /// report what Accessibility sees — so we can validate the focus mechanism without typing
    /// anything into the real conversation. Returns role/value-length/placeholder of the focus.
    func probeFocus() -> [String: String] {
        let found = onMain { () -> Bool in
            guard let app = self.runningEditor() else { return false }
            app.activate(options: [.activateIgnoringOtherApps]); return true
        }
        guard found else { return ["editor": "none-running"] }
        waitFrontmost(timeout: 1.8)
        focusChatInput()
        var out: [String: String] = ["editor": "found", "axTrusted": AXIsProcessTrusted() ? "yes" : "no"]
        if let el = focusedAXElement() {
            var r: CFTypeRef?; AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &r)
            out["focusedRole"] = (r as? String) ?? "?"
            var v: CFTypeRef?; AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v)
            out["valueLen"] = "\((v as? String)?.count ?? -1)"
            var pl: CFTypeRef?; AXUIElementCopyAttributeValue(el, kAXPlaceholderValueAttribute as CFString, &pl)
            out["placeholder"] = (pl as? String) ?? ""
        } else {
            out["focusedRole"] = "none-or-AX-unavailable"
        }
        return out
    }

    // MARK: - frontmost + accessibility helpers

    /// Block until the target editor is the frontmost app (activation is async), up to `timeout`,
    /// then a small settle — so keystrokes can't fire into the previously-frontmost app.
    @discardableResult
    private func waitFrontmost(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let up = onMain { () -> Bool in
                guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
                return self.editorBundles.contains(id)
            }
            if up { usleep(250_000); return true }
            usleep(120_000)
        }
        return false   // never confirmed frontmost → caller aborts rather than typing into the wrong app
    }
    /// Re-activate the editor (used before a re-submit, in case another app stole focus).
    private func ensureFrontmost() {
        _ = onMain { self.runningEditor()?.activate(options: [.activateIgnoringOtherApps]) ?? false }
        usleep(250_000)
    }

    /// The system-wide focused UI element (nil if Accessibility isn't granted or none focused).
    private func focusedAXElement() -> AXUIElement? {
        let sys = AXUIElementCreateSystemWide()
        var f: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &f) == .success,
              let el = f, CFGetTypeID(el) == AXUIElementGetTypeID() else { return nil }
        return (el as! AXUIElement)
    }
    /// True if `el` is a text-entry control — OR a webview/container/opaque role we must NOT disturb.
    /// The Electron Claude Code chat input surfaces to system-wide AX as AXGroup / AXWebArea /
    /// AXScrollArea (not a text role), so treating those as "leave it" stops the corrective second
    /// Cmd+Esc from blurring a correctly-focused input. Only a DEFINITELY-wrong role (button, list,
    /// outline) triggers the corrective toggle.
    private func isTextLike(_ el: AXUIElement) -> Bool {
        var r: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &r) == .success,
              let role = r as? String else { return true }
        // NB: deliberately NOT including AXScrollArea (the editor's integrated TERMINAL is a scroll
        // area — a paste+Return there would RUN as a shell command) or AXUnknown (ambiguous). Those
        // get the corrective toggle back to the chat input. Only the webview chat-input container
        // roles are left alone.
        let leaveAlone: Set<String> = [kAXTextAreaRole as String, kAXTextFieldRole as String,
                                       "AXComboBox", "AXGroup", "AXWebArea"]
        return leaveAlone.contains(role)
    }

    /// Interrupt the running turn in the live editor session (Escape stops generation).
    /// MUST be called off the main thread.
    @discardableResult
    func interrupt() -> Bool {
        // Serialize with injections (shared keyboard focus) so Stop's Cmd+Esc/Esc can't interleave
        // with a different-session inject's paste/submit. BOUNDED wait (2s) so Stop stays responsive
        // even if an inject is mid-flight — best-effort past the deadline rather than hang.
        let gotLock = Self.injectLock.lock(before: Date().addingTimeInterval(2))
        defer { if gotLock { Self.injectLock.unlock() } }
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
