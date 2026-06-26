# EdgePanel

> A macOS edge-docked hover panel for Claude Code — live usage, working-chat tracking, and inline permission approval, one cursor-flick away.

Slam your cursor to the right edge of the screen and EdgePanel slides in. Move away and it slides out. No dock icon, no window to manage, and it never steals focus from your editor.

![EdgePanel](docs/panel.png)

## What it does

- **Hover-reveal at the screen edge.** A non-activating panel docked just off the right edge; the cursor jamming the edge pixel slides it in, with hysteresis + a dismiss delay so it never flickers. Works over fullscreen apps.
- **Live plan usage.** Your 5-hour and weekly limits — percent, reset countdown, and burn rate — straight from Claude Code's own usage endpoint.
- **Working now.** Which chats are *mid-response right now*: the project, the prompt you gave it (auto-summarized by Claude when it's long), a live clock since you hit enter, and the tokens that turn has used.
- **Days-used calendar.** A GitHub-style heatmap of your Claude Code activity this month, with a streak badge.
- **5-hour spend + per-model split.** Estimated API-rate cost for the current window, broken down Opus / Sonnet / Haiku.
- **Recent activity.** The last tool calls of your active session, parsed from the transcript. Click a file row to open it.
- **Inline permission approval** *(optional, hook-wired).* Approve / Deny / Always on tool requests right from the panel — risk-colored, with a command or diff preview. The panel auto-reveals when a request fires and won't hide until you decide.

## Requirements

- macOS 14+
- Swift 6 toolchain (Xcode 16+ or a standalone Swift toolchain)
- [Claude Code](https://claude.com/claude-code) (for the usage data and optional hooks)

## Get it

```sh
git clone https://github.com/srivibhavpadakandla/EdgePanel.git
cd EdgePanel
swift build -c release --product EdgePanel
.build/release/EdgePanel
```

It runs as a menu-bar agent (a `sidebar.right` icon — no dock icon). Flick your cursor to the right screen edge to reveal the panel. Right-click the menu-bar icon to quit.

## How it works

**The window.** A borderless, non-activating `NSPanel` (`.nonactivatingPanel`, `level = .statusBar`, `collectionBehavior` spanning all spaces + fullscreen) docked off the right edge of the rightmost display. A global `NSEvent` mouse-moved monitor (no Accessibility permission needed) detects the cursor at the literal edge pixel and animates the frame in; a wider hysteresis band + a ~400 ms dismiss timer kill boundary flicker.

**The data — no hooks needed.** Everything in the panel is read from disk:

- Plan % / weekly come from Claude Code's `/api/oauth/usage` endpoint (keychain token), cached to `~/ClaudeUsage/plan.json`.
- Spend, the per-model split, and the calendar are aggregated from your `~/.claude/projects/**/*.jsonl` transcripts.
- "Working now" + the activity feed are parsed live from those transcripts — a turn counts as *working* until its final assistant message reports `stop_reason: end_turn`.
- Long prompts are shortened by shelling out to your local `claude` CLI (Haiku, `--no-session-persistence`, hooks-free), cached per prompt so each is summarized once.

**Live status + inline approval — optional, hook-wired.** EdgePanel embeds a loopback-only HTTP/1.1 server (`PerchCore`) on `127.0.0.1:8787`. Point Claude Code's `"type":"http"` hooks at it for live run status and a **held** `/permission` round-trip: the panel auto-reveals, you tap a button, and the decision returns to Claude Code as `permissionDecision` JSON. If EdgePanel isn't running, the hooks fail open (non-blocking) and Claude Code behaves normally.

Add to a project's `.claude/settings.json`:

```jsonc
{
  "hooks": {
    "PreToolUse":       [{ "matcher": ".*", "hooks": [{ "type": "http", "url": "http://127.0.0.1:8787/permission", "timeout": 30 }] }],
    "PostToolUse":      [{ "matcher": ".*", "hooks": [{ "type": "http", "url": "http://127.0.0.1:8787/event", "timeout": 5 }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:8787/event", "timeout": 5 }] }],
    "Stop":             [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:8787/event", "timeout": 5 }] }]
  }
}
```

> The `/permission` gate only fires when Claude Code actually asks for permission, so it won't surface in `bypassPermissions` mode. `--no-session-persistence` summarizer calls are filtered out of the panel.

## Architecture

| Path | Role |
|---|---|
| `Sources/PerchCore/HTTPServer.swift` | loopback-only HTTP/1.1 server (`NWListener`) |
| `Sources/PerchCore/HookEvent.swift` | decodes Claude Code hook payloads |
| `Sources/PerchCore/RiskEngine.swift` | classifies tool risk (read / write / danger) |
| `Sources/EdgePanel/EdgePanelWindow.swift` | the docked `NSPanel` + edge-stick hover state machine |
| `Sources/EdgePanel/UsageData.swift` | transcript + plan aggregation, working-session detection |
| `Sources/EdgePanel/UsageStore.swift` | observable store, polling + refresh |
| `Sources/EdgePanel/UsageView.swift` | the SwiftUI panel UI |
| `Sources/EdgePanel/EdgePanelState.swift` | hook ingestion + the held permission gate |
| `Sources/EdgePanel/PromptSummarizer.swift` | `claude`-CLI prompt summaries |
| `Sources/EdgePanel/ClaudeAnims.swift` | the pixel mascot renderer |

### Environment knobs

| Var | Default | Effect |
|---|---|---|
| `EDGEPANEL_PORT` | `8787` | HTTP server port |
| `EDGEPANEL_DECISION_TIMEOUT` | `20` | seconds a held permission waits before falling through to the native prompt |
| `EDGEPANEL_DEBUG` | off | enables a test-only `POST /debug/decide` (`allow`/`deny`) |

## Notes

- Window scaffolding and hook plumbing reuse **PerchCore** (from the Perch notch overlay).
- The pixel mascot is rendered from [ClaudePix](https://claudepix.vercel.app/) sprites.
- Not affiliated with Anthropic. "Claude" and "Claude Code" are Anthropic's.
