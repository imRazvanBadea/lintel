# Lintel

*A lintel is the beam across the top of a doorway. This one sits across the top of your screen.*

Lintel is a small native macOS app (Swift + SwiftUI, no dependencies, ~2 MB, ~0% CPU at rest) that turns the notch,
or the top-centre of an external display, into two islands:

- **Agents (left).** Every live Claude Code and Codex session, one colour each. See what each one is doing
  (researching, reasoning, writing, reviewing), approve or deny commands, answer an agent's multiple-choice questions,
  and send a follow-up when a turn finishes, all without leaving what you're doing.
- **Music (right).** What's playing in Apple Music or YouTube Music (in Chrome, Arc, Brave, Edge or Safari), with artwork,
  progress, play/pause/skip and **up next**.

On a notched MacBook the notch itself separates the two islands. On an external display they sit side by side with a gap.

## Install

```bash
./scripts/build.sh --install
```

This builds a release `Lintel.app`, copies it to `~/Applications`, and launches it. Settings open on first launch.

Then:

1. **Connect Claude Code** (Settings, or the menu-bar icon). This adds hooks to `~/.claude/settings.json` and saves a
   backup next to it as `settings.json.lintel-backup`. Sessions started *after* this show up. If Lintel isn't running,
   the hook exits immediately and Claude Code behaves exactly as before.
2. **Codex** is picked up automatically from `~/.codex/sessions` (desktop app and CLI). Nothing to install.
3. **Music.** macOS asks once whether Lintel may control Music and your browser. Allow it. For YouTube Music in a
   Chromium browser, turn on **View › Developer › Allow JavaScript from Apple Events** (in Safari it's in the Develop menu).

## Using it

| | |
|---|---|
| Hover a pill | Opens its card. Moving away closes it. |
| Click a pill | Pins it open. |
| `⌃⌥Space` | Toggle agents |
| `⌃⌥M` | Toggle music |
| `⌘1…⌘9` (card focused) | Jump to that session's terminal or app |
| `⌘↩` | Allow / submit |
| `Esc` | Back / close |

**When an agent needs you** the agents card opens on its own with a soft *tink*:

- **Permission prompts:** Allow, Deny, *Always allow* (applies Claude's suggested rule), or *Answer in terminal*.
  If you don't answer within the timeout (10 min by default), the prompt goes back to the terminal.
- **Questions** (`AskUserQuestion`): tick the options, or type your own answer, then Submit.
- **Finished turns:** shows the agent's summary. For 25 s (configurable) you can type a reply that continues the
  same Claude session. Typing pauses the countdown.

Codex is read-only. Lintel shows its status and tool calls and flags approvals with an *Open Codex* button. Codex
doesn't offer a hook for answering approvals from outside the app.

## How it works

```
Claude Code ── hook ──▶ ~/.lintel/claude-hook.sh ── HTTP 127.0.0.1:47821 (token) ──▶ Lintel
                               ▲                                                     │
                               └──────────── decision JSON (allow / deny / answers / reply) ◀┘
Codex ── writes ──▶ ~/.codex/sessions/**/rollout-*.jsonl ── FSEvents tail ──▶ Lintel
Music.app ── distributed notification + AppleScript ──▶ Lintel
Browser tab (music.youtube.com) ── AppleScript → JS (mediaSession + queue) ──▶ Lintel
```

- The hook server only listens on `127.0.0.1` and needs a random token stored in `~/.lintel/token` (mode 600).
- Permission and question cards are answered through Claude Code's `PermissionRequest` hook. Replies to a finished
  turn use the `Stop` hook's `decision: block` with your message as the reason.
- Apple Music is event-driven. The YouTube Music poll runs every 5 s, every 2 s while playing, and every 1 s with the
  card open. It does nothing when no browser is running.
- Spinners and equalisers are Core Animation layers, so they animate in the window server, not the app.

## Project layout

```
Sources/Lintel/
  App/      main, AppDelegate (menu-bar item, hotkeys), NotchPanel (window + mouse), IslandModel, Settings, Hotkeys
  Agents/   HookServer, ClaudeHooks (installer), AgentStore, AgentModels, CodexWatcher, Proc
  Music/    NowPlaying (merges sources), AppleMusicSource, YouTubeMusicSource, ScriptRunner
  UI/       RootView, AgentViews, MusicViews, Mascot, Theme, SettingsView
scripts/    build.sh, make-icon.swift, simulate.sh (fake hook events for UI work)
```

### Developing

```bash
swift build && open build/Lintel.app      # or ./scripts/build.sh
scripts/simulate.sh UserPromptSubmit '{"session_id":"demo","cwd":"'$PWD'","prompt":"Try it"}'
scripts/simulate.sh debug agents           # open the agents card
scripts/simulate.sh debug snapshot         # render the panel to $TMPDIR/lintel-snapshot.png
scripts/simulate.sh debug state            # dump sessions / pending requests / music as JSON
```

## Uninstall

Settings › Claude Code › Disconnect (removes only Lintel's hooks), quit Lintel, delete `~/Applications/Lintel.app`
and `~/.lintel`.
