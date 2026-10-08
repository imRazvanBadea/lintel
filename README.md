# Lintel

*A lintel is the beam across the top of a doorway. This one sits across the top of your screen.*

Lintel is a small native macOS menu-bar app (Swift + SwiftUI, no dependencies, ~2 MB, ~0% CPU at rest) that turns the
notch, or the top-centre of an external display, into two islands:

- **Agents (left).** Every live Claude Code, Cursor and Codex session, each a coloured circle with the first letter of its
  project and the title the tool generated for it. See what each one is doing, approve or deny commands, answer an
  agent's multiple-choice questions, and send a follow-up when a turn finishes, all without leaving what you're doing.
- **Music (right).** Whatever is playing on the Mac (Apple Music, Spotify, YouTube Music in any browser…), with
  artwork, progress, play/pause/skip and the **real up-next queue**. Click the cover to jump to the player.

On a notched MacBook the notch grows wings, agents on the left and music on the right. On an external display they're
two capsules at the top edge. Lintel follows the display you click on. Light, Dark or System appearance.

## Install

```bash
./scripts/build.sh --install
```

This builds a release `Lintel.app`, copies it to `~/Applications`, and launches it. Settings open on first launch.

Then:

1. **Connect Claude Code and Cursor** from the menu-bar icon or Settings. This adds hooks to `~/.claude/settings.json`
   and `~/.cursor/hooks.json`, saving a `.lintel-backup` next to each. If Lintel isn't running, the hook exits
   immediately and the agents behave exactly as before.
2. **Codex** is picked up automatically from `~/.codex/sessions` (desktop app and CLI). Nothing to install.
3. **Music** works with no setup. For YouTube Music's *up next* (browsers don't publish their queue), turn on
   **Allow JavaScript from Apple Events** in your browser (Chromium/Dia/Arc: View › Developer; Safari: Develop).

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

**Cursor:** live status, tool calls, the agent's reply, token counts, and quick replies (sent as Cursor's
`followup_message`). Approving Cursor's terminal commands from the notch is opt-in in Settings.

**Codex** is read-only. Lintel shows its status and tool calls and flags approvals with an *Open Codex* button. Codex
doesn't offer a hook for answering approvals from outside the app.

**Titles** are the ones each tool generates: the Claude app's session titles, Cursor's conversation names and
Codex's thread names. Claude Code in a plain terminal doesn't generate titles, so those show your first prompt.

**Regular Claude chats** (claude.ai, or the desktop app's Chat tab) aren't shown. They expose no hooks or local state
for other apps to follow.

## How it works

```
Claude Code ── hook ──▶ ~/.lintel/claude-hook.sh ── HTTP 127.0.0.1:47821 (token) ──▶ Lintel
                               ▲                                                     │
                               └──────────── decision JSON (allow / deny / answers / reply) ◀┘
Codex ── writes ──▶ ~/.codex/sessions/**/rollout-*.jsonl ── FSEvents tail ──▶ Lintel
Cursor ── ~/.cursor/hooks.json ──▶ same hook script ──▶ Lintel   (followup_message / permission JSON back)
macOS Now Playing (MediaRemote) ── bridge in /usr/bin/perl ──▶ Lintel   (any player, real queue, controls)
Browser tab (music.youtube.com) ── AppleScript → JS (queue only) ──▶ Lintel
```

- The hook server only listens on `127.0.0.1` and needs a random token stored in `~/.lintel/token` (mode 600).
- Permission and question cards are answered through Claude Code's `PermissionRequest` hook. Replies to a finished
  turn use the `Stop` hook's `decision: block` with your message as the reason.
- Music is event-driven. Since macOS 15.4 the Now Playing service only answers Apple-signed processes, so a ~150-line
  bridge (`Bridge/LintelNowPlaying.m`) runs inside `/usr/bin/perl` and streams JSON to Lintel over a pipe. The
  YouTube Music queue is read from the page only while a browser is the player (every 15 s, or 3 s with the card open).
- Spinners and equalisers are Core Animation layers, so they animate in the window server, not the app.

## Project layout

```
Sources/Lintel/
  App/      main, AppDelegate (menu-bar item, hotkeys), NotchPanel (window + mouse), IslandModel, Settings, Hotkeys
  Agents/   HookServer, ClaudeHooks (installer), AgentStore, AgentModels, CodexWatcher, Proc
  Music/    NowPlaying, NowPlayingBridge, WebQueueReader, ScriptRunner
Bridge/     LintelNowPlaying.m (MediaRemote bridge, built into the app by build.sh)
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

Settings › Agents › Disconnect for Claude Code and Cursor (removes only Lintel's hooks), quit Lintel from the menu-bar
icon, delete `~/Applications/Lintel.app` and `~/.lintel`.
