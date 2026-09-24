#!/bin/bash
# Simulate several Claude/Codex sessions moving through every state, by piping fake hook
# payloads through the real reporter. No agents required.
#
#   scripts/fake-events.sh            # one run (~40s)
#   scripts/fake-events.sh --loop     # repeat until Ctrl-C
#   scripts/fake-events.sh --fast     # compress the timeline 5x
#   scripts/fake-events.sh --clear    # just end every fake session
#
# Honors AGENTWATCH_HOME like the app and reporter do.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPORTER="${REPORTER:-}"
for c in "$REPORTER" "$ROOT/.build/release/agentwatch-report" "$ROOT/.build/debug/agentwatch-report" "$HOME/.agentwatch/bin/agentwatch-report"; do
  [ -n "$c" ] && [ -x "$c" ] && REPORTER="$c" && break
done
[ -x "${REPORTER:-}" ] || { echo "agentwatch-report not built; run 'make build' first" >&2; exit 1; }

SPEED=1; LOOP=0; CLEAR=0
for a in "$@"; do
  case "$a" in
    --loop) LOOP=1 ;;
    --fast) SPEED=5 ;;
    --clear) CLEAR=1 ;;
    *) echo "unknown option $a" >&2; exit 64 ;;
  esac
done

FAKE_DIR="${TMPDIR:-/tmp}"; FAKE_DIR="${FAKE_DIR%/}/agentwatch-fake"
PROJECTS=(web-app api-server mobile-app infra docs-site)
for p in "${PROJECTS[@]}"; do mkdir -p "$FAKE_DIR/$p"; done

pause() { sleep "$(echo "scale=2; $1 / $SPEED" | bc)"; }

# ev <agent> <event> <session> <project> [extra json fields without braces]
ev() {
  local agent=$1 event=$2 sid=$3 proj=$4 extra=${5:-}
  local json="{\"hook_event_name\":\"$event\",\"session_id\":\"$sid\",\"cwd\":\"$FAKE_DIR/$proj\"${extra:+,$extra}}"
  printf '%s' "$json" | "$REPORTER" --agent "$agent" --no-pid --origin fake
  echo "  $agent $sid $event ${extra:0:60}"
}

clear_all() {
  ev claude SessionEnd fake-web web-app '"reason":"other"'
  ev claude SessionEnd fake-api api-server '"reason":"other"'
  ev codex SessionEnd fake-mobile mobile-app '"reason":"other"'
  ev codex SessionEnd fake-infra infra '"reason":"other"'
  ev claude SessionEnd fake-docs docs-site '"reason":"other"'
}

if [ "$CLEAR" = 1 ]; then clear_all; exit 0; fi

run_once() {
  echo "== sessions start"
  ev claude SessionStart fake-web web-app '"source":"startup"'
  ev claude SessionStart fake-api api-server '"source":"startup"'
  ev codex SessionStart fake-mobile mobile-app '"source":"startup"'
  ev codex SessionStart fake-infra infra '"source":"startup"'
  ev claude SessionStart fake-docs docs-site '"source":"startup"'
  pause 2

  echo "== everyone gets a prompt"
  ev claude UserPromptSubmit fake-web web-app '"user_input":"Fix the login redirect bug"'
  ev claude UserPromptSubmit fake-api api-server '"user_input":"Add pagination to /orders"'
  ev codex UserPromptSubmit fake-mobile mobile-app '"prompt":"Upgrade React Native"'
  ev codex UserPromptSubmit fake-infra infra '"prompt":"Rotate the staging certs"'
  ev claude UserPromptSubmit fake-docs docs-site '"user_input":"Fix typos in README"'
  pause 2

  echo "== tool calls, subagents"
  ev claude PreToolUse fake-web web-app '"tool_name":"Read","tool_use_id":"w1","tool_input":{"file_path":"src/auth.ts"}'
  ev claude SubagentStart fake-api api-server '"agent_id":"sub-explore","agent_type":"Explore"'
  ev claude SubagentStart fake-api api-server '"agent_id":"sub-plan","agent_type":"Plan"'
  ev claude PreToolUse fake-api api-server '"agent_id":"sub-explore","agent_type":"Explore","tool_name":"Grep","tool_use_id":"a1","tool_input":{"pattern":"paginate"}'
  ev codex PreToolUse fake-mobile mobile-app '"tool_name":"Bash","tool_use_id":"m1","tool_input":{"command":"npm outdated"}'
  ev codex PreToolUse fake-infra infra '"tool_name":"Bash","tool_use_id":"i1","tool_input":{"command":"kubectl get secrets"}'
  pause 3

  echo "== web-app and infra need input"
  ev claude PostToolUse fake-web web-app '"tool_name":"Read","tool_use_id":"w1"'
  ev claude PermissionRequest fake-web web-app '"tool_name":"Bash","tool_use_id":"w2","tool_input":{"command":"rm -rf node_modules && npm ci"}'
  ev claude Notification fake-web web-app '"notification_type":"permission_prompt","notification_text":"Claude needs your permission to use Bash"'
  ev codex PermissionRequest fake-infra infra '"tool_name":"Bash","tool_use_id":"i2","tool_input":{"command":"kubectl apply -f certs.yaml"}'
  ev claude Stop fake-docs docs-site '"last_assistant_message":"Fixed 4 typos in README.md."'
  pause 6

  echo "== api-server subagents finish; mobile finishes"
  ev claude SubagentStop fake-api api-server '"agent_id":"sub-explore","agent_type":"Explore"'
  ev codex Stop fake-mobile mobile-app '"last_assistant_message":"Upgraded to 0.80; 2 warnings remain."'
  pause 4
  ev claude SubagentStop fake-api api-server '"agent_id":"sub-plan","agent_type":"Plan"'
  ev claude PreToolUse fake-api api-server '"tool_name":"Edit","tool_use_id":"a2","tool_input":{"file_path":"routes/orders.ts"}'
  pause 4

  echo "== infra approved, docs session exits"
  ev codex PostToolUse fake-infra infra '"tool_name":"Bash","tool_use_id":"i2"'
  ev claude SessionEnd fake-docs docs-site '"reason":"prompt_input_exit"'
  pause 6

  echo "== api-server asks a question; infra done; web-app approved"
  ev claude PreToolUse fake-api api-server '"tool_name":"AskUserQuestion","tool_use_id":"a3","tool_input":{"questions":[{"question":"Cursor or offset pagination?"}]}'
  ev codex Stop fake-infra infra '"last_assistant_message":"Certs rotated."'
  ev claude PostToolUse fake-web web-app '"tool_name":"Bash","tool_use_id":"w2"'
  pause 8

  echo "== wrap up"
  ev claude PostToolUse fake-api api-server '"tool_name":"AskUserQuestion","tool_use_id":"a3"'
  ev claude Stop fake-web web-app '"last_assistant_message":"Login redirect fixed; tests pass."'
  pause 4
  ev claude Stop fake-api api-server '"last_assistant_message":"Cursor pagination added."'
}

if [ "$LOOP" = 1 ]; then
  trap 'echo; clear_all; exit 0' INT
  while true; do run_once; pause 10; done
else
  run_once
fi
