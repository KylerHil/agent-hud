# Agent HUD

A tiny native macOS floating panel that shows every running Claude Code and Codex session, in
terminals, editors, the Claude desktop app and the ChatGPT desktop app, what state it's in, and
pings you when one is waiting on you. You answer prompts in the agent itself; Agent HUD only
watches and gets you there.

```
┌ 👁 Agent HUD                       ⌕  ▥  ⚙  ⌃ ┐
│ [ All 6 ][ ● You 2 ][ ● Busy 2 ][ ● Idle 2 ]   │
│ NEEDS YOU 2                                    │
│ ● Claude  web-app  Terminal         waiting 42s│
│   Permission: Bash                             │
│   rm -rf node_modules && pnpm install          │
│ ● Codex   infra  ChatGPT app         waiting 2m│
│ WORKING 2                                      │
│ ● Claude  api-server  VS Code             4m   │
│   Bash · pnpm test auth                        │
│   ↳ ● Explore                              1m  │
│ ● Claude  agent-watch  Claude app         38s  │
│ IDLE 2                                         │
│ ● Claude  docs-site  Terminal         idle 6m  │
│ 3h 12m agent time · 14m waiting    ⌃⌥Space jump│
└────────────────────────────────────────────────┘
```

Swift + SwiftUI, macOS 14+, no dependencies beyond what ships with macOS (`jq` is used by the
hook installer: built into macOS 15+, and installed with the cask on 14). No network, no Dock icon.

## Install

Requires macOS 14 (Sonoma) or later, on Apple silicon or Intel, and [Homebrew](https://brew.sh).

```sh
brew install --cask kylerhil/tap/agent-hud
```

Then:

1. Open **Agent HUD** (Spotlight, or `/Applications`). A panel appears at the top right, and an eye
   appears in the menu bar.
2. Click the **gear** → **Hooks** → **Install Hooks…**, check the diff, then **Apply**. This lets
   Claude Code and Codex report to Agent HUD. It adds entries next to your existing hooks, with a
   backup first. The same from a terminal: `agenthud-report install-hooks`.
3. Restart any Claude Code session that's already running. For Codex, run `/hooks` once and trust
   the Agent HUD entries.
4. Optional: gear → **General** → **Launch at login**.

macOS asks once to allow notifications, and once per terminal app for Automation (used to select
the right tab when you click a session).

**Update:** `brew upgrade --cask agent-hud`
**Uninstall:** `brew uninstall --cask agent-hud`. Add `--zap` to also remove its hooks (with backups),
settings and `~/.agenthud`.

Agent HUD isn't notarized by Apple. The cask clears the download quarantine so it opens normally.
If you install from the zip by hand instead, right-click the app → **Open** the first time.

## How it works

```
Claude Code / Codex hook ──stdin JSON──▶ agenthud-report ──append──▶ ~/.agenthud/events.jsonl
                                                                               │ (tail)
ps/libproc scan (liveness) ──────┐                                             ▼
~/.codex/sessions rollouts ──────┤                                    AgentHUD.app state machine
Claude.app session files ────────┼──────── synthetic events ─────────────────▲
Chat windows (Accessibility, opt-in) ┘
```

- **`agenthud-report`** is what the hooks run. It reduces the hook payload to one small JSON
  line, finds the agent's pid/tty and host app (VS Code, Terminal, iTerm2…) by walking its parent
  processes, and appends it to the log. It prints nothing, always exits 0, and kills itself after
  2 s. Hooks are registered `async`, so the agent never waits on it (~17 ms per call anyway).
- **The app** tails the log, runs a per-session state machine, scans the process table every 3 s,
  and reads Codex rollout logs for sessions its hooks don't cover.

### Sources

Settings → Sources shows each one with its live status, and turns the desktop apps and chats on or off.

| Source | How |
|---|---|
| Claude Code in Terminal, iTerm2, Ghostty, VS Code, Cursor… | hooks; process table for liveness |
| **Claude desktop app** (Code tab) | Claude.app runs its own copy of Claude Code, so the same hooks report it. Its per-session files in `~/Library/Application Support/Claude/claude-code-sessions` add the title, and running/idle from the transcript when hooks don't fire. |
| Codex CLI and IDE extension | hooks; `~/.codex/sessions` rollouts until the hooks are trusted |
| **ChatGPT desktop app** (Codex) | ChatGPT.app runs `codex app-server` with the same `~/.codex`, so its tasks come through the same hooks and rollouts. |
| **Chats in Claude and ChatGPT** (experimental, off by default) | Accessibility: a Stop button in the window means a reply is streaming. Shows *Responding…* then *Reply ready*. Needs Accessibility permission; only window titles and that button are read. |

### States

| State | Set by |
|---|---|
| 🟠 NEEDS INPUT | `PermissionRequest`; `Notification` (permission / elicitation / agent_needs_input); `AskUserQuestion` / `ExitPlanMode`; MCP `Elicitation` |
| 🟢 RUNNING | `UserPromptSubmit`, `PreToolUse`, `PostToolUse*`, `SubagentStart` |
| ⚪ IDLE | `Stop`, `StopFailure` (shown in red), `Interrupt` (Codex), `idle_prompt`, Esc-interrupt detected in the Claude transcript |
| 🟡 STALE | RUNNING, but no events and no transcript writes for 15 min (configurable) |
| 🟣 SEEN | a Claude process alive for 30 s+ with no hook events yet (started before hooks were installed); it disappears when the process exits |
| ENDED | `SessionEnd`, or the agent process disappeared; dropped after 3 min |

Subagents (`SubagentStart`/`SubagentStop`, and tool events carrying `agent_id`) are nested under
their parent session.

**What can't be known:** Codex without trusted hooks shows RUNNING/IDLE only, because its rollout
logs don't record approval prompts. A Codex `app-server` hosts many threads in one process, so a
Codex session ends when its VS Code window's `codex` process exits.

## Coming from AgentWatch

Agent HUD was called AgentWatch. On first launch it moves `~/.agentwatch` to `~/.agenthud`, leaving
a symlink so hooks installed by AgentWatch keep working, and carries your settings over. A banner in
the panel offers **Update…**, which replaces the old hook entries through the usual diff preview.
`make install` removes `~/Applications/AgentWatch.app`.

## Build from source

Needs Xcode 16 or later (or its Command Line Tools).

```sh
make app        # build/AgentHUD.app (ad-hoc signed)
make run        # build and launch from build/
make install    # copy to ~/Applications/AgentHUD.app + ~/.agenthud/bin/agenthud-report, launch
make test       # unit tests
make release VERSION=1.2.0   # publish a release to GitHub and the Homebrew tap (docs/RELEASING.md)
make icon       # regenerate Resources/AppIcon.icns from scripts/make-icon.swift
make help       # everything else
```

On first launch macOS asks to allow notifications. Clicking a Terminal/iTerm2 session asks once
for Automation permission (used to select the right tab).

## Install the hooks

```sh
make hooks-diff        # show exactly what would change; touches nothing
make install-hooks     # backs up, shows the diff, asks y/N, then merges
make hooks-status
```

Or use **Settings → Hooks → Install Hooks…** in the app (same diff preview).

- **Claude Code:** entries are added to `~/.claude/settings.json` under `hooks`, next to any
  hooks you already have. Existing keys, order, and formatting are preserved.
- **Codex:** a new `~/.codex/hooks.json` is created. `config.toml` is **not** modified (your
  `notify` setting is left alone), but it is backed up anyway. If `config.toml` already defines
  inline `[hooks]`, the installer stops, because Codex doesn't allow both in one layer.
  Codex runs new hooks only after you trust them: open Codex, run **`/hooks`**, and trust the
  Agent HUD entries. Until then Agent HUD falls back to the rollout logs.
- Backups: `~/.agenthud/backups/<file>.<yyyyMMdd-HHmmss>.bak`, written before every change.
- Installing twice is a no-op; every hook entry is identified by `agenthud-report` in its command.

## Uninstall

```sh
make uninstall-hooks                     # removes only Agent HUD's entries (diff + confirm)
rm -rf ~/Applications/AgentHUD.app ~/.agenthud
```

Uninstall after install restores `settings.json` byte-for-byte; `hooks.json` is deleted if only
Agent HUD's hooks were in it.

## Using it

- **Drag** the panel from anywhere; **resize** from its edges or the corner grip. Size and
  position are remembered. The list scrolls.
- **Click** a row to bring its window forward: the exact Terminal/iTerm2 tab (by tty), the
  VS Code/Cursor window that already has the project open (read from the editor's list of open
  windows, so it never opens a second window for a subfolder), the Claude or ChatGPT app, else the
  folder in Finder.
- **Tabs** filter to All, You (needs input), Busy, or Idle. Rows are grouped the same way, and
  each shows the app it lives in.
- **ⓘ** (on hover) or right-click → Show Details opens the session: its prompt, tool calls, files
  changed, time spent waiting on you, context used, subagents, and a timeline of recent events.
  Copy Resume Command gives `cd <folder> && claude --resume <id>` (or `codex resume <id>`).
- **Right-click** also has Open Folder, Copy Session ID, Mute Notifications, Dismiss.
- **⌃** collapses to a pill. While something needs input the pill names it (`● web-app  Permission: Bash  +1`)
  and pulses orange; otherwise it shows counts. Click the pill to expand.
- **⌃⌥Space** (or the magnifying glass) brings the panel forward with a search field: type to
  filter, ↑↓, Return or ⌘1–9 to jump, Esc to close. **⌃⌥A** shows or hides the panel. Change either
  under gear → General → Shortcuts (click, then press the new combination), or turn them off.
- **Everything happens in the panel.** The dashboard (chart icon) and settings (gear) open inside
  it, and it grows to fit them; nothing opens a separate window. CSV export saves straight to
  Downloads.
- **Rows are named by project**: the git root of the folder the session started in (else that folder).
  When the agent `cd`s deeper, the row shows where it is: `Norco › norco-mobile`.
- **Dashboard** (the chart button, the panel footer, or the menu) opens inside the panel, which grows
  to fit and returns to its size and place when you go back. Ranges: Today, 7 Days, 30 Days, All.
  - Active time, sessions and tokens by project and by day, read from the agents' own transcripts
    (`~/.claude/projects`, `~/.codex/sessions`), so it covers weeks of history, including sessions
    from before Agent HUD ran. Indexed into `~/.agenthud/history-index.json` (the first run reads
    everything, a few seconds; after that only changed files). History is kept even after Claude
    deletes old transcripts.
  - Active time is the time between transcript events, with silences longer than the idle gap
    (5, 10, 15 or 30 min; default 10) counted as breaks. A project's sessions are merged first, so
    parallel sessions count once.
  - Tokens count each API message once: input, output, cache writes and cache reads.
  - Today also shows the live per-session timeline, with time spent waiting on you in orange.
  - Click a project to list its sessions; **Export** writes one CSV row per session (project, start,
    end, active minutes, tokens, model) for checking time against a timesheet.
- **Menu bar:** the eye icon, followed by one colored dot per live session in panel order (🟠 needs input, 🟢 running,
  🟡 stale, ⚪ idle, 🟣 seen without hooks; `+N` past 10), so you can hide the panel and still see
  everything. The menu groups sessions like the panel; click one to jump to it. It also has
  Jump to Next Waiting, Find Session…, Pause Notifications (15 min to tomorrow), and Dashboard.
- **Notifications** have Show, Snooze 10 min, and Mute Session. "Finished" says how long the turn
  took and how many files changed.
- **Settings:** opacity (the panel goes fully opaque on hover), pulse, idle sessions, stale and
  ended timings, notifications (needs input, finished, sound, re-remind interval), launch at login.

## Testing without agents

```sh
make fake          # ~40 s scripted run: 5 sessions through every state, with subagents
make fake-loop     # repeat forever; Ctrl-C ends the fake sessions
make fake-clear    # end all fake sessions now
AgentHUD.app/Contents/MacOS/Agent HUD --snapshot /tmp/snap   # render the panel, detail, dashboard to PNGs
AgentHUD.app/Contents/MacOS/Agent HUD --history 7             # print the last 7 days of history
```

`fake-events.sh` pipes fake hook payloads through the real reporter. Feed one event by hand with:

```sh
echo '{"hook_event_name":"PermissionRequest","session_id":"t1","cwd":"/tmp/demo","tool_name":"Bash"}' \
  | ~/.agenthud/bin/agenthud-report --agent claude
```

`AGENTHUD_HOME=/some/dir` points the reporter, fake script, and app at a separate log.

## Troubleshooting

- **A session never appears.** `tail -f ~/.agenthud/events.jsonl` while you use the agent.
  No lines means the hooks aren't running: check `make hooks-status`, restart the Claude session,
  and for Codex make sure the hooks are trusted in `/hooks`.
- **Stuck on RUNNING.** Long silent tool calls are normal; after 15 min it shows STALE. Esc-interrupts
  in Claude are detected from the transcript within a few seconds.
- **Stuck on NEEDS INPUT after denying a prompt.** It clears on the next tool batch, turn end, or
  prompt. Right-click → Dismiss removes a row immediately (it comes back with the next event).
- **Clicking a row does nothing.** For Terminal/iTerm2, allow Agent HUD under System Settings →
  Privacy & Security → Automation. VS Code sessions are focused by opening their folder.
- **No notifications.** System Settings → Notifications → Agent HUD. With notifications off,
  the sound setting still plays a sound.
- **Panel off-screen.** It returns to the main screen automatically when its saved position isn't
  on any display. `defaults delete local.agenthud.Agent HUD` resets all settings.
- **Log size.** The log rotates at 20 MB to `events.1.jsonl`; only the last 24 h are replayed at launch.

## Layout

```
Package.swift
Makefile
Resources/Info.plist                 LSUIElement, AppleEvents usage string
Sources/AgentHUDCore/              event model, state machine, activity log, tailer, scanners, installer
Sources/agenthud-report/main.swift the hook reporter (+ install/uninstall subcommands)
Sources/AgentHUD/                  SwiftUI/AppKit app: panel, detail, search, dashboard, menu bar,
                                     settings, notifications, hotkeys, chat watcher
Tests/AgentHUDCoreTests/           state machine, tailer, scanners, installer
scripts/fake-events.sh
scripts/make-icon.swift              the app icon, drawn in code (`make icon`)
```
