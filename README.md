# AgentWatch

A tiny native macOS floating panel that shows every running Claude Code and Codex session,
what state it's in, and pings you when one is waiting on you.

```
┌ AgentWatch                 ● 2  ● 1  ● 2  ⌃ ┐
│ ● Claude  web-app                waiting 6s │
│   Permission: Bash · rm -rf node_modules    │
│ ● Codex   infra                  waiting 6s │
│ ● Claude  api-server            running 12s │
│   ↳ ● Plan                       running 9s │
│ ● Claude  docs-site                 idle 6s │
│   Fixed 4 typos in README.md.               │
└─────────────────────────────────────────────┘
```

Swift + SwiftUI, macOS 14+, no dependencies beyond what ships with macOS (`jq` is used by the
hook installer; it's at `/usr/bin/jq` on macOS 15+). No network, no Dock icon.

## How it works

```
Claude Code / Codex hook ──stdin JSON──▶ agentwatch-report ──append──▶ ~/.agentwatch/events.jsonl
                                                                               │ (tail)
ps/libproc scan (liveness) ─┐                                                  ▼
~/.codex/sessions rollouts ─┴──────────── synthetic events ──────────▶ AgentWatch.app state machine
```

- **`agentwatch-report`** is what the hooks run. It reduces the hook payload to one small JSON
  line, finds the agent's pid/tty and host app (VS Code, Terminal, iTerm2…) by walking its parent
  processes, and appends it to the log. It prints nothing, always exits 0, and kills itself after
  2 s. Hooks are registered `async`, so the agent never waits on it (~17 ms per call anyway).
- **The app** tails the log, runs a per-session state machine, scans the process table every 3 s,
  and reads Codex rollout logs for sessions its hooks don't cover.

### States

| State | Set by |
|---|---|
| 🟠 NEEDS INPUT | `PermissionRequest`; `Notification` (permission / elicitation / agent_needs_input); `AskUserQuestion` / `ExitPlanMode`; MCP `Elicitation` |
| 🟢 RUNNING | `UserPromptSubmit`, `PreToolUse`, `PostToolUse*`, `SubagentStart` |
| ⚪ IDLE | `Stop`, `StopFailure` (shown in red), `Interrupt` (Codex), `idle_prompt`, Esc-interrupt detected in the Claude transcript |
| 🟡 STALE | RUNNING, but no events and no transcript writes for 15 min (configurable) |
| 🟣 SEEN | an agent process with no hook events yet (started before hooks were installed) |
| ENDED | `SessionEnd`, or the agent process disappeared; dropped after 3 min |

Subagents (`SubagentStart`/`SubagentStop`, and tool events carrying `agent_id`) are nested under
their parent session.

**What can't be known:** Codex without trusted hooks shows RUNNING/IDLE only, because its rollout
logs don't record approval prompts. A Codex `app-server` hosts many threads in one process, so a
Codex session ends when its VS Code window's `codex` process exits.

## Build and run

```sh
make app        # build/AgentWatch.app (ad-hoc signed)
make run        # build and launch from build/
make install    # copy to ~/Applications/AgentWatch.app + ~/.agentwatch/bin/agentwatch-report, launch
make test       # unit tests
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
  AgentWatch entries. Until then AgentWatch falls back to the rollout logs.
- Backups: `~/.agentwatch/backups/<file>.<yyyyMMdd-HHmmss>.bak`, written before every change.
- Installing twice is a no-op; every hook entry is identified by `agentwatch-report` in its command.

## Uninstall

```sh
make uninstall-hooks                     # removes only AgentWatch's entries (diff + confirm)
rm -rf ~/Applications/AgentWatch.app ~/.agentwatch
```

Uninstall after install restores `settings.json` byte-for-byte; `hooks.json` is deleted if only
AgentWatch's hooks were in it.

## Using it

- **Drag** the panel from anywhere; **resize** from its edges or the corner grip. Size and
  position are remembered. The list scrolls.
- **Click** a row to bring its window forward: the exact Terminal/iTerm2 tab (by tty), the
  VS Code/Cursor window with that folder, else the host app, else the folder in Finder.
  Right-click for Open Folder, Copy Session ID, Dismiss.
- **⌃** collapses to a pill (`● 2 ● 3 ● 1`); click the pill to expand. It pulses orange while
  anything needs input.
- **Menu bar:** the eye icon, followed by one colored dot per live session in panel order (🟠 needs input, 🟢 running,
  🟡 stale, ⚪ idle, 🟣 seen without hooks; `+N` past 10), so you can hide the panel and still see
  everything. The menu lists every session with its state; click one to jump to it.
- **Settings:** opacity (the panel goes fully opaque on hover), pulse, idle sessions, stale and
  ended timings, notifications (needs input, finished, sound, re-remind interval), launch at login.

## Testing without agents

```sh
make fake          # ~40 s scripted run: 5 sessions through every state, with subagents
make fake-loop     # repeat forever; Ctrl-C ends the fake sessions
make fake-clear    # end all fake sessions now
AgentWatch.app/Contents/MacOS/AgentWatch --snapshot /tmp/snap   # render the panel to PNGs
```

`fake-events.sh` pipes fake hook payloads through the real reporter. Feed one event by hand with:

```sh
echo '{"hook_event_name":"PermissionRequest","session_id":"t1","cwd":"/tmp/demo","tool_name":"Bash"}' \
  | ~/.agentwatch/bin/agentwatch-report --agent claude
```

`AGENTWATCH_HOME=/some/dir` points the reporter, fake script, and app at a separate log.

## Troubleshooting

- **A session never appears.** `tail -f ~/.agentwatch/events.jsonl` while you use the agent.
  No lines means the hooks aren't running: check `make hooks-status`, restart the Claude session,
  and for Codex make sure the hooks are trusted in `/hooks`.
- **Stuck on RUNNING.** Long silent tool calls are normal; after 15 min it shows STALE. Esc-interrupts
  in Claude are detected from the transcript within a few seconds.
- **Stuck on NEEDS INPUT after denying a prompt.** It clears on the next tool batch, turn end, or
  prompt. Right-click → Dismiss removes a row immediately (it comes back with the next event).
- **Clicking a row does nothing.** For Terminal/iTerm2, allow AgentWatch under System Settings →
  Privacy & Security → Automation. VS Code sessions are focused by opening their folder.
- **No notifications.** System Settings → Notifications → AgentWatch. With notifications off,
  the sound setting still plays a sound.
- **Panel off-screen.** It returns to the main screen automatically when its saved position isn't
  on any display. `defaults delete local.agentwatch.AgentWatch` resets all settings.
- **Log size.** The log rotates at 20 MB to `events.1.jsonl`; only the last 24 h are replayed at launch.

## Layout

```
Package.swift
Makefile
Resources/Info.plist                 LSUIElement, AppleEvents usage string
Sources/AgentWatchCore/              event model, state machine, tailer, scanners, installer
Sources/agentwatch-report/main.swift the hook reporter (+ install/uninstall subcommands)
Sources/AgentWatch/                  SwiftUI/AppKit app: panel, menu bar, settings, notifications
Tests/AgentWatchCoreTests/           state machine, tailer, scanners, installer
scripts/fake-events.sh
```
