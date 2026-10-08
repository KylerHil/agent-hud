#!/usr/bin/env python3
"""Isolated real-process broker lifecycle tests. No model calls or real editor automation."""
import json
import os
import pathlib
import socket
import subprocess
import tempfile
import time
import unittest
import uuid

BINARY = pathlib.Path(__file__).resolve().parents[1] / '.build/debug/agenthud-broker'

class Wire:
    def __init__(self, home):
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.settimeout(5)
        self.socket.connect(str(home / 'broker.sock'))
        self.file = self.socket.makefile('rb')
    def request(self, op, **fields):
        rid = str(uuid.uuid4())
        self.socket.sendall((json.dumps(dict(id=rid, op=op, **fields)) + '\n').encode())
        messages = []
        while True:
            msg = json.loads(self.file.readline())
            messages.append(msg)
            if msg.get('replyTo') == rid:
                return messages
    def snapshot(self):
        return next(m for m in self.request('hello', version=2) if m['kind'] == 'snapshot')
    def close(self):
        self.file.close()
        self.socket.close()

class BrokerLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='hud-broker-', dir='/tmp')
        self.home = pathlib.Path(self.temp.name)
        caps = dict(observe=True, sendNextTurn=True, sendAtCompletion=False, steerActiveTurn=False,
                    interruptTurn=True, answerPermission=True, answerQuestion=True, reconnect=True)
        session = dict(id='recover', agent='claude', cwd=str(self.home), sessionId='conversation', status='busy',
                       pending=[dict(id='q', kind='question', tool='AskUserQuestion', summary='Which label?', questions=[], since=100)],
                       outbox=[dict(id='message', text='preserve this task', state='forwarded', at=100, steer=False)],
                       capabilities=caps, startedAt=100, lastActivity=101, turns=0)
        (self.home / 'broker-state.json').write_text(json.dumps(dict(sessions=[session], pairs=[])))
        self.process = subprocess.Popen([str(BINARY)], env={**os.environ, 'AGENTHUD_HOME': str(self.home)},
                                        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        until = time.monotonic() + 5
        while not (self.home / 'broker.sock').exists() and time.monotonic() < until:
            if self.process.poll() is not None:
                self.fail('Broker exited on startup')
            time.sleep(0.02)
        self.wire = Wire(self.home)
    def tearDown(self):
        self.wire.close()
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        self.temp.cleanup()
    def test_restart_preserves_task_and_marks_uncertain_delivery(self):
        session = self.wire.snapshot()['sessions'][0]
        self.assertEqual(session['sessionId'], 'conversation')
        self.assertEqual(session['status'], 'exited')
        self.assertEqual(session['pending'], [])
        self.assertEqual(session['outbox'][0]['text'], 'preserve this task')
        self.assertEqual(session['outbox'][0]['state'], 'failed')
        self.assertIn('Which label?', session['error'])
        self.assertIn('before delivery was confirmed', session['outbox'][0]['error'])
    def test_workspace_reconnect_deduplicates_and_close_updates_evidence(self):
        editor = Wire(self.home)
        identity = dict(id='real-process-test', name='test', folders=[str(self.home)], trusted=True,
                        focused=True, connected=True, lastSeen=time.time())
        editor.request('editorHello', editor=identity)
        editor.request('editorHeartbeat', editor=identity)
        snapshot = self.wire.snapshot()
        self.assertEqual(len(snapshot['editors']), 1)
        self.assertTrue(snapshot['editors'][0]['connected'])
        editor.close()
        until = time.monotonic() + 3
        while self.wire.snapshot()['editors'][0]['connected'] and time.monotonic() < until:
            time.sleep(0.02)
        self.assertFalse(self.wire.snapshot()['editors'][0]['connected'])
        again = Wire(self.home)
        again.request('editorHello', editor=identity)
        self.assertEqual(len(self.wire.snapshot()['editors']), 1)
        self.assertTrue(self.wire.snapshot()['editors'][0]['connected'])
        again.close()
    def test_missing_prompt_and_editor_actions_fail_usefully(self):
        reply = self.wire.request('answer', session='recover', requestId='gone', decision='allow')[-1]
        self.assertFalse(reply['ok'])
        self.assertIn('no longer pending', reply['error'])
        reply = self.wire.request('editorAction', action='review', text=str(self.home))[-1]
        self.assertFalse(reply['ok'])
        self.assertIn('No connected VS Code bridge', reply['error'])

if __name__ == '__main__':
    unittest.main()
