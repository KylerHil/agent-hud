# Quick answers

Quick answers gathers questions from local Claude Code and Codex coding transcripts and associated Markdown plans. You can draft answers in Agent HUD, copy a single numbered reply, and open the associated agent to paste and send it.

## Using it

Open **Menu → Quick Answers**, the question-count button in the panel header, or a session’s **Quick Answers…** context-menu item. Select a source, fill in the answers, and choose **Copy & open agent**. For editors, this opens the project window; choose the conversation identified in the question header before pasting. The reply includes the question wording and original numbering, so answering only question 3 cannot accidentally become an answer to question 1.

- **Add plan…** attaches a Markdown file to the chosen session and remembers that association across restarts. Automatic discovery only follows associated local Markdown paths; it does not crawl your repository.
- An **Open questions** or **Decisions needed** heading with numbered questions produces clearer results than free-form prose. Detection is heuristic; inspect the wording and source.
- Option buttons fill a draft; you can edit it or enter multiple choices in the answer field.
- **Preview assembled reply** shows exactly what will be copied.
- Copying doesn't send. A chat question goes stale by itself at your next prompt; for a plan, choose **Mark handled after sending**. **Show handled** lets you reopen plans.
- The header count includes only structured questions: under a questions heading, numbered, or with options. An offhand question at the end of a reply ("What should I work on next?") is still listed, but doesn't add to the count.
- Scans run when a turn ends, when you open Quick Answers, and once a minute for plans edited outside a turn. Working sessions aren't rescanned.
- Drafts and handled status live in `~/.agenthud/quick-answer-drafts.json` (or `AGENTHUD_HOME`), with owner-only permissions. The newest 200 source records are retained. Plans and transcripts are never rewritten.
- If a plan changes or a new user turn supersedes a chat question, the old draft stays visible but copying is blocked until you select a current source. A changed source has a new identity.
- Native interactive questions (Claude's AskUserQuestion, Codex's request_user_input) are shown for reference with **Open agent to answer**: a pasted chat message wouldn't resolve their tool request, so there's nothing to copy.

Supported sources are coding sessions with local transcripts: Claude Code/Codex in terminals, editors, and supported coding desktop surfaces. Ordinary Claude/ChatGPT conversations observed only through Accessibility do not expose message bodies to this implementation.

## Suggested question format

You can give either agent this instruction; Agent HUD does not change your CLAUDE.md or AGENTS.md automatically:

> Put unresolved decisions under `## Open questions`. Number each question and put its options on indented `a)`, `b)`, `c)` lines. Preserve the numbers when referring back to them. Move resolved questions out of that section or add an `Answer:` line.

Reads are bounded: Markdown files up to 512 KB, the last 4 MB of a coding transcript, and up to 32 questions per source. Older content outside the tail or unsupported formatting may be missed; manually attach the plan or inspect the original source when necessary.

## Feasibility and delivery boundary

Research checked on 2026-09-25. Detection can be implemented locally for both providers; JSONL transcript formats are implementation details and may change, so unknown records are ignored and parser fixtures cover the supported shapes.

Codex’s [app-server protocol](https://learn.chatgpt.com/docs/app-server) accepts new turns, steering, and replies to pending user-input requests through its connected client. This does not establish universal access to an arbitrary independently launched CLI or IDE session.

Claude’s [user-input integration](https://code.claude.com/docs/en/agent-sdk/user-input) lets an SDK client collect and return answers for `AskUserQuestion`. Its [Channels interface](https://code.claude.com/docs/en/channels) offers a separately configured connection for pushing messages into opted-in sessions.

Both providers also document continuation through configured Stop hooks: [Claude hooks](https://code.claude.com/docs/en/hooks#stop-decision-control), [Codex hooks](https://learn.chatgpt.com/docs/hooks#stop). A future direct-delivery mode would need bounded waiting, version checks, stale-request validation, and duplicate/loop protection.

The installed VS Code-bundled Codex also exposes `codex queue --thread <THREAD> --message <TEXT>` in its CLI help. This is a concrete candidate for direct delivery to an existing session, but whether the extension consumes it, when it is delivered, and how receipt is confirmed have not been tested. It is not evidence that an outstanding native question can be resolved that way. No test prompts were sent into live sessions.

The documented direct transports require an explicit connection or configured hook; the locally available queue route needs end-to-end validation. Copy-and-focus is the supported common workflow in this version, as selected for this build. It does not resume the same session in a second process, inject keystrokes, install new hooks, or approve commands.
