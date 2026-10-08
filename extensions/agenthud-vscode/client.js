'use strict';
const net = require('node:net');
const { randomUUID } = require('node:crypto');
const path = require('node:path');

// Bounded framing, explicit acknowledgments and no automatic replay after connection loss.
class BrokerClient {
  constructor(socketPath, onMessage, onState) {
    this.path = socketPath; this.onMessage = onMessage; this.onState = onState;
    this.pending = new Map(); this.socket = undefined;
  }
  connect() {
    if (this.socket) return;
    const socket = net.createConnection(this.path); this.socket = socket;
    let buffer = '';
    socket.setEncoding('utf8');
    socket.on('connect', () => this.onState(true));
    socket.on('data', data => {
      buffer += data;
      if (Buffer.byteLength(buffer) > 4 * 1024 * 1024) { socket.destroy(new Error('Broker message exceeded 4 MB')); return; }
      let newline;
      while ((newline = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, newline); buffer = buffer.slice(newline + 1);
        try {
          const msg = JSON.parse(line);
          if (msg.kind === 'reply' && this.pending.has(msg.replyTo)) {
            const pending = this.pending.get(msg.replyTo); this.pending.delete(msg.replyTo); clearTimeout(pending.timer);
            if (msg.ok) pending.resolve(msg); else pending.reject(new Error(msg.error || 'Broker rejected the request'));
          } else this.onMessage(msg);
        } catch (err) { this.onState(true, `Invalid broker message: ${err.message}`); }
      }
    });
    socket.on('error', err => { this.lastError = err.message; });
    socket.on('close', () => {
      if (this.socket !== socket) return;
      this.socket = undefined;
      for (const p of this.pending.values()) { clearTimeout(p.timer); p.reject(new Error('Broker disconnected; delivery is uncertain. Review task state before retrying.')); }
      this.pending.clear(); this.onState(false, this.lastError); this.lastError = undefined;
    });
  }
  request(op, fields = {}) {
    const id = randomUUID();
    return new Promise((resolve, reject) => {
      if (!this.socket || this.socket.connecting || this.socket.destroyed) { reject(new Error('Broker disconnected. Use Agent HUD: Reconnect Workspace Bridge.')); return; }
      const timer = setTimeout(() => { this.pending.delete(id); reject(new Error('Broker did not acknowledge the request. Review task state before retrying.')); }, 15000);
      this.pending.set(id, { resolve, reject, timer });
      this.socket.write(JSON.stringify({ id, op, ...fields }) + '\n');
    });
  }
  close() { this.socket?.destroy(); }
}
function socketPath(home, uid = process.getuid()) {
  const p = path.join(home, 'broker.sock');
  if (Buffer.byteLength(p) < 100) return p;
  let hash = 0xcbf29ce484222325n;
  for (const byte of Buffer.from(p)) hash = BigInt.asUintN(64, (hash ^ BigInt(byte)) * 0x100000001b3n);
  hash = BigInt.asIntN(64, hash);
  return `/tmp/agenthud-${uid}-${(hash < 0n ? -hash : hash) % 1000000n}.sock`;
}
module.exports = { BrokerClient, socketPath };
