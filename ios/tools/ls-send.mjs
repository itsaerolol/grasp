#!/usr/bin/env node
// Reference LocalSend v2.2 sender. Mirrors the Swift SendEngine flow exactly, so you can prove the
// protocol against the REAL LocalSend on your PC before touching Xcode:
//   node tools/ls-send.mjs --host 192.168.1.20 photo.jpg doc.pdf
//   node tools/ls-send.mjs --host 192.168.1.20 --text "hello"
//   node tools/ls-send.mjs --host 192.168.1.20 --info            (print PC identity + cert fingerprint)
//   node tools/ls-send.mjs --host 192.168.1.20 --pair 427        (Grasp for Windows: pair with the code it shows)
// Options: --pin-fp <FP> (fail if server cert differs)  --pin <PIN>  --no-client-cert (prove mTLS is required)
import https from 'node:https';
import { createHash, randomUUID } from 'node:crypto';
import { createReadStream, statSync } from 'node:fs';
import { basename, dirname, extname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { API, GRASP_API, PORT, VERSION, ensureCert, fingerprintOfDer } from './lib.mjs';

const args = process.argv.slice(2);
const opt = (n, d) => (args.includes(n) ? args[args.indexOf(n) + 1] : d);
const flag = (n) => args.includes(n);
const host = opt('--host', '127.0.0.1');
const port = Number(opt('--port', PORT));
const pinnedFp = opt('--pin-fp', null)?.toUpperCase();
const pin = opt('--pin', null);
const text = opt('--text', null);
const pairCode = opt('--pair', null);
const valueFlags = new Set(['--host', '--port', '--pin-fp', '--pin', '--text', '--pair']);
const files = args.filter((a, i) => !a.startsWith('--') && !valueFlags.has(args[i - 1]));

const here = dirname(fileURLToPath(import.meta.url));
const me = ensureCert(join(here, '.client-cert'), 'Grasp');
const myInfo = { alias: 'Grasp CLI', version: VERSION, deviceModel: 'iPhone', deviceType: 'mobile',
  fingerprint: me.fingerprint, port: PORT, protocol: 'https', download: false };

const MIME = { '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png', '.heic': 'image/heic',
  '.pdf': 'application/pdf', '.txt': 'text/plain', '.mov': 'video/quicktime', '.mp4': 'video/mp4', '.zip': 'application/zip' };

let serverFp = null;
const agent = new https.Agent({
  keepAlive: true, rejectUnauthorized: false,
  ...(flag('--no-client-cert') ? {} : { key: me.key, cert: me.cert }),
});

// Pin check runs on the TLS handshake, before any request bytes are written
// (checkServerIdentity is skipped by Node when rejectUnauthorized is false).
function verifyPeer(socket, req) {
  const check = () => {
    const raw = socket.getPeerCertificate()?.raw;
    if (!raw) return;
    serverFp = fingerprintOfDer(raw);
    if (pinnedFp && serverFp !== pinnedFp) req.destroy(new Error(`server fingerprint ${serverFp} != pinned ${pinnedFp}`));
  };
  socket.getPeerCertificate?.()?.raw ? check() : socket.once('secureConnect', check);
}

function request(method, path, { query = {}, json, bodyStream, timeout = 10_000, length, base = API } = {}) {
  const qs = new URLSearchParams(query).toString();
  return new Promise((resolve, reject) => {
    const req = https.request({ host, port, method, agent, path: base + path + (qs ? `?${qs}` : ''), timeout,
      headers: json ? { 'content-type': 'application/json' }
        : bodyStream ? { 'content-type': 'application/octet-stream', 'content-length': length } : {} },
    (res) => {
      const chunks = []; res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        const raw = Buffer.concat(chunks).toString();
        resolve({ status: res.statusCode, body: raw ? (() => { try { return JSON.parse(raw); } catch { return raw; } })() : null });
      });
    });
    req.on('socket', (s) => verifyPeer(s, req));
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', reject);
    if (json) req.end(JSON.stringify(json));
    else if (bodyStream) bodyStream.pipe(req);
    else req.end();
  });
}

const sha256File = (p) => new Promise((res, rej) => {
  const h = createHash('sha256'); createReadStream(p).on('data', (c) => h.update(c)).on('end', () => res(h.digest('hex'))).on('error', rej);
});

const PAIR_ERR = { 400: 'Client certificate required', 401: 'Wrong code', 409: 'Pairing is not open on the PC', 429: 'Too many wrong codes' };
const ERR = { 401: 'PIN required / invalid', 403: 'Rejected (or invalid token/IP)', 409: 'Busy: another session', 422: 'Checksum mismatch', 429: 'Too many requests' };

async function main() {
  const reg = await request('POST', '/register', { json: myInfo });
  console.log(`PC: ${reg.body?.alias} (${reg.body?.deviceModel}) protocol ${reg.body?.version}`);
  console.log(`PC cert fingerprint: ${serverFp}`);
  console.log(`my client fingerprint: ${me.fingerprint}`);
  console.log(`code pairing: ${reg.body?.grasp ? 'supported (Grasp for Windows)' : 'not supported'}`);
  if (flag('--info')) return;

  if (pairCode != null) {
    const r = await request('POST', '/pair', { base: GRASP_API, json: { code: pairCode, info: myInfo } });
    if (r.status !== 200) throw new Error(`pair ${r.status}: ${PAIR_ERR[r.status] ?? JSON.stringify(r.body)}${r.body?.attemptsLeft != null ? ` (${r.body.attemptsLeft} left)` : ''}`);
    return console.log(`paired with ${r.body.alias} ✓`);
  }

  let dtos, refs = [];
  if (text != null) {
    dtos = [{ id: randomUUID(), fileName: `${randomUUID()}.txt`, size: Buffer.byteLength(text), fileType: 'text/plain', preview: text }];
  } else {
    if (!files.length) throw new Error('pass files or --text');
    dtos = [];
    for (const p of files) {
      const id = randomUUID(), size = statSync(p).size;
      dtos.push({ id, fileName: basename(p), size, fileType: MIME[extname(p).toLowerCase()] ?? 'application/octet-stream', sha256: await sha256File(p) });
      refs.push({ id, path: p, size });
    }
  }

  console.log('prepare-upload: waiting for accept on the PC…');
  const prep = await request('POST', '/prepare-upload', {
    query: pin ? { pin } : {}, timeout: 600_000,
    json: { info: myInfo, files: Object.fromEntries(dtos.map((d) => [d.id, d])) } });
  if (prep.status === 204) return console.log('accepted (204, nothing to upload) ✓');
  if (prep.status !== 200) throw new Error(`prepare-upload ${prep.status}: ${ERR[prep.status] ?? JSON.stringify(prep.body)}`);

  const { sessionId, files: tokens } = prep.body;
  for (const r of refs.filter((r) => tokens[r.id])) {
    const up = await request('POST', '/upload', { query: { sessionId, fileId: r.id, token: tokens[r.id] },
      bodyStream: createReadStream(r.path), length: r.size, timeout: 120_000 });
    if (up.status !== 200) throw new Error(`upload ${basename(r.path)} ${up.status}: ${ERR[up.status] ?? up.body}`);
    console.log(`uploaded ${basename(r.path)} (${r.size}B) ✓`);
  }
  console.log('done ✓');
}

main().catch((e) => { console.error('FAILED:', e.message); process.exit(1); }).finally(() => agent.destroy());
