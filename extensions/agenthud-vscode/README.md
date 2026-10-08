# Agent HUD Workspace Bridge

Local macOS companion to Agent HUD. Every window registers its actual workspace folders with a persistent local broker. Empty, multi-root, trusted and remote windows are reported distinctly. Remote execution is currently unavailable.

The Explorer's **Agent HUD Tasks** view shows tasks for this workspace. Use **Agent HUD: Assign Work** to choose Claude or Codex and enter a task. Click a task to read its current result and choose a next action: answer a question or permission, follow up, interrupt, resume, or review changes in Source Control.

Agents run under the broker, survive editor/app reloads, and use your existing CLI authentication. This workspace extension controls broker-owned tasks. The desktop coordinator separately delivers replies to existing Codex chats through Codex's versioned local thread-owner protocol. It does not take ownership or create another thread. Unsupported sessions remain observable; continue a copy there when you need broker control.

Install the VSIX from `make vscode-package` using **Extensions: Install from VSIX** or `code --install-extension build/agenthud-workspace-bridge.vsix`. Existing windows may need **Developer: Reload Window** once. The broker is bundled; `agenthud.brokerPath` optionally overrides it. `agenthud.home` must match the desktop app's state directory if overridden. Settings are machine scoped and cannot be supplied by untrusted repositories.

The bridge uses an owner-only Unix socket, small periodic heartbeats, event-driven updates and bounded messages. It exposes only task/result/Source Control actions; it does not inject keys, start terminals, or expose arbitrary command execution through editor IPC. On a lost connection it does not replay requests. Review the task's last confirmed state before retrying uncertain delivery.
