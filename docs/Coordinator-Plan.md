> Historical proposal and implementation notes. Current behavior and verification: [COORDINATOR.md](COORDINATOR.md). Unexpected review changes are now preserved; this document’s discard behavior is superseded.

**# Coordinator (proposal)**



Status: proposal, not built. Research checked on 2026-10-08 against Claude Code 2.1.282 and the

Codex CLI 0.160.1 bundled with the VS Code extension (\`openai.chatgpt-26.930.\*\` / \`26.1002.\*\`).

Clickable prototype: https\://claude.ai/artifact/VaojrcXfJt9kufm1TZ93u6 (private to the owner).



The Coordinator is a new Agent HUD window for driving agents, not just watching them. It has a

rail of projects on the left, the selected session's conversation in the middle, and every running

agent on the right. Finished turns report into the conversation, and you can reply to keep a

session going. It can also run Claude and Codex as a **\*\*pair\*\*** on one goal, passing the work between

them (plan → review → build → review) until the reviewer approves.



This document lists the behavior, what the agents' interfaces allow, a proposed architecture, and

the questions that still need an answer. \*\*Reviewers: section 7 lists the claims that most need

checking.\*\* Mark anything here that is wrong or out of date.



**## What's possible today**



Checked against Claude Code 2.1.282 and the Codex 0.160.1 bundled with the VS Code extension. This

is the finding that shapes the design: the Coordinator can fully drive the sessions it starts.

Sessions started in a terminal or VS Code, whether Claude or Codex, are read-only. Section 4 has the

evidence.



\| Piece | How | Status |

\|---|---|---|

\| Project rail, statuses, running column | Already in the app: \`SessionStore\`, hooks, process scan, transcripts. | Ready |

\| Auto-report when a turn ends | Stop hooks plus the transcript tail; files and tests are already summarized for notifications. | Ready |

\| Chat with Claude sessions started in the Coordinator | \`claude -p --input-format stream-json --output-format stream-json --resume\`, one process per session; prompts via \`--permission-prompts host\`. | Works |

\| Chat with Codex sessions started in the Coordinator | Its own \`codex app-server\` over JSON-RPC: \`thread/start\`, \`turn/start\`, \`turn/steer\`, \`turn/interrupt\`, approval requests. | Works, needs a test |

\| Chat with Codex open in VS Code | Each VS Code window runs a private \`codex app-server\` over stdio, and the shared daemon isn't running. Only candidate: \`codex queue\`, untested. | Read-only |

\| Chat with a Claude session open in VS Code or a terminal | No supported way in. Options: copy & open (ships today), tmux \`send-keys\` for tmux panes, or Move here (stop it, then \`--resume\` in the Coordinator). | Read-only |

\| Claude + Codex pair | Both agents run under the Coordinator, so it owns turn order, handoff summaries, the edit lock, and stop rules. A worktree per pair avoids clashes. | Most new code |

\| Background Claude sessions | \`claude --bg\` + \`claude agents --json\` list and stop them, but there's no command to send a message to one that's already running. | List only |



**## 1. Goals**



1\. One place to see every project's sessions grouped by state: needs you, just finished, working, idle.

2\. Click a project to read its conversation, with each finished turn posted as a short report.

3\. Reply from the Coordinator to keep a session going, and answer permission prompts inline.

4\. Pair Claude and Codex on one project: they take turns planning, building and reviewing, and stop

&#x20;  when the reviewer approves, a limit is hit, or a stop rule fires.



Non-goals: replacing the terminal or editor; typing keystrokes into other apps; approving commands

without the user; pushing or merging without the user.



**## 2. The flow (as prototyped)**



\| # | Step | What happens |

\|---|---|---|

\| 1 | Open | Panel **\*\*Menu → Coordinator\*\*** (proposed shortcut ⌃⌥C). It opens a separate window. Everything else in Agent HUD opens inside the panel; this is a deliberate exception, because a three-column chat doesn't fit a \~360 pt panel. |

\| 2 | Board | Title bar has the same filter tabs as the panel (All / You / Busy / Done) and **\*\*＋ New pair\*\***. Left rail: one row per project, grouped in panel order, with a dot per session. Middle: the conversation. Right: **\*\*Running now\*\*** (every live agent: current tool, elapsed time, context ring, subagents) and **\*\*Finished today\*\***. |

\| 3 | Watched session | A session started elsewhere (e.g. Claude in VS Code) shows its transcript read-only. The composer is replaced by **\*\*Copy reply & open VS Code\*\*** (the existing Quick Answers flow) and **\*\*Move here…\*\*** (only when idle; see 4.3). |

\| 4 | Report | When a turn ends, a report card is posted: duration, files edited (+lines), test result, and the start of the reply. The project moves to *\*Just finished\** (blue dot, 2-minute rule, as in the panel). |

\| 5 | Reply | For sessions started in the Coordinator, the composer sends into the same conversation. A message sent while busy is queued until the turn ends; ⌥↩ stops the turn and sends now. |

\| 6 | Prompt | Permission prompts appear inline (Allow once / Allow rule for project / Deny). The project jumps to *\*Needs you\**, and the window gets the panel's orange edge. |

\| 7 | New pair | Sheet: project, goal, turn order (default Claude plans → Codex reviews plan → **\*\*you approve\*\*** → Claude builds → Codex reviews diff, with review and fix repeating up to 3 rounds), **\*\*Swap roles\*\***, a new worktree on \`pair/\<slug>\` (default) or the current checkout, and stop rules. |

\| 8 | Pair running | One thread; each handoff is a divider ("Handed to Codex · review diff · round 1"). The right column becomes the pair timeline: phases, round N of M, who holds the edit lock, branch, files changed, tokens per agent, Pause after this turn, Stop. |

\| 9 | Pair done | Final report: files, tests, branch and commits (not pushed). Actions: **\*\*Open diff in VS Code\*\***, **\*\*Merge into main…\*\*** (asks and shows the diff first), **\*\*Keep going…\*\*** (new goal, same two sessions). |



**## 3. Two kinds of session**



The research findings divide sessions into two kinds, and the UI shows which kind each one is:



\- **\*\*Managed\*\***: started by the Coordinator, which owns the agent process (or the app-server

&#x20; connection). The Coordinator can send messages, interrupt the turn, and answer prompts. The rail

&#x20; shows a **\*\*Coordinator\*\*** chip.

\- **\*\*Watched\*\***: started anywhere else (terminal, VS Code, Claude.app, ChatGPT.app). It is read-only,

&#x20; using the hooks, the process scan and the transcripts Agent HUD already reads. The rail shows the

&#x20; host chip (**\*\*VS Code\*\***, **\*\*Terminal\*\***, …), as the panel does today.



A watched session can become managed only by **\*\*Move here\*\***: stop it in its host, then resume the

same conversation under the Coordinator. Two processes must never run one conversation at the

same time.



**## 4. What the agents allow**



**### 4.1 Claude Code: managed sessions (works)**



Headless print mode with streaming JSON in and out keeps one long-lived process per session:



\`\`\`

claude -p --input-format stream-json --output-format stream-json \\

&#x20;      \--include-partial-messages --replay-user-messages \\

&#x20;      \--permission-prompts host \\

&#x20;      [--resume \<session-id> | --session-id \<uuid>]

\`\`\`



\- \`--input-format stream-json\` (only with \`-p\`): user messages are written to stdin as JSON lines while the process runs.

\- \`--replay-user-messages\`: user messages are echoed on stdout, which confirms delivery.

\- \`--permission-prompts host\`: prompts are sent to the SDK host (or a \`--permission-prompt-tool\`) instead of being denied.

\- Hooks still fire, so the session also shows up in \`events.jsonl\` like any other.



Not yet verified: the exact control-message schema for answering a permission prompt and for

interrupting a turn over stdin. The Agent SDK implements both, so the protocol exists, but Agent

HUD would speak it directly from Swift (there is no Swift SDK). See 7.1.



**### 4.2 Claude Code: watched sessions (read-only)**



There is no supported way to send a message into an interactive Claude session that another app owns.



\- \`claude agents --json\` lists active sessions (interactive and background) with \`pid\`, \`cwd\`,

&#x20; \`sessionId\`, \`name\` and \`status\` (\`busy\`/\`idle\`). It is useful as an extra liveness and status

&#x20; source, but it can't send anything.

\- \`claude --bg\` sessions can be listed, attached (\`claude attach \<id>\`), stopped and read with

&#x20; \`claude logs \<id>\`. There is no "send message to background session" command.

\- **\*\*Channels\*\*** (see the Claude Code docs) push messages into sessions that opted in at launch. That

&#x20; doesn't help with sessions that are already running, and it would mean changing how users start Claude.

\- **\*\*Stop-hook continuation\*\*** (a Stop hook returns a block decision with a reason) can make a session

&#x20; keep going with text the hook supplies. In principle the Coordinator could answer a pending Stop

&#x20; hook. Risks: the hook has to wait (bounded), loops have to be prevented, and every session would

&#x20; pay that wait on every stop. Not proposed for v1.

\- tmux panes: \`tmux send-keys\` works technically (\`Sources/AgentHUDCore/Tmux.swift\` already finds

&#x20; the pane), but it is keystroke injection into a TUI. It could be offered behind an explicit

&#x20; setting at most.



**### 4.3 Move here**



Only for idle sessions: stop the host's process (for a terminal, the same pid/tty the Focuser

already knows; for VS Code, close the panel or end the session), then start the managed process

with \`--resume \<id>\`. Open questions: whether a VS Code Claude panel notices the conversation

moving and stops cleanly, and whether \`claude --bg --resume \<id>\` is a better route (its help says

it "continues that session in the background under the same ID, or starts a copy and says so").



**### 4.4 Codex: managed sessions (works, untested end to end)**



\`codex app-server\` speaks JSON-RPC (schemas: \`codex app-server generate-json-schema --out DIR\`).

The methods the Coordinator needs:



\| Need | Method | Required params |

\|---|---|---|

\| Start or resume a conversation | \`thread/start\`, \`thread/resume\` | \`threadId\` for resume |

\| Send a message | \`turn/start\` | \`threadId\`, \`input\` (also \`cwd\`, \`sandboxPolicy\`, \`approvalPolicy\`, \`model\`, \`effort\`) |

\| Add to a running turn | \`turn/steer\` | \`threadId\`, \`input\`, \`expectedTurnId\` |

\| Stop | \`turn/interrupt\` | |

\| Stream output | \`item/started\`, \`item/completed\`, \`item/agentMessage/delta\`, \`turn/started\`, \`turn/completed\`, \`turn/diff/updated\`, \`turn/plan/updated\`, \`thread/status/changed\`, \`thread/tokenUsage/updated\` | |

\| Prompts | server requests \`item/commandExecution/requestApproval\`, \`item/fileChange/requestApproval\`, \`item/permissions/requestApproval\`, \`item/tool/requestUserInput\` | |

\| List | \`thread/list\`, \`thread/loaded/list\`, \`thread/read\`, \`thread/turns/list\` | |



\`turn/steer\` with \`expectedTurnId\` lets the Coordinator add guidance mid-turn without starting a

new turn. Claude has no equivalent; there the composer queues instead.



\`sandboxPolicy\` per turn is how a Codex **\*\*reviewer\*\*** runs read-only in a pair (7.2).



**### 4.5 Codex: watched sessions (read-only, with one candidate)**



The \*\*prototype and an earlier summary said Codex sessions started in VS Code could be messaged

through a shared app-server daemon. That is wrong for this machine.\*\* As checked:



\- Each VS Code window runs its own \`codex -c features.code_mode_host=true app-server

&#x20; \--analytics-default-enabled\` as a child of the extension host, over stdio. Eight were running.

&#x20; Another process can't connect to them.

\- The shared daemon (\`codex app-server daemon start\`, \`codex app-server proxy\`, \`codex agents\`) is

&#x20; not running. \`\~/.codex/app-server-control/app-server-control.sock\` does not exist.

\- \`\~/.codex/ipc/ipc.sock\` **\*\*does\*\*** exist. Its purpose is unknown (7.2).

\- \`codex queue --thread \<uuid|name> --message \<text>\` ("Queue a message for an existing session")

&#x20; is the only candidate route into a session another process owns. It has not been tested, and

&#x20; neither has whether the VS Code extension picks the message up.



So v1 treats Codex like Claude: managed sessions get full chat; watched ones are read-only plus

copy & open, unless \`codex queue\` turns out to work.



**## 5. Proposed architecture**



Swift, macOS 14+, no new dependencies, matching the existing app.



\`\`\`

&#x20;                    ┌──────────────── CoordinatorWindow (SwiftUI, NSWindow) ────────────────┐

SessionStore ───────▶│ ProjectRail        ChatView (per session)         RunningColumn        │

(existing: hooks,    └──────────▲───────────────────▲─────────────────────────────▲──────────┘

&#x20;scans, transcripts)            │                   │                             │

&#x20;                        TranscriptReader     SessionBridge (protocol)      PairOrchestrator

&#x20;                        (watched, read-only)   ├─ ClaudeBridge  (stdio stream-json, 1 proc/session)

&#x20;                                               └─ CodexBridge   (stdio JSON-RPC to own \`codex app-server\`)

\`\`\`



\- **\*\*SessionStore stays the source of truth for state.\*\*** Managed sessions still fire hooks, so rows,

&#x20; dots, notifications and the Dashboard work unchanged. Bridges add the ability to act; they don't

&#x20; run a second state machine.

\- **\*\*SessionBridge\*\*** (\`send(text)\`, \`interrupt()\`, \`answer(promptId, decision)\`, \`events: AsyncStream\`).

&#x20; \- **\*\*ClaudeBridge\*\*** spawns \`claude -p …stream-json…\` per session and keeps stdin open.

&#x20; \- **\*\*CodexBridge\*\*** spawns one \`codex app-server\` per Coordinator (it hosts many threads) and talks

&#x20;   JSON-RPC over stdio.

\- **\*\*TranscriptReader\*\*** turns \`\~/.claude/projects/\*\*.jsonl\` and Codex rollouts into chat items. The

&#x20; Dashboard's \`HistoryIndex\` and Quick Answers already parse these, so their parsers can be shared.

\- **\*\*Report cards\*\*** come from data the app already collects for "Finished" notifications (duration,

&#x20; files changed, test runs). See \`Session.filesChanged\` and \`TestRun\` in \`Sources/AgentHUDCore/Session.swift\`.

\- **\*\*Lifetime.\*\*** Managed processes are children of Agent HUD, so quitting or updating Agent HUD kills

&#x20; them. Options: keep them alive with \`--bg\`-style detaching, or warn before quitting and resume on

&#x20; relaunch (\`--resume\` / \`thread/resume\`). The auto-updater already waits while a session needs

&#x20; input; it would also have to wait for managed turns.

\- **\*\*Window.\*\*** A normal \`NSWindow\`, not the floating \`NSPanel\`. It's the first real window, so the

&#x20; Dock icon/\`LSUIElement\` behavior needs a decision (7.4).



**## 6. Pairing protocol**



A pair is two managed sessions (one Claude, one Codex) plus a small state machine in \`PairOrchestrator\`.



**\*\*Phases\*\*** (default; roles can be swapped):



\`\`\`

PLAN(Claude) → REVIEW_PLAN(Codex) → APPROVE(user, optional) → BUILD(Claude)

&#x20;  → REVIEW_DIFF(Codex) ─approve→ DONE

&#x20;                       └changes→ FIX(Claude) → REVIEW_DIFF(Codex) … (max N rounds, default 3)

\`\`\`



**\*\*Handoffs pass summaries, not transcripts.\*\*** Each agent keeps its own context. The orchestrator

builds the next agent's message from:



\- the goal

\- the latest artifact: plan text, or \`git diff \<base>..HEAD\` from the worktree, or the review findings

\- the round number and the stop rules

\- an instruction to end with a machine-readable verdict



Ask reviewers for a structured verdict so the orchestrator never has to guess.

Codex's \`turn/start\` takes an \`outputSchema\`; for Claude, use \`--json-schema\` or a fenced JSON block.



\`\`\`json

{ "verdict": "approve" | "changes", "findings": [{ "file": "", "line": 0, "issue": "", "severity": "blocker|nit" }] }

\`\`\`



**\*\*Edit lock.\*\*** Only the agent holding the turn may write. The reviewer runs read-only:



\- Codex: \`sandboxPolicy\` read-only on review turns.

\- Claude: when Claude is the reviewer, a read-only permission mode or a deny rule for Edit/Write.



The lock is also enforced by phase: the orchestrator never has two turns open at once.



**\*\*Worktree.\*\*** Default \`git worktree add ../\<repo>-pair-\<slug> -b pair/\<slug>\`. The builder commits

at the end of each build/fix turn so the reviewer diffs commits, not a dirty tree. Nothing is

merged or pushed without the user.



**\*\*Stop rules\*\*** (any one pauses the pair and marks it *\*Needs you\**):



\- the round limit is reached without approval

\- tests fail in two consecutive build/fix turns

\- an optional path guard (e.g. any change outside \`src/\`)

\- a per-pair token or time budget

\- either agent asks the user a question (Claude \`AskUserQuestion\`, Codex \`requestUserInput\`)

\- any permission prompt that the session's policy doesn't auto-allow



**\*\*User intervention.\*\*** A message typed into a pair goes to whoever has the turn (Codex: \`turn/steer\`;

Claude: queued for its next turn), or to a chosen agent. **\*\*Pause after this turn\*\*** and **\*\*Stop\*\*** are

always available.



**## 7. Open questions for review**



Checked so far by reading \`--help\` output and generated schemas, not by sending live traffic.



**### 7.1 Claude Code**

1\. What is the exact stdin control-message schema in \`--input-format stream-json\` mode for:

&#x20;  \- (a) answering a permission request under \`--permission-prompts host\`

&#x20;  \- (b) interrupting the current turn

&#x20;  \- (c) sending a user message while a turn is running: is it queued or rejected?

2\. Can a stream-json process resume a session that is still open in another process? We assume no

&#x20;  and require the other process to be stopped first. What actually happens: a copy, an error, or

&#x20;  corruption?

3\. Is \`claude --bg --resume \<id>\` plus \`claude attach\` a better fit for managed sessions than a raw

&#x20;  \`-p\` child, given that it survives Agent HUD quitting? Can anything be written to a background

&#x20;  session's input without attaching?

4\. Is there any supported injection route into an already-running interactive session that we've

&#x20;  missed? (Channels needs opt-in at launch; Remote Control is cloud-bound.)



**### 7.2 Codex**

1\. Does \`codex queue --thread \<id> --message \<text>\` deliver to a thread owned by a VS Code

&#x20;  extension's private app-server? When is it delivered, and how is receipt confirmed?

2\. What is \`\~/.codex/ipc/ipc.sock\`, and can a third-party client use it to reach running threads?

3\. If the Coordinator runs its own \`codex app-server\` and calls \`thread/resume\` on a thread that a

&#x20;  VS Code app-server also has loaded, what happens?

4\. Do we need to call \`thread/unsubscribe\` or \`thread/archive\` when a pair ends?

5\. Can the read-only reviewer turn rely on \`sandboxPolicy\` alone, or are file-change approvals still

&#x20;  requested and need auto-denying?

6\. Is \`outputSchema\` on \`turn/start\` stable enough to use for the reviewer verdict?

7\. Should we prefer the shared daemon (\`codex app-server daemon start\` + \`proxy --sock\`) over a

&#x20;  private stdio app-server, so that Codex threads started from the Coordinator survive Agent HUD

&#x20;  restarts and show up in \`codex agents\`?



**### 7.3 Pairing**

1\. Is plan → review → build → review the right default, or should the reviewer also write failing

&#x20;  tests first (TDD split)?

2\. How big can a diff handoff get before it should be summarized or limited to file lists plus hunks?

3\. Should the pair share one worktree (turn-taking) or use two (reviewer gets a read-only checkout)?



**### 7.4 Product**

1\. A separate window breaks "everything happens in the panel". Is that acceptable, or should the

&#x20;  panel grow into this mode like the Dashboard does?

2\. Agent HUD is \`LSUIElement\` (no Dock icon). Should a Coordinator window bring a Dock icon while open?

3\. Where do managed sessions' API costs show? The Dashboard already counts tokens from transcripts,

&#x20;  so this probably works for free. Verify for Codex threads started by our own app-server.



**## 8. Rough build order**



1\. Read-only Coordinator: window, rail, transcript chat, running column, report cards. No new

&#x20;  process control. Useful on its own.

2\. ClaudeBridge: start managed Claude sessions from the window (**\*\*New session\*\***), chat, inline

&#x20;  prompts, interrupt.

3\. CodexBridge: same for Codex via a private \`codex app-server\`.

4\. Move here (idle watched → managed).

5\. PairOrchestrator with worktree, edit lock, structured verdicts, stop rules.

6\. Optional: \`codex queue\` for watched Codex sessions, if 7.2.1 checks out.



Each step should ship behind a setting until the next one lands.


---

# 9. Research addendum: make control a capability, not a session-origin restriction

Added 2026-10-08. This section supersedes categorical “started elsewhere means read-only” statements in sections 3–4 and the build order in section 8. Preserve the original observations as machine-specific findings, not universal product limitations.

**Conclusion:** The Coordinator is feasible. Full control of sessions it starts is the easiest baseline, but externally started sessions can also expose control through an opted-in bridge. Arbitrary sessions with no bridge remain observable until they are connected, migrated, or controlled through an explicitly enabled UI adapter. Do not promise that every already-running VS Code panel can be attached without preparation.

Evidence labels used below:

- **Documented:** described by an official interface or official source.
- **Proposed:** an architecture we can implement using those interfaces.
- **Unverified:** requires a test against the installed CLI and extension. No live agent tests were run for this addendum; neither CLI is available in this research environment. The original machine's binaries, processes, flags, and socket observations were not independently reproduced.

## 9.1 Corrections and routes around the limitations

| Original conclusion | Revised conclusion | Implementation route |
|---|---|---|
| Externally started Claude sessions are read-only | Sessions without a control bridge are read-only; opted-in interactive sessions can receive channel events and expose replies | Local Coordinator channel; reconnect or relaunch once with opt-in |
| Channels require changing launch behavior, so exclude them | A one-time launch/configuration integration is a practical product feature | “Enable Coordinator connection” setup, then a terminal launcher or project task |
| Stop-hook input requires waiting at every stop | A hook can check for an already-queued message and return immediately when empty | Nonblocking local mailbox, available at a subsequent natural stop |
| Codex VS Code stdio servers cannot be connected to | True for a private stdio transport; it does not rule out connectable servers launched deliberately | Shared local broker; prove stock extension connectivity separately |
| Background sessions are list-only | Background lifetime and writable transport are separate concerns | Broker-owned streaming processes or opted-in channel sessions |
| Quitting Agent HUD kills child agents | Parent-child ancestry alone does not determine lifetime; pipes, cleanup and process supervision matter | Independent helper owns processes and pipes |
| No Swift SDK means protocol features are impossible | Native integration is possible, but a private protocol carries maintenance cost | Versioned Swift adapter or a small official-SDK sidecar |
| Denying Edit/Write makes Claude reviewer read-only | Shell commands and other tools can still write | Filesystem enforcement or isolated disposable review checkout |

## 9.2 Claude: local channels for sessions started outside the Coordinator

**Documented evidence:** Claude Channels is a local MCP subprocess that can deliver events to an interactive session and expose a reply tool. It requires session opt-in. It is a research preview with organization/allowlist restrictions; custom development channels require an interactive launch and cannot use the development bypass in print/SDK mode. [S1–S2]

**Proposed implementation:** Build an Agent HUD channel with an authenticated connection to a local broker. The MCP subprocess handles Claude's stdio connection; the Swift app talks to the broker. Give each registration a unique channel-instance ID, project identity and session binding. Never route by project path alone: one project can contain several sessions.

Provide these user flows:

1. Existing connected terminal session: click it and reply from the Coordinator while retaining the terminal UI.
2. Unconnected session: offer “Enable connection on next launch” and “Continue here” after verified handoff.
3. VS Code Claude panel: expose channel control only after a compatibility test proves that this host loads and opts into the channel. Otherwise offer a connected terminal within VS Code or managed continuation.

The app accepts a message into a durable outbox, sends the channel notification, and marks separate states for **queued locally**, **forwarded to channel**, and **observed in session**. A socket write is not proof the agent consumed the instruction. Add a reply/report tool carrying the message ID to help correlate responses; missing model acknowledgment must remain uncertain.

Channel events are additional context, not proof of SDK-style interrupt semantics. Advertise the capabilities actually tested. Do not silently implement Stop with a process kill.

**Permission relay:** The channel contract defines a permission-request notification and an allow/deny response using the issued request ID. This permits inline approvals for connected sessions. Local answers can win the race. Channel relay supports per-request decisions; do not show “Allow rule for project” unless another verified interface persists that rule. [S1]

Keep this as a preview feature until custom-channel distribution and the relevant account policies permit normal installation. Launch-time opt-in is a setup cost, not proof the feature cannot be built.

## 9.3 Claude: fast Stop-hook mailbox as a limited fallback

**Documented evidence:** A Stop hook can return a block decision with a reason, causing Claude to continue. The hook input includes `stop_hook_active` for loop handling. Stop hooks do not run after a user interrupt. [S3]

**Proposed implementation:** Reuse the app's hook installation to check a broker mailbox by exact session ID. Read a pending instruction once; otherwise return immediately. Do not wait for the user at every stop and do not keep Claude spinning with repeated “check again” instructions.

Use a short timeout and return normally if the broker is unavailable. Lease the message before returning its text, then reconcile consumption against subsequent session activity. Distinguish pending, offered and observed states so a failed hook does not lose the message or trigger blind duplicate execution. Apply a continuation budget and test the loop guard with two successive queued messages.

This can deliver guidance queued **before a future natural stop**. It cannot wake an already-idle agent on its own. Label it “Send at next completion,” rather than “live chat.” Confirm whether the installed version loads new hook configuration into existing sessions; require restart if it does not. This is worth a bounded prototype instead of dismissing it because of an assumed wait penalty.

## 9.4 Claude: managed streaming and SDK fallback

**Documented evidence:** The Agent SDK supports streaming input and interactive approvals/user questions. Its Python client exposes interruption. This establishes that the control operations exist; it does not make every raw CLI flag or wire format a stable public contract. [S4–S6]

Keep Swift as the app implementation. Choose between:

- **Native adapter:** mirror the control protocol of a pinned SDK/CLI version, with fixtures for initialization, permissions, cancellation, result events and repeated turns. Record the upstream source revision from which each payload was derived.
- **SDK sidecar:** a small Node or Python process using the official SDK, exposing a narrow local JSON protocol to Swift. This adds a runtime/distribution dependency, but reduces reverse-engineering work.

Do not let “no new dependencies” block the entire feature. Treat it as a preference and compare packaging size, startup time, maintenance and licensing. The sidecar is a fallback or first integration spike, not a requirement to rewrite Agent HUD.

Test the original `--permission-prompts host` invocation against the installed CLI before adopting it. For messages sent while busy, make queueing an explicit broker policy until the actual CLI behavior is verified. Queueing, interruption, and live steering are different capabilities.

## 9.5 Codex: reachable app-server, queue investigation and VS Code limits

**Documented evidence:** Codex app-server exposes stdio, WebSocket and Unix-socket transports. Its documentation shows a terminal UI connecting with `codex --remote` to a listener. Network transport remains experimental. Thread history resume is a conversation operation, not evidence that another client's live private server becomes reachable. [S7]

**Proposed reliable route:** A broker owns one app-server and its stdio pipes. Agent HUD connects to the broker, which maintains subscriptions, pending approvals and per-thread turn state. This solves Coordinator relaunch without depending on a network listener. A shared listener is an optional route for a separately connected terminal UI; gate it on the installed version's actual help and transport behavior.

Stock VS Code extension connectivity is a separate compatibility question. Check its documented settings/commands and source when available. A companion extension cannot automatically access another extension's internal stdio or private webview state. If the stock extension cannot target the shared server, offer a connected terminal or an Agent HUD companion view. Do not describe either as attaching the existing stock panel.

**`codex queue` remains a priority experiment, not a verified solution.** The pasted plan reports the command locally, but this research did not establish its exact routing contract from an official source. Inspect installed help, schemas and the matching Codex source tag. Then test:

| Target | Essential checks |
|---|---|
| Coordinator-owned thread | idle/busy submission; receipt; cancellation; restart |
| Stock VS Code private server | whether it reaches that owner; whether the panel updates |
| Terminal-created thread | exact live-owner selection; no duplicate runtime |
| Stopped thread | whether it queues, resumes, fails, or targets another server |
| Same thread loaded twice | reject ambiguity or target a proven owner; never silently choose |

Record process, endpoint, thread/turn IDs and timeline for each test. A successful command exit or a changed history file is insufficient. Prove delivery by a uniquely tagged prompt and the target runtime's observed response.

The presence of `~/.codex/ipc/ipc.sock` does not establish a supported control API. Identify its creator and matching source/protocol before opening it. Avoid rollout-file writes, attaching a debugger, scraping secrets, or replacing the extension's binary as a normal integration strategy.

## 9.6 Replace two session classes with explicit capabilities

Keep host/origin as display metadata. Store independently:

```swift
struct SessionCapabilities {
    var observe: Bool
    var sendNextTurn: Bool
    var sendAtCompletion: Bool
    var steerActiveTurn: Bool
    var interruptTurn: Bool
    var answerPermission: Bool
    var answerQuestion: Bool
    var reconnect: Bool
}
```

Track an owner ID, connection ID, CLI version and transport alongside capabilities. Suggested control modes: observed, channel-connected, hook-connected, broker-managed and automation-connected. Render the composer and buttons from capability evidence rather than “launched here.” Downgrade immediately when the bridge disconnects; preserve the draft.

Extend `SessionBridge` with a structured send mode and delivery receipt. Make unsupported operations explicit errors. Keep broker transport state authoritative for commands and approvals; SessionStore remains the UI projection. Hooks and transcripts enrich observations but must not overwrite a newer command result with a stale idle status.

## 9.7 Durable local broker and performance

**Proposed:** Package a small helper with Agent HUD and launch it independently of the UI. It owns agent processes, stdin/stdout, approvals, outbox and pair state. Agent HUD quitting detaches the UI; stopping work is a separate explicit action. Choose an Apple-supported helper/service packaging route during the macOS spike. [S8]

Persist session IDs, message IDs, pair phase, base/build SHAs and event cursors. On recovery, reconnect and reconcile before sending anything. Mark an interrupted in-flight tool as unknown until inspected; never replay a possibly completed edit just because the UI missed an acknowledgment.

Performance requirements to measure, not claim as achieved:

- No new model process for a merely observed session.
- Incremental transcript parsing; cap in-memory chat history and page older messages.
- Event-driven IPC; no full process/transcript scan on each token.
- Coalesce UI text updates and use bounded queues with backpressure.
- Lazy-start controlled sessions; reuse one Codex app-server where supported.
- Stop-hook mailbox target: under 50 ms on a healthy local broker, with a hard short timeout.
- Benchmark 20 observed sessions and several active managed sessions for CPU, RSS, typing latency and reconnection. Report agent memory separately from Coordinator overhead.

## 9.8 Pairing and migration fixes

Pair orchestration remains a good fit for broker-managed sessions. An external session may join only when its bridge has sufficient capabilities and the user agrees to its workflow control.

Before “Move here,” establish the actual owner, stop or detach through the host, confirm active work and background writers are finished, then resume. An idle main thread does not prove that all subprocesses or subagents stopped. If ownership cannot be established, offer an explicitly labeled fork/copy. Never invent a guarantee that concurrent resume is safe.

Enforce one active builder lease, but recognize that the lease binds only cooperating clients. Test shell, MCP and background-tool writes in reviewer mode. Denying Edit/Write alone is insufficient. If filesystem restrictions cannot cover every write route, review a disposable isolated checkout without valuable writable mounts or credentials and compare it afterward.

Use exact base/build commits for review and require a validated structured verdict tied to that build SHA. Reject a verdict for an older revision. Do not parse an invalid JSON answer as approval. A model's approval does not substitute for required tests. Persist round/time/token limits in the broker so reconnecting does not reset them.

## 9.9 Optional automation fallback

If broad control of unmodified running panels is a required product goal, amend the original non-goal about typing into other apps. An opt-in macOS Accessibility adapter or tmux adapter is an engineering fallback, with different reliability from a protocol bridge.

Prototype only exact-window/pane targeting, idle composer submission, user-visible confirmation of the target and reconciliation against the transcript. Never send blind keystrokes based on focus or use text submission as permission approval. Accessibility requirements and each host's exposed controls need local testing. This may improve coverage, but cannot justify a universal “every session fully controllable” claim.

## 9.10 Revised build order and acceptance gates

1. **Capability research spike before freezing the UI:** managed Claude approval/interrupt/repeated-turn tests; interactive local channel test; Stop-hook mailbox; Codex queue against a stock VS Code session; shared-server terminal test.
2. **Durable broker plus observed Coordinator:** transcript pagination, reports, connection registry and outbox.
3. **Managed Claude/Codex bridges:** verified send modes, approvals, questions, interrupt and relaunch recovery.
4. **Connected external Claude sessions:** preview channel onboarding; hook delivery where useful. Ship stock VS Code support only where proven.
5. **Codex external control:** enable queue or shared-server attachment only for a passed host/version matrix. Keep unsupported hosts observable.
6. **Verified migration/fork flows.**
7. **Pair orchestrator:** exact-revision handoffs, enforced review environment, stop budgets, crash recovery and test evidence.
8. **Optional UI automation adapters:** separate opt-in and compatibility coverage.

Every adapter must demonstrate correct session targeting with two sessions in the same project, an active turn, a permission prompt, disconnect/reconnect and a host restart. Delivery states must remain truthful. An unavailable bridge should leave a usable observation view and preserved reply draft.

### Research sources

Sources checked 2026-10-08. Official documentation describes capabilities; local behavior must be verified against the actual installed versions. Architecture and acceptance criteria above are proposals, not measurements.

- **S1:** [Anthropic — Channels reference](https://code.claude.com/docs/en/channels-reference). Channel contract, custom-development restrictions, reply tools and permission relay.
- **S2:** [Anthropic — Channels](https://code.claude.com/docs/en/channels). Opt-in, lifecycle and organization controls.
- **S3:** [Anthropic — Hooks reference](https://code.claude.com/docs/en/hooks). Stop continuation and loop handling.
- **S4:** [Anthropic — SDK streaming input](https://code.claude.com/docs/en/agent-sdk/streaming-vs-single-mode).
- **S5:** [Anthropic — SDK approvals and user input](https://code.claude.com/docs/en/agent-sdk/user-input).
- **S6:** [Anthropic — Python SDK client source](https://github.com/anthropics/claude-agent-sdk-python/blob/main/src/claude_agent_sdk/client.py).
- **S7:** [OpenAI — Codex App Server](https://developers.openai.com/codex/app-server). Transports, remote terminal client and thread lifecycle.
- **S8:** [Apple — SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice). Helper/service integration starting point; implementation needs a platform-specific spike.

---

# 10. Spike results (2026-10-08)

Run against Claude Code 2.1.282 (Haiku) and Codex CLI 0.162.0-alpha.2 (the VS Code extension's
`26.1002.51308` binary), in a scratch git repo. Each test session was started by the spike itself; no
messages were sent into existing sessions. Harnesses: Python scripts that spoke each protocol over stdio.

## 10.1 Claude managed streaming (§9.4): works, with one flag correction

Command that works:

```
claude -p --input-format stream-json --output-format stream-json --verbose \
       --permission-prompts host --permission-prompt-tool stdio --replay-user-messages
```

| Check | Result |
|---|---|
| Handshake | `{"type":"control_request","request_id":"init1","request":{"subtype":"initialize"}}` → `control_response` success (lists commands). |
| Send a turn | `{"type":"user","message":{"role":"user","content":"…"}}` on stdin. Replay echo has `"isReplay":true`, which confirms receipt. Turn ends with `{"type":"result","subtype":"success"}`. |
| Repeated turns | Several turns in one process, same `session_id`. |
| Permissions | **`--permission-prompts host` alone did not route prompts to the host**: Bash was denied (`system`/`permission_denied`). Adding **`--permission-prompt-tool stdio`** produced `{"type":"control_request","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{…}}}`. Replying `{"type":"control_response","response":{"subtype":"success","request_id":"<id>","response":{"behavior":"allow","updatedInput":<input>}}}` ran the command (file created). |
| Message while busy | A second user message sent mid-turn was queued and ran as its own turn afterwards (two `result`s). Not rejected and not merged. |
| Interrupt | `{"type":"control_request","request_id":"int1","request":{"subtype":"interrupt"}}` → `control_response` `{"still_queued":[]}`; the assistant message is marked `"aborted":true`, a user line `[Request interrupted by user]` follows, and the turn ends with `result` `subtype:"error_during_execution"`, `is_error:true`. The next message runs normally. |
| Hooks | SessionStart and the others still fire (`hook_started`/`hook_response` system events), so managed sessions also reach `events.jsonl`. |

Not yet tested: deny responses, `AskUserQuestion` over the control channel, `--resume` of a session that's
open elsewhere, behavior when stdin closes mid-turn.

## 10.2 Codex app-server over stdio (§9.5): works

`codex app-server` (stdio JSON-RPC), our own process:

| Check | Result |
|---|---|
| Handshake | `initialize` with `{"clientInfo":{"name":…,"version":…}}`, then the `initialized` notification. |
| Start | `thread/start` `{"cwd","approvalPolicy":"on-request","sandbox":"workspace-write"}` → thread id. MCP servers from `~/.codex/config.toml` start with it. |
| Turn | `turn/start` `{"threadId","input":[{"type":"text","text":…}]}` → `turn/started` … `turn/completed` with the `agentMessage` items. |
| Steer | `turn/steer` `{"threadId","expectedTurnId","input"}` mid-turn → the running turn changed course ("STEERED"); same turn id completed. |
| Interrupt | `turn/interrupt` `{"threadId","turnId"}` → `turn/completed` with `"status":"interrupted"`; rollout gets `event_msg` `turn_aborted`. |
| Rollouts | The thread writes a normal rollout under `~/.codex/sessions`, so history and the Dashboard see it. |

Not yet tested: approval requests (`item/commandExecution/requestApproval`) and their response shape,
`thread/resume` after restarting the app-server, `codex queue`, the shared daemon.

## 10.3 Transcript formats seen while building the chat reader

- Codex 0.162 rollouts no longer write `event_msg` `user_message`/`agent_message`; conversation text is only
  in `response_item` `message` (roles `developer`, `user`, `assistant`). Injected context arrives as user
  messages wrapped in tags (`<environment_context>`, `<external_codex_apps_open_page>`).
- Codex code-mode tool calls are `custom_tool_call` `name:"exec"` whose `input` is JavaScript, e.g.
  `text(await tools.exec_command({cmd:"git status"}))`. The chat reader pulls the `cmd` out.

# 11. Build status

## Increment 1 (2026-10-08): observed Coordinator, no process control

Built on `main`, not released:

- `AgentHUDCore/SessionCapabilities.swift`: `ControlMode`, `SessionCapabilities`, `SessionControl` (§9.6).
  Every session is `.observed` for now; the composer is drawn from capabilities.
- `AgentHUDCore/ChatTranscript.swift`: incremental Claude/Codex transcript reader. First read is the last 8 MB,
  then only appended bytes; partial lines are held back; a rewritten file restarts; items are capped at 400;
  lines that can't produce a chat item are rejected before JSON decoding (48 MB transcript: about 115 ms for the
  first read).
- `AgentHUD/CoordinatorModel.swift`, `CoordinatorView.swift`, `CoordinatorWindow.swift`: the window. Rail
  grouped Needs you / Just finished / Working / Idle by project; chat with collapsed tool runs, the waiting
  prompt, and a report card (duration, files, test result, commands) when a turn ends; Running now with tool,
  time, context and subagents, plus Finished today. Replies are Copy & Open (the observed-session route).
- Entry points: panel Menu → Coordinator, the menu bar menu, and a configurable global shortcut (default ⌃⌥C).
  The app switches to a regular activation policy (Dock icon, ⌘Tab) while the window is open.
- Debug: `--chat <transcript>` prints the chat items; `--snapshot-coordinator <png> [project]` renders the
  window from live sessions.
- Tests: `ChatTranscriptTests` (Claude/Codex parsing, editor-context stripping, incremental reads, tail start).

## Increment 2 (2026-10-08): broker, managed sessions, Move here, pairs

Built on `main`, not released, not committed.

**Broker** (`agenthud-broker`, a third executable in the app bundle; §9.7)

- `AgentHUDCore/BrokerService.swift`: owns every managed agent process and pair. Unix socket at
  `~/.agenthud/broker.sock` (owner-only; peers checked with `getpeereid`), one JSON object per line
  (`BrokerProtocol.swift`: `BrokerRequest` in, `BrokerMessage` out, protocol version 1). A lock file allows one
  broker. Agent HUD launches it on first use with `posix_spawn` + `POSIX_SPAWN_SETSID`, so it outlives the app,
  app updates and relaunches; it exits after 10 idle minutes (nothing running, no clients). An app that finds an
  older protocol asks it to exit once idle.
- State (sessions, pairs) is saved to `~/.agenthud/broker-state.json` (0600). After a broker restart nothing is
  replayed: sessions come back as stopped (Resume continues the same conversation), and a pair that was mid-turn
  waits for you with the reason, so a turn that may already have edited files isn't run twice.
- Agents run in the login shell's environment (`AgentBinaries`): an app opened from Finder has launchd's PATH,
  which finds neither `claude` nor the tools agents run. `codex` is found on PATH, else in the newest VS Code /
  Cursor / Windsurf extension, else ChatGPT.app.
- Managed agents get `AGENTHUD_MANAGED=1`; the reporter then records their host as `coordinator`, so the panel
  shows a Coordinator chip and clicking one opens the Coordinator.

**Drivers**

- `ClaudeDriver`: one `claude -p` stream-json process per session, with the flags from §10.1. Sends, queues
  while busy (the CLI runs a message sent mid-turn as the next turn), interrupts, answers `can_use_tool`
  (allow, allow for the session via `updatedPermissions`, deny with a message), answers `AskUserQuestion`
  through `updatedInput.answers`, switches permission mode with `set_permission_mode`. Delivery is
  `forwarded` when written and `observed` on the `isReplay` echo.
- `CodexDriver` + `CodexServer`: one `codex app-server` for all threads. `thread/start|resume|fork`, `turn/start`
  (per-turn `sandboxPolicy` and `approvalPolicy` for pairs), `turn/steer` while busy, `turn/interrupt`, and the
  server requests for command and file-change approvals, permissions, `requestUserInput` and MCP elicitations.

**Coordinator**

- Capabilities drive the UI (§9.6): managed sessions get a composer (Return sends; Stop Turn; Codex steers a
  running turn, Claude queues), inline permission and question cards, a permission-mode menu (Claude) and Stop
  Session. Stopped managed sessions offer Resume and Close. Observed sessions keep Copy & Open.
- **New Session** (project or any folder, Claude or Codex, permission mode / sandbox, model, first message).
- **Move Here** for an idle Claude session in a terminal or tmux: SIGTERM, wait until the process is gone, then
  resume the same conversation under the broker. Other hosts (VS Code, desktop apps) and Codex get **Continue a
  Copy Here** (`--fork-session` / `thread/fork`): their original keeps running untouched (§9.8: no concurrent resume).
- **Pairs** (`PairEngine`, a pure state machine, plus the broker's executor): plan → review plan → (revise) →
  you approve (optional) → build → commit → tests → review diff → fix … → done. Per §9.8:
  - Worktree per pair by default (`git worktree add -b pair/<slug> ../<repo>-pair-<slug>`), base SHA recorded.
  - The builder never commits; the broker commits after each build/fix turn, and the reviewer reviews the exact
    `base..build` diff (capped at 60 KB, with the command to read the rest).
  - Verdicts must be a fenced JSON block; a verdict whose `sha` doesn't match the build is rejected; no block (or
    an invalid one) gets one reminder, then the pair waits for you. Prose is never approval.
  - Approval needs passing tests when a test command is set; two failing runs in a row stop the pair.
  - Read-only turns: Claude runs in `plan` mode and Edit/Write/MultiEdit/NotebookEdit are denied; Bash is allowed
    only for inspection commands (no redirects, `;`, `&&`, command substitution); `ExitPlanMode` is denied but its
    plan is captured. Codex review turns run with `sandboxPolicy: readOnly`, `approvalPolicy: never`. After any
    read-only turn in a worktree, changes are discarded (`git checkout -- . && git clean -fd`) and logged.
  - Stop rules: round limit, two test failures, optional path guard, agent errors or interrupts, a stopped agent.
    Pause after this turn, Resume / Try Again, Stop, Keep Going (new goal, same sessions, new base), Merge into
    your checkout (`git merge --no-ff`, refused on a dirty checkout, aborted on conflict), Remove (optionally with
    the worktree). An agent that stopped is resumed on its conversation before its next turn.
- Notifications: pair waiting on you (plan to approve, stuck) and pair finished, with a click that opens it.
  Managed sessions' own prompts already notify through the `PermissionRequest` hook.

**Verified end to end** (scratch `AGENTHUD_HOME`, scratch repos):

- Claude via the broker: reply, permission prompt answered from the app (file deleted), interrupt, stop.
- Codex via the broker: reply, sandboxed command, steer mid-turn ("STEERED").
- Two full pairs (Claude plans/builds, Codex reviews): plan captured from ExitPlanMode, plan approved with notes
  (the builder followed them), commit, test command, diff review, approval, merge.
- The app launching the broker itself, starting a session and showing its reply.
- Broker killed with SIGKILL and restarted: sessions listed as stopped; resuming Claude and Codex kept the
  conversation (each recalled earlier context).
- `swift test`: 135 tests, including `PairEngineTests` (9) and `BrokerTests` (6).

## 10.4 `codex queue` (§9.5)

Tested only on threads the tests created. `codex queue --thread <id> --message <text>` returns at once
("Queued message … for thread …") with no app-server or daemon running. The message is delivered when an
app-server next loads the thread: resuming that thread in the broker ran it as a turn immediately, and the reply
landed in the rollout. Not tested: a thread that a VS Code window currently has loaded (whether its private
app-server picks the queue up live, and whether the panel shows it). That needs a test on a real VS Code thread,
which wasn't done without asking. The Codex driver now subscribes to a resumed thread before resuming, so a
queued turn that starts on load is tracked.

## Not built, and why

- **Claude channels (§9.2)**: still a research preview; custom channels need a development flag at interactive
  launch and an org allowlist. Move Here / Continue a Copy Here cover sessions started elsewhere today.
- **Stop-hook mailbox (§9.3)**: can only deliver at a session's next natural stop, never to an idle session, and
  needs a second, synchronous Stop hook in every user's settings. Low value next to Move Here; not installed.
- **`codex queue` in the UI**: waits on the VS Code test above (§9.10 step 5 gates it on a passed host matrix).
- **UI automation adapters (§9.9)**: optional; not started.
- **Benchmarks (§9.7)**: not run. The chat reader's first read of a 48 MB transcript takes about 115 ms.

## Increment 3 (2026-10-08): replies into VS Code, UI redesign

- **Claude in VS Code / Cursor / Windsurf**: the Claude Code extension (2.1.294) registers a URI handler,
  `<scheme>://anthropic.claude-code/open?session=<uuid>&prompt=<text>`, which opens that conversation and calls the
  webview's `setInputText` with the prompt. It fills the input; it doesn't send. `EditorReply` focuses the session's
  editor window, opens the link in that editor, and with **Press Return for me** (Accessibility) posts one Return to
  the editor's pid only while it's frontmost. Delivery is marked only when the transcript shows the user message.
  The Codex extension's URI handler only routes its webview (no prompt parameter); Codex in VS Code stays
  copy-and-open until `codex queue` is tested against a live VS Code thread (§10.4).
- **Redesign** from the picks in https://claude.ai/artifact/M9tYpYbv579EX6ZYxcL3zk: three panes in a full-height
  window (transparent title bar); a native sidebar `List` with projects as disclosure folders (auto-open when
  something waits on you) and a filter; chat bubbles with agent avatars and tool runs folded to one summary line
  ("Read 3 files, ran 2 commands"); a composer box with a chip row (where it goes, permission mode, model, @ file,
  Press Return for me, more) whose send button becomes Stop (⌘.) while a managed session works; the waiting prompt
  pinned above the composer (⌘Y / ⌥⌘Y / ⌘N); an Approvals sheet (⇧⌘A) across sessions and pairs with context and
  J/K; the pair thread restyled to match.
