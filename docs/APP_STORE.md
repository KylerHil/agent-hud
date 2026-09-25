# Agent HUD on the App Store

Everything to paste into App Store Connect, what App Review will look at, and what to check in
TestFlight first.

## How the sandboxed build differs

The App Store requires App Sandbox. The App Store build (`make upload-appstore`) changes this:

| | Direct (Developer ID) | App Store |
|---|---|---|
| Data folder | `~/.agenthud` | the App Group container, shared with the hook reporter |
| Hook command | `~/.agenthud/bin/agenthud-report` | the reporter inside the app: `/Applications/AgentHUD.app/Contents/MacOS/agenthud-report` (reinstall hooks if you move the app) |
| Chat watching (Accessibility) | available | not available; Settings → Sources says so |
| Reading `~/.claude`, `~/.codex`, Claude desktop and editor window lists | direct | temporary-exception entitlements, listed below |
| AppleScript to Terminal/iTerm2 | yes | temporary-exception entitlement |

### Review risks

Be ready for these, and ship the direct DMG either way:

- **Temporary-exception entitlements** (guideline 2.4.5). The app reads and writes paths outside
  its container. Apple accepts these case by case when the justification is clear; the review
  notes below explain each one. If they're rejected, the fallback is asking the user to pick
  `~/.claude` and `~/.codex` once in an Open dialog (security-scoped bookmarks). That's a code
  change, and not needed unless review asks.
- **Editing another app's settings** (installing hooks into `~/.claude/settings.json` and
  `~/.codex/hooks.json`). It only happens when the user clicks Install, after previewing the
  exact diff, with a backup written first. Say that in the notes.
- **Process inspection.** The app lists processes to see which agents are running. If the sandbox
  blocks reading other processes' paths, sessions still show from hooks and transcripts, but the
  "seen" rows and liveness checks stop working. Check this in TestFlight.

## Listing

| Field | Value |
|---|---|
| Name | Agent HUD |
| Subtitle (≤30) | AI Agent Watcher |
| Category | Developer Tools (secondary: Productivity) |
| Age rating | 4+ (no objectionable content) |
| Price | your call |
| Copyright | © 2026 Xeratec |
| Support URL / Marketing URL | [YOUR URL] |
| Privacy Policy URL | required. A one-paragraph page saying nothing is collected or transmitted is enough: [YOUR URL] |

**Promotional text (≤170)**

> See every Claude Code and Codex session at a glance: who's working, who's waiting on you, and where the hours went.

**Description**

> Agent HUD is a small floating panel and menu bar companion for people who run AI coding agents.
>
> It shows every Claude Code and Codex session on your Mac: in Terminal, iTerm2, VS Code, Cursor, the Claude desktop app, and the ChatGPT desktop app. Each row says what the session is doing right now and pings you the moment one needs your answer. Click a session to jump straight to its window.
>
> • Needs you, working, idle: sessions grouped by what they need from you
> • Notifications with Show, Snooze and Mute, and a count of how long each agent waited
> • Session detail: prompt, tool calls, files changed, context used, subagents, timeline
> • Dashboard: active time and tokens by project and by day, going back weeks, with CSV export for checking time against a timesheet
> • ⌃⌥Space to find and jump to any session from the keyboard
> • Everything stays on your Mac. No account, no network, no analytics.
>
> Agent HUD reads the agents' own local files and hooks. It never answers prompts for you; you stay in control in the agent itself.

**Keywords (≤100 characters)**

```
claude,codex,ai agent,coding agent,monitor,menu bar,developer,hud,terminal,vscode,tokens,timesheet
```

**What's New (1.0)**

> First release.

**Screenshots:** macOS needs at least one, at 16:10: 1280×800, 1440×900, 2560×1600 or 2880×1800.
Take real ones (⌘⇧5) of the panel over a desktop, the dashboard, and a notification. For art
with no personal data, `AgentHUD --snapshot <dir>` renders the panel, detail view and dashboard
to PNGs; composite them onto a 2880×1800 background.

## App Privacy

App Store Connect → App Privacy → **Data Not Collected**. The app has no network code; the privacy
manifest (`Resources/PrivacyInfo.xcprivacy`) declares UserDefaults and file-timestamp use for
app functionality only.

## Review notes (paste into "Notes" under App Review Information)

> Agent HUD monitors AI coding agents (Claude Code and OpenAI Codex) that run on the user's Mac, and shows their status in a floating panel and the menu bar.
>
> To see it working: install Claude Code (https://claude.com/claude-code), open Agent HUD → Settings (gear) → Hooks → Install Hooks… → Apply, then run `claude` in Terminal and give it a task. The session appears in the panel, turns orange when it asks for permission, and clicking it brings Terminal forward. The Dashboard (chart icon) summarizes the user's past sessions from the agents' local transcripts.
>
> Why each entitlement is needed:
> • home-relative-path read-write `/.claude/`, `/.codex/`: the agents keep their transcripts, session logs and hook settings here. Agent HUD reads them to show status and history. It writes only when the user clicks Install/Uninstall Hooks, after showing the exact diff, and it saves a backup first.
> • home-relative-path read-only `/Library/Application Support/Claude/claude-code-sessions/`: the Claude desktop app's list of its coding sessions, to show their titles.
> • home-relative-path read-only `…/Code|Cursor|Windsurf/User/globalStorage/`: the editor's list of open windows, so clicking a session focuses the existing window instead of opening a new one.
> • apple-events for com.apple.Terminal and com.googlecode.iterm2: to select the exact tab running the session the user clicked.
> • application-groups: the small hook reporter (run by the agent, inside the app bundle) appends status events that the app reads.
> • files.downloads.read-write: CSV export of the user's own session history.
>
> No data leaves the Mac; the app makes no network requests and has no account.

## TestFlight checklist

Install the TestFlight build on a Mac with Claude Code and/or Codex, then:

- [ ] First launch: the panel appears top right; the menu bar shows the eye.
- [ ] Settings → Hooks → Install: the diff previews, Apply succeeds, and `~/.claude/settings.json` points at the reporter inside the app.
- [ ] Run `claude` in Terminal: the row appears within a second (events flow through the App Group).
- [ ] Permission prompt: the row turns orange, and a notification appears with Show / Snooze / Mute.
- [ ] Click the row: the Terminal tab comes forward (approve the Automation prompt once).
- [ ] VS Code session: clicking focuses the existing window, no new window.
- [ ] Process detection: quit `claude`; the row goes to *ended* within a few seconds. If it doesn't, the sandbox is blocking process inspection; tell me.
- [ ] Claude desktop app Code session shows with its title.
- [ ] Dashboard: 7 Days shows history; Export writes a CSV to Downloads.
- [ ] ⌃⌥Space opens the panel with search focused; typing and Return jump.
- [ ] Launch at login toggles in Settings → General.
