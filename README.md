# EdgePanel

> A macOS edge-docked hover panel for Claude Code — live usage, working-chat tracking, and inline permission approval, one cursor-flick away.

Slam your cursor to the right edge of the screen and EdgePanel slides in. Move away and it slides out. No dock icon, no window to manage, and it never steals focus from your editor.

![EdgePanel](docs/panel.png)

## What it does

- **Hover-reveal at the screen edge.** A non-activating panel docked just off the right edge; the cursor jamming the edge pixel slides it in, with hysteresis + a dismiss delay so it never flickers. Works over fullscreen apps.
- **Live plan usage.** Your 5-hour and weekly limits — percent, reset countdown, and burn rate — straight from Claude Code's own usage endpoint.
- **Working now.** Which chats are *mid-response right now*: the project, the prompt you gave it (auto-summarized by Claude when it's long), a live clock since you hit enter, and the tokens that turn has used.
- **Days-used calendar.** A GitHub-style heatmap of your Claude Code activity this month, with a streak badge.
- **5-hour spend.** Estimated API-rate cost for the current window.
- **Recent chats.** Your latest Claude Code sessions, named by Claude Code's own `ai-title` (or a summarized first prompt). Click one to open its project in VS Code.
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
- Spend and the calendar are aggregated from your `~/.claude/projects/**/*.jsonl` transcripts.
- "Working now" + recent chats are parsed live from those transcripts — a turn counts as *working* until its final assistant message reports `stop_reason: end_turn`.
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

## iPhone companion (`ios/`)

A SwiftUI app that mirrors the panel on your phone — plan %, working-now (live
timer + tokens), the days-used calendar, weekly, 5H spend, and recent chats —
plus a **Live Activity / Dynamic Island** timer while a prompt runs.

```sh
cd ios
xcodegen generate
open EdgePanelMobile.xcodeproj      # run on a device or the iPhone 17 Pro simulator
```

**Pairing.** Mac: menu-bar icon → **Pair iPhone…** shows a QR (host + token).
Phone: **gear → Scan QR from your Mac** (or type the address + token). The Mac
serves a token-protected `GET /snapshot` on `:8788` (and `POST /open` to open a
chat on the Mac). All traffic is direct phone↔Mac — nothing leaves your devices.

**Reaching the Mac.** On a home network with no client isolation, the LAN IP
just works. But many routers (and most phone hotspots) **isolate clients**, so
the phone can't see the Mac even on the same Wi-Fi — and the LAN IP never works
off-network. The robust fix is [Tailscale](https://tailscale.com): install it on
both, sign in with the same account, and pair to the Mac's `100.x` tailnet IP.
Then it works on any Wi-Fi *and* on cellular, end-to-end encrypted. Launch the
Mac app with `EDGEPANEL_PAIR_HOST=100.x.x.x:8788` so the QR encodes the tailnet
address instead of the LAN IP. (The app's ATS allows plain HTTP, so it rides the
encrypted Tailscale tunnel with no HTTPS setup. Note: the Tailscale `100.64/10`
range is *not* "local networking" to iOS, so the Info.plist uses
`NSAllowsArbitraryLoads` **alone** — adding `NSAllowsLocalNetworking` would make
iOS ignore it and block the connection.)

**Live Activity (Tier 1, no account needed).** When a prompt starts, the app
shows a Dynamic Island activity with the project + a self-ticking timer; it flips
to a ✓ done state and posts a local notification when the turn ends, and warns at
80% / 90% of your 5-hour limit. Done/usage delivery happens while the app is
running (foreground or recently backgrounded); the timer ticks regardless.

### Free closed-app push via ntfy (no paid account)

iOS only delivers to a *fully-closed* app through APNs, which needs a paid Apple
account. The free workaround: piggyback on [ntfy](https://ntfy.sh), whose own app
already has push. The Mac (always running) POSTs to an ntfy topic when a prompt
finishes or a permission is waiting — and the permission alert carries **Allow /
Deny / Always** action buttons that POST the decision straight back to the Mac.
Works locked + fully-closed, instant, $0.

1. Install the **ntfy** app on your phone, subscribe to a private topic name.
2. On the Mac, create `~/.edgepanel/ntfy.json`:

   ```json
   {
     "server": "https://ntfy.sh",
     "topic": "edgepanel-<something-unguessable>",
     "macHost": "100.x.x.x:8788",
     "token": "<your EdgePanel pairing token>"
   }
   ```

   `macHost` + `token` let the buttons reach the Mac (use the Tailscale IP so it
   works off your LAN). The topic name is the only access control on the public
   server — keep it unguessable or self-host ntfy. Absent the file, ntfy is off.

### Tier 2 — push when the app is closed (optional, needs a paid account)

For the done/permission/usage alerts to arrive when the app is fully closed or
off your home network, the Mac pushes via APNs. Set up once:

1. In your Apple Developer account, create an **APNs Auth Key** (`.p8`), note its
   **Key ID** and your **Team ID**, and enable Push for the app's bundle id.
2. Build the iOS app onto a real device signed with your team (the
   `aps-environment` entitlement is already wired).
3. On the Mac, create `~/.edgepanel/apns.json`:

   ```json
   {
     "teamId": "ABCDE12345",
     "keyId": "KEY1234567",
     "keyPath": "~/.edgepanel/AuthKey_KEY1234567.p8",
     "bundleId": "com.srivibhav.edgepanel.mobile"
   }
   ```

Absent that file, push is disabled and Tier 1 (local) is used. *(The APNs path is
code-complete but unverified — it needs the key + a device to exercise.)*
