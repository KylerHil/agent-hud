#!/usr/bin/env python3
"""Observe a real broker session. No fake editor registration or simulated completion."""
import argparse
import json
import pathlib
import socket
import time
import uuid

p = argparse.ArgumentParser()
p.add_argument('--home', default=str(pathlib.Path.home() / '.agenthud'))
p.add_argument('--workspace', default=str(pathlib.Path.cwd()))
p.add_argument('--start', choices=['claude', 'codex'])
p.add_argument('--prompt')
p.add_argument('--action', choices=['reveal', 'review', 'result'])
p.add_argument('--session')
p.add_argument('--stop', action='store_true')
p.add_argument('--answer')
p.add_argument('--send')
a = p.parse_args()
s = socket.socket(socket.AF_UNIX)
s.settimeout(20)
s.connect(str(pathlib.Path(a.home) / 'broker.sock'))
f = s.makefile('rb')

def send(op, **fields):
    rid = str(uuid.uuid4())
    s.sendall((json.dumps(dict(id=rid, op=op, **fields)) + '\n').encode())
    return rid

def read():
    line = f.readline()
    if not line:
        raise RuntimeError('Broker disconnected')
    return json.loads(line)

selected = None
rid = send('hello', version=2)
while True:
    m = read()
    if m['kind'] == 'snapshot':
        selected = next((x for x in m.get('sessions', []) if x['id'] == a.session), None)
        editors = [e for e in m.get('editors', []) if e['connected'] and a.workspace in e['folders']]
        print(json.dumps({'protocol': m['version'], 'workspace_bridges': editors, 'sessions': [{'id': x['id'], 'agent': x['agent'], 'cwd': x['cwd'], 'status': x['status'], 'turns': x['turns'], 'lastTurnStatus': x.get('lastTurnStatus'), 'reply': x.get('lastReply'), 'error': x.get('error')} for x in m.get('sessions', []) if x['cwd'] == a.workspace]}, indent=2), flush=True)
    if m.get('replyTo') == rid:
        break
if a.action:
    rid = send('editorAction', action=a.action, text=a.workspace, session=a.session)
elif a.answer:
    if not selected or not selected.get('pending'):
        p.error('Select a session with a pending question')
    pending = selected['pending'][0]
    rid = send('answer', session=a.session, requestId=pending['id'], decision='allow', answers={q['id']: [a.answer] for q in pending.get('questions', [])})
elif a.send:
    rid = send('send', session=a.session, text=a.send, steer=False)
elif a.stop:
    rid = send('stop', session=a.session)
elif a.start:
    if not a.prompt:
        p.error('--start requires --prompt')
    rid = send('start', start=dict(agent=a.start, cwd=a.workspace, prompt=a.prompt, fork=False, permissionMode='read-only' if a.start == 'codex' else 'default', title='Workspace bridge smoke validation'))
else:
    s.close()
    raise SystemExit(0)
key = a.session
until = time.monotonic() + 180
while time.monotonic() < until:
    m = read()
    if m.get('replyTo') == rid:
        print(json.dumps(m), flush=True)
        if not m.get('ok'):
            raise SystemExit(1)
        key = m.get('key') or key
        if not (a.start or a.answer or a.send):
            break
    session = m.get('session')
    if session and session['id'] == key:
        print(json.dumps({k: session.get(k) for k in ['id','agent','cwd','status','turns','lastTurnStatus','lastReply','pending','error','currentDetail']}, indent=2), flush=True)
        if session.get('pending') or session['status'] in ['failed','exited'] or session.get('turns',0) > (selected.get('turns', 0) if selected else 0):
            break
s.close()
