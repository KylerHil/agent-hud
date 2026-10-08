'use strict';
const vscode = require('vscode');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawn } = require('node:child_process');
const { randomUUID } = require('node:crypto');
const { BrokerClient, socketPath } = require('./client');

function contains(root, file) { return file === root || file.startsWith(root.endsWith(path.sep) ? root : root + path.sep); }
function canonical(p) { try { return fs.realpathSync(p); } catch { return path.resolve(p); } }
function status(s, connected) {
  if (!connected) return 'Disconnected';
  if (s.pending?.length && !['exited', 'failed'].includes(s.status)) return 'Waiting on you';
  if (s.status === 'idle') return s.error ? 'Failed' : s.lastTurnStatus === 'completed' ? 'Completed' : 'Idle';
  return { starting: 'Starting', busy: 'Running', waiting: 'Waiting on you', exited: 'Stopped', failed: 'Failed' }[s.status] || 'Unknown';
}

function activate(context) {
  const log = vscode.window.createOutputChannel('Agent HUD Bridge');
  const stateDir = vscode.workspace.getConfiguration('agenthud').get('home') || process.env.AGENTHUD_HOME || path.join(os.homedir(), '.agenthud');
  const editorID = randomUUID(); // One identity per actual extension host; reconnect keeps it, reload registers a new host.
  let connected = false, stopped = false, retry, heartbeat, launching = false, incompatible = false, lastLaunch = 0;
  const sessions = new Map();
  const change = new vscode.EventEmitter();
  const bar = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 20);
  bar.command = 'agenthud.assign'; bar.show();
  function folders() { return (vscode.workspace.workspaceFolders || []).filter(f => f.uri.scheme === 'file').map(f => canonical(f.uri.fsPath)); }
  function workspace() {
    return { id: editorID, name: vscode.workspace.name || 'Empty window', folders: folders(),
      workspaceFile: vscode.workspace.workspaceFile?.toString(), remote: vscode.env.remoteName || undefined,
      trusted: vscode.workspace.isTrusted, focused: vscode.window.state.focused, connected: true, lastSeen: Date.now() / 1000 };
  }
  function localSessions() { return [...sessions.values()].filter(s => !vscode.env.remoteName && folders().some(f => contains(f, canonical(s.cwd)))).sort((a,b) => b.lastActivity - a.lastActivity); }
  function refresh() {
    const waiting = localSessions().filter(s => status(s, connected) === 'Waiting on you').length;
    bar.text = connected ? `$(hubot) Agent HUD${waiting ? `: ${waiting} need you` : ''}` : '$(debug-disconnect) Agent HUD';
    bar.tooltip = connected ? 'Assign work in this workspace · Agent HUD Tasks shows progress and results' : 'Bridge disconnected. Reconnect from the Command Palette.';
    bar.command = connected ? 'agenthud.assign' : 'agenthud.reconnect'; change.fire();
  }
  async function announce(op = 'editorHeartbeat') { await client.request(op, { editor: workspace() }); }
  async function handleEditor(command) {
    try {
      if (command.editorID !== editorID || vscode.env.remoteName || !folders().some(f => contains(f, canonical(command.cwd)))) throw new Error('Action does not belong to this local workspace');
      if (command.action === 'reveal') await vscode.commands.executeCommand('agenthud.tasks.focus');
      else if (command.action === 'review') await vscode.commands.executeCommand('workbench.view.scm');
      else if (command.action === 'result') {
        const doc = await vscode.workspace.openTextDocument({ content: command.text || 'No reply yet.', language: 'markdown' });
        await vscode.window.showTextDocument(doc, { preview: true });
      } else throw new Error('Unsupported editor action');
      await client.request('editorResult', { commandID: command.id, ok: true });
    } catch (error) { await client.request('editorResult', { commandID: command.id, ok: false, error: error.message }).catch(() => {}); }
  }
  const client = new BrokerClient(socketPath(stateDir), msg => {
    if (msg.kind === 'snapshot') {
      if (msg.version !== 2) {
        if (!incompatible) log.appendLine('Broker protocol mismatch. Finish running tasks and restart the broker with the updated app. The bridge will retry automatically.');
        incompatible = true; client.close(); return;
      }
      incompatible = false; connected = true;
      sessions.clear(); for (const s of msg.sessions || []) sessions.set(s.id, s);
    } else if (msg.kind === 'session') sessions.set(msg.session.id, msg.session);
    else if (msg.kind === 'removed') sessions.delete(msg.removed);
    else if (msg.kind === 'editorCommand') { void handleEditor(msg.editorCommand); return; }
    refresh();
  }, (up, error) => {
    connected = false; refresh();
    if (error) log.appendLine(error);
    if (up) {
      clearTimeout(retry); void client.request('hello', { version: 2 }).then(() => announce('editorHello')).catch(e => log.appendLine(e.message));
    } else if (!stopped) retry = setTimeout(connect, 3000);
  });
  async function connect() {
    if (stopped || client.socket) return;
    if (!launching && Date.now() - lastLaunch > 15000) {
      lastLaunch = Date.now();
      launching = true;
      const configured = vscode.workspace.getConfiguration('agenthud').get('brokerPath');
      const binary = configured || context.asAbsolutePath('bin/agenthud-broker');
      try {
        await fs.promises.access(binary, fs.constants.X_OK);
        const child = spawn(binary, [], { detached: true, stdio: 'ignore', env: { ...process.env, AGENTHUD_HOME: stateDir } });
        child.on('error', e => log.appendLine(`Could not launch broker: ${e.message}`)); child.unref();
      } catch (error) { log.appendLine(`Install/build the broker or set agenthud.brokerPath. ${error.message}`); }
      launching = false;
    }
    client.connect();
  }
  async function pick(item) {
    if (item?.session) return sessions.get(item.session.id) || item.session;
    const selected = await vscode.window.showQuickPick(localSessions().map(session => ({ label: session.title || `${session.agent} task`, description: status(session, connected), session })), { placeHolder: 'Select a task' });
    return selected?.session;
  }
  const tree = {
    onDidChangeTreeData: change.event,
    getChildren: () => localSessions().map(session => ({ session })),
    getTreeItem: item => {
      const s = item.session, label = status(s, connected);
      const t = new vscode.TreeItem(s.title || `${s.agent} task`); t.description = label;
      t.tooltip = `${s.cwd}\n${label}${s.currentDetail ? ` · ${s.currentDetail}` : ''}${s.error ? `\n${s.error}` : ''}`;
      t.iconPath = new vscode.ThemeIcon(label === 'Waiting on you' ? 'question' : label === 'Completed' ? 'pass' : label === 'Failed' ? 'error' : label === 'Running' ? 'sync~spin' : 'circle-outline');
      t.command = { command: 'agenthud.result', title: 'Review task', arguments: [item] }; return t;
    }
  };
  function command(name, fn) { context.subscriptions.push(vscode.commands.registerCommand(name, async (...args) => { try { await fn(...args); } catch (e) { log.appendLine(e.message); vscode.window.showErrorMessage(`Agent HUD: ${e.message}`); } })); }
  command('agenthud.assign', async () => {
    if (!vscode.workspace.isTrusted) throw new Error('Trust this workspace before starting agents.');
    if (vscode.env.remoteName) throw new Error('Remote execution is not supported by the local broker. Open a local workspace.');
    let root; const roots = vscode.workspace.workspaceFolders || [];
    if (roots.length === 1) root = roots[0]; else root = await vscode.window.showWorkspaceFolderPick();
    if (!root || root.uri.scheme !== 'file') return;
    const agent = await vscode.window.showQuickPick(['Codex', 'Claude'], { placeHolder: 'Agent to perform the work' }); if (!agent) return;
    const prompt = await vscode.window.showInputBox({ title: 'Assign work', prompt: `Task for ${agent} in ${root.name}`, ignoreFocusOut: true, validateInput: text => text.trim() ? undefined : 'Enter a task' }); if (!prompt) return;
    await client.request('start', { start: { agent: agent.toLowerCase(), cwd: canonical(root.uri.fsPath), prompt, fork: false, title: prompt.slice(0, 80), permissionMode: agent === 'Codex' ? 'workspace-write' : 'default' } });
    await vscode.commands.executeCommand('agenthud.tasks.focus');
  });
  command('agenthud.reply', async item => {
    const s = await pick(item); if (!s) return;
    const text = await vscode.window.showInputBox({ title: `Follow up with ${s.agent}`, ignoreFocusOut: true }); if (!text?.trim()) return;
    await client.request('send', { session: s.id, text, steer: s.agent === 'codex' && ['busy', 'waiting'].includes(s.status) });
  });
  command('agenthud.interrupt', async item => { const s = await pick(item); if (s) await client.request('interrupt', { session: s.id }); });
  command('agenthud.resume', async item => {
    const s = await pick(item); if (!s) return;
    if (!['exited', 'failed'].includes(s.status) || !s.sessionId) throw new Error('Select a stopped session with a conversation ID.');
    await client.request('start', { start: { agent: s.agent, cwd: s.cwd, resume: s.sessionId, fork: false, permissionMode: s.permissionMode, title: s.title, model: s.model } });
    await client.request('forget', { session: s.id });
  });
  command('agenthud.answer', async item => {
    const s = await pick(item); if (!s) return;
    const p = s.pending?.[0]; if (!p) throw new Error('This task has no pending prompt.');
    if (p.kind === 'question') {
      const answers = {};
      for (const q of p.questions) {
        const value = await vscode.window.showInputBox({ title: q.header || 'Agent question', prompt: `${q.question}${q.options.length ? ` (${q.options.join(' / ')})` : ''}`, ignoreFocusOut: true });
        if (value === undefined) return; answers[q.id] = [value];
      }
      await client.request('answer', { session: s.id, requestId: p.id, decision: 'allow', answers });
    } else {
      log.appendLine(`Permission: ${p.tool}\n${p.summary}\n${p.detail || ''}`); log.show(true);
      const decision = await vscode.window.showQuickPick(['Deny', 'Allow once', 'Allow for session'], { title: p.summary, placeHolder: 'Full request is in Agent HUD Bridge output' }); if (!decision) return;
      await client.request('answer', { session: s.id, requestId: p.id, decision: decision === 'Deny' ? 'deny' : decision === 'Allow once' ? 'allow' : 'allowSession' });
    }
  });
  command('agenthud.result', async item => {
    const s = await pick(item); if (!s) return;
    const content = `# ${s.title || s.agent + ' task'}\n\n${status(s, connected)} · ${s.cwd}\n\n${s.error ? `Error: ${s.error}\n\n` : ''}${s.currentDetail ? `Current activity: ${s.currentDetail}\n\n` : ''}${s.lastReply || 'No completed reply yet.'}\n\n${(s.outbox || []).filter(m => m.state !== 'observed').map(m => `${m.state}: ${m.text}${m.error ? `\n${m.error}` : ''}`).join('\n\n')}`;
    const doc = await vscode.workspace.openTextDocument({ content, language: 'markdown' }); await vscode.window.showTextDocument(doc, { preview: true });
    const actions = s.pending?.length ? ['Answer agent', 'Follow up', 'Review changes'] : ['busy','waiting'].includes(s.status) ? ['Follow up', 'Interrupt', 'Review changes'] : ['exited','failed'].includes(s.status) ? ['Resume', 'Review changes'] : ['Follow up', 'Review changes'];
    const action = await vscode.window.showQuickPick(actions, { placeHolder: 'Next action for this task (Escape to read the result)' });
    const commands = { 'Answer agent': 'agenthud.answer', 'Follow up': 'agenthud.reply', Interrupt: 'agenthud.interrupt', Resume: 'agenthud.resume', 'Review changes': 'workbench.view.scm' };
    if (action) await vscode.commands.executeCommand(commands[action], item || { session: s });
  });
  command('agenthud.reconnect', async () => { incompatible = false; clearTimeout(retry); client.close(); setTimeout(connect, 100); });
  heartbeat = setInterval(() => { if (connected) void announce().catch(e => log.appendLine(e.message)); }, 15000);
  context.subscriptions.push(log, bar, change, vscode.window.registerTreeDataProvider('agenthud.tasks', tree),
    vscode.workspace.onDidChangeWorkspaceFolders(() => { if (connected) void announce().catch(() => {}); refresh(); }),
    vscode.workspace.onDidGrantWorkspaceTrust(() => { if (connected) void announce().catch(() => {}); }),
    vscode.window.onDidChangeWindowState(() => { if (connected) void announce().catch(() => {}); }),
    { dispose: () => { stopped = true; clearInterval(heartbeat); clearTimeout(retry); client.close(); } });
  refresh(); void connect();
  return { client, workspace, localSessions }; // Also useful to integration tests via extensions.getExtension(...).exports.
}
module.exports = { activate, contains, status };
