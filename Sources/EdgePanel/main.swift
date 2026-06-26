import AppKit

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
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
