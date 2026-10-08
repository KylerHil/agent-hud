'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const fs = require('node:fs');
const { BrokerClient, socketPath } = require('./client');

test('partial frames and independent replies are handled without replay', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'hud-client-'));
  const file = path.join(dir, 'test.sock');
  let peer, delivered = 0;
  const server = net.createServer(socket => {
    peer = socket;
    socket.on('data', chunk => {
      const r = JSON.parse(chunk.toString().trim()); delivered++;
      const response = JSON.stringify({ kind: 'reply', replyTo: r.id, ok: true }) + '\n';
      socket.write(response.slice(0, 9)); setImmediate(() => socket.write(response.slice(9)));
    });
  });
  await new Promise(resolve => server.listen(file, resolve));
  let client;
  try {
    await new Promise(resolve => { client = new BrokerClient(file, () => {}, up => { if (up) resolve(); }); client.connect(); });
    const result = await client.request('hello'); assert.equal(result.ok, true);
    peer.destroy(); await new Promise(resolve => setImmediate(resolve));
    client.close(); assert.equal(delivered, 1);
  } finally { client?.close(); await new Promise(resolve => server.close(resolve)); fs.rmSync(dir, { recursive: true }); }
});

test('socket path fallback is bounded and stable', () => {
  assert.equal(socketPath('/tmp/hud', 501), '/tmp/hud/broker.sock');
  const long = '/tmp/' + 'workspace'.repeat(40);
  assert.equal(socketPath(long, 501), socketPath(long, 501));
  assert.ok(Buffer.byteLength(socketPath(long, 501)) < 100);
});
