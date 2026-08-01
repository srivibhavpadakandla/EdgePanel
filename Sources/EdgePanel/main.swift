import AppKit
import Darwin

// EdgePanel — a Claude Code usage + approval panel that docks just off the right
// screen edge and slides in when the cursor jams against that edge.
//
// Phase 0 ships only the window scaffolding + hover-reveal mechanic (empty panel,
// no data). Later phases stand up PerchCore's loopback HTTP hook server and
// render the live Usage view + inline permission approval.
//
// Like Perch, EdgePanel runs as a background agent: `.accessory` activation
// policy means no Dock icon, a menu-bar item only, and — paired with a
// non-activating NSPanel — it never steals focus from the editor.
//
// `main.swift` top-level code is nonisolated, but at process start we are on the
// main thread (the main actor's executor), so we assert that isolation to touch
// the @MainActor AppDelegate and NSApplication.
if CommandLine.arguments.dropFirst().first == "--edgepanel-process-group-wrapper",
   CommandLine.arguments.count >= 3 {
    // ChatRunner re-execs Claude through this tiny mode so every remote turn owns a process
    // group. Panic/Stop can then signal the entire tree, including shell/tool grandchildren.
    _ = setpgid(0, 0)
    let forwarded = Array(CommandLine.arguments.dropFirst(2))
    var cArgs = forwarded.map { strdup($0) } + [nil]
    _ = cArgs.withUnsafeMutableBufferPointer { buf in
        execv(buf[0], buf.baseAddress)
    }
    _exit(127)
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
