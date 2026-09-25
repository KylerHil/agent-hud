// agenthud-report: called by Claude Code / Codex hooks.
//
// Reads the hook JSON from stdin, reduces it to an AgentEvent and appends one line to
// ~/.agenthud/events.jsonl. It must never disturb the agent: it prints nothing to stdout,
// always exits 0, and kills itself after a hard deadline.
//
//   agenthud-report --agent claude|codex [--event Name] [--no-pid]
//   agenthud-report install-hooks|uninstall-hooks|hooks-status [...]   (see Installer)

import AgentHUDCore
import Darwin
import Foundation

let args = Array(CommandLine.arguments.dropFirst())

if let command = args.first, !command.hasPrefix("-") {
    exit(InstallerCLI.run(command: command, args: Array(args.dropFirst())))
}

// Hard deadline: whatever happens, we are gone in 2s with status 0.
signal(SIGALRM) { _ in _exit(0) }
signal(SIGPIPE, SIG_IGN)
alarm(2)

func flag(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let agent = flag("--agent").flatMap(AgentKind.init(rawValue:)) ?? .claude
var payload: [String: Any] = [:]
if isatty(STDIN_FILENO) == 0 {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { payload = obj }
}

var event = HookPayload.makeEvent(payload: payload, agent: agent, eventOverride: flag("--event"))
if let origin = flag("--origin") { event.origin = origin }
if !args.contains("--no-pid") {
    let anc = ProcTools.ancestry(from: getppid(), agent: agent, env: ProcessInfo.processInfo.environment)
    event.pid = anc.agentPid
    event.tty = anc.tty.map { "/dev/" + $0 }
    event.hostApp = anc.hostApp
    event.hostKind = anc.hostKind
}
EventLog.append(event)
exit(0)
