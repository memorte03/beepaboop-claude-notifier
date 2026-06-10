# Beepaboop

> **Desktop notifications for Claude Code** — a native macOS menu-bar app that
> alerts you when Claude Code finishes, needs input, or asks permission, with
> inline approve/deny and one-click jump-to-session. (a Claude Code notifier /
> notification overlay for macOS)

A native macOS overlay for [Claude Code](https://claude.com/claude-code). When
Claude finishes, needs input, or asks for permission — and you're on another
Space, in another app, or just not looking — a LookAway-style card slides in
on **whatever Space you're currently on**:

- Shows which session fired (**repo · branch**), the state (done / waiting /
  permission), and a one-line context.
- **Approve / Deny** permission requests right from the overlay, with a diff
  preview for file edits — no window switching.
- **Jump to session**: one click raises the exact terminal window (across
  Spaces) and focuses the exact tmux pane the session lives in.
- **Missed-action pills**: notifications you don't act on demote into compact
  persistent pills at the top of the screen (project icon · repo · branch ·
  state · age). Click to jump, ✕ to dismiss — or they clear themselves when
  you visit the pane or the session sends a newer event.
- **Per-project icons**: regex-on-path rules (Settings → Project Icons) put
  your project's logo on its overlays and pills.
- Distinct synthesized chimes per event kind; everything configurable from
  the Settings window (⌘,).

<!-- TODO: screenshot/GIF of the overlay here -->

## Requirements

- macOS 14+
- [`jq`](https://jqlang.github.io/jq/) — `brew install jq` (hooks are built with it)
- Swift 6 toolchain (Xcode or Command Line Tools) to build from source
- Optional, for the best jump-to-session experience: tmux + [Ghostty](https://ghostty.org) ≥ 1.3

## Install

### From a release (drag-to-install)

Open `Beepaboop-<version>.dmg`, drag **Beepaboop** onto the
Applications folder, and launch it. The app installs its own Claude Code hooks
on first launch — no terminal step. Because the app isn't notarized by Apple,
the first launch needs a one-time approval in **System Settings → Privacy &
Security → Open Anyway**. Install `jq` (`brew install jq`) for the hooks to run;
the menu bar warns if it's missing.

### From source

```sh
git clone https://github.com/memorte03/beepaboop-claude-notifier
cd beepaboop-claude-notifier
scripts/install.sh
```

The script builds the app, installs `Beepaboop.app` into `/Applications`,
copies the hook scripts to `~/.config/beepaboop/hooks/`, and wires them
into `~/.claude/settings.json` (a backup is written next to it). Re-run it any
time to update; it converges instead of duplicating entries.

### Building a distributable

- `scripts/make-dmg.sh` → `dist/Beepaboop-<version>.dmg` (universal,
  drag-to-install — send this to others).
- `scripts/package.sh` → `dist/Beepaboop-<version>.zip` (app + a
  `bash`-run installer that sidesteps the Gatekeeper prompt).
- For permissions that persist across rebuilds, run `scripts/make-signing-cert.sh`
  once; the build scripts then sign with that stable identity instead of ad-hoc.

By default the permission overlay covers `Bash|Write|Edit|MultiEdit|NotebookEdit`.
Change it with:

```sh
BEEPABOOP_PRETOOL_MATCHER="Bash|Write" scripts/install.sh
```

Uninstall completely with `scripts/uninstall.sh`.

### Permissions

macOS will prompt for two things:

- **Accessibility** — at first launch. Used to raise terminal windows and read
  window titles. (System Settings → Privacy & Security → Accessibility)
- **Automation → Ghostty** — at your first jump. Used to raise the right
  Ghostty window across Spaces. (System Settings → Privacy & Security → Automation)

The menu bar icon (✨) → **Permissions** shows the live status of both, with
shortcuts into System Settings.

## How it works

```
┌────────────────────┐  POST /notify       ┌──────────────────┐
│ hook scripts       │ ──────────────────▶ │  Beepaboop.app   │
│ (~/.config/        │  POST /permission   │  - HTTP on :7891  │
│  beepaboop/)       │ ◀──── decision ──── │  - SwiftUI overlay │
│                    │                     │  - menu bar       │
└────────────────────┘                     └──────────────────┘
```

- `notify.sh` (Stop / Notification hooks) is fire-and-forget.
- `permission.sh` (PreToolUse hook) blocks until you click Approve / Deny in
  the overlay, then emits the `permissionDecision` JSON Claude Code expects.
  If you don't click within ~10 s (or the app isn't running), it falls back to
  `"ask"` and Claude Code shows its native prompt — the notifier failing never
  blocks you.
- Requests are authenticated with a random token the app generates at first
  launch (`~/.config/beepaboop/token`, mode 0600). Without it, any local
  process or webpage could spoof overlay prompts via a POST to localhost.

### Jump to session

When the session runs inside tmux, the jump is deterministic: the hook
captures the pane identity (`$TMUX_PANE`, socket, binary), and on click the
app selects the exact window+pane, maps the session to its client tty
(attaching a client if the session is detached), briefly writes a unique title
marker (OSC 2) to that tty, and raises the marked window — via Ghostty ≥ 1.3
AppleScript, which sees windows on **every** Space. Other terminals (or denied
Automation) fall back to the Accessibility API, which macOS limits to windows
on the current Space.

Approve/Deny answers are likewise delivered with `tmux send-keys` straight to
the pane — no synthesized keystrokes landing in the wrong window.

Outside tmux, the jump activates the terminal app and best-effort matches the
window by title.

### Approve / Deny and your existing permission rules

`permission.sh` checks `permissions.allow` in your Claude settings first and
auto-allows matching tools without showing an overlay, so pre-approved tools
stay silent. If a `permissions.deny` rule matches, the hook steps aside
(`"ask"`) and lets Claude Code enforce it. The rule matcher is a close — but
not perfect — reimplementation of Claude Code's; if a rule behaves
unexpectedly, the failure mode is always an extra prompt, never a silent allow.

## Menu bar

- Server status (or a visible error if the port is taken)
- **Permissions** — live Accessibility / Automation status
- **Notifications** — per-kind toggles (done / waiting / permission / errors /
  info) and chime mute; persisted across restarts
- **Launch at Login**
- **Debug** — fire test notifications, preview chimes

## Hook payload contract

`/notify` and `/permission` accept the same JSON shape (header
`X-Beepaboop-Token: <contents of ~/.config/beepaboop/token>` required):

| field           | source                                                            |
| --------------- | ----------------------------------------------------------------- |
| `id`            | uuid (correlation key for `/permission` responses)                |
| `kind`          | `stop` \| `idle` \| `permission` \| `info` \| `error`             |
| `title`         | shown bold in the overlay                                         |
| `context`       | one-line context (tool input, last message, etc.)                 |
| `repoName`      | `basename git rev-parse --show-toplevel`                          |
| `branch`        | `git rev-parse --abbrev-ref HEAD`                                 |
| `cwd`           | Claude Code's `cwd`                                               |
| `sessionId`     | Claude Code's `session_id`                                        |
| `toolName`      | tool being approved (for permissions)                             |
| `diffPreview`   | short unified diff shown for Edit/Write/MultiEdit                 |
| `terminalPid`   | terminal app PID found by walking ancestors of the hook script    |
| `terminalApp`   | bundle id, e.g. `com.mitchellh.ghostty`                           |
| `windowTitle`   | best-effort window title for the AX-based jump (fallback path)    |
| `tmuxSession`   | tmux session name (`#{session_name}`)                             |
| `tmuxPane`      | tmux pane id (`$TMUX_PANE`, e.g. `%4`)                            |
| `tmuxWindowId`  | tmux window id (`#{window_id}`, e.g. `@2`)                        |
| `tmuxSocket`    | tmux server socket path (first field of `$TMUX`)                  |
| `tmuxBin`       | absolute path to the tmux binary                                  |

`/permission` blocks until the overlay returns:

```json
{ "decision": "allow" | "deny" | "ask", "reason": "optional" }
```

## Configuration

- **Port**: `export BEEPABOOP_PORT=7777` — read by both the app and the
  hooks (default 7891).
- **Permission timeout**: `defaults write com.morte.beepaboop permissionTimeout 12`
  (seconds, max 14 — the hooks' HTTP timeout is 15 s).
- **Notification kinds / chimes**: menu bar → Notifications.

## Troubleshooting

- **No overlays at all** — check the menu bar icon: does it show a server
  error? Is the app running? `curl http://127.0.0.1:7891/health` prints a JSON
  status (`ok`, current/queued/pending counts). Check `jq` is installed.
- **Overlays work but Jump doesn't switch Spaces** — menu bar → Permissions:
  Automation (Ghostty) must be granted, and Ghostty must be ≥ 1.3. Without it,
  the fallback can only raise windows on the current Space.
- **Permission overlay never appears for some tool** — the tool probably
  matches a `permissions.allow` rule (auto-allowed, silent by design) or isn't
  in the PreToolUse matcher (re-run install with `BEEPABOOP_PRETOOL_MATCHER`).
- **403 from curl when testing by hand** — send the token:
  `-H "X-Beepaboop-Token: $(cat ~/.config/beepaboop/token)"`.

## Development

```sh
swift build && .build/debug/Beepaboop   # run from the repo, no bundle
scripts/test-jump.sh [pane-id]               # fire a jump-test notification
swift scripts/make-icon.swift                # regenerate the iconset
```

The app logs with `NSLog`; when launched from a terminal, stderr is the place
to look.

## Roadmap

- Reply-back input on the overlay (send a follow-up prompt into the session)
- Per-session history / "show me what just finished"
- Prebuilt, notarized releases

## License

[MIT](LICENSE)
