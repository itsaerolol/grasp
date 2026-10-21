#!/usr/bin/env node
// Mock LocalSend v2.2 receiver that enforces the same rules as localsend/localsend packages/core:
//  - HTTPS, self-signed server cert, fingerprint = SHA-256(DER) uppercase
//  - client certificate MANDATORY (mTLS) unless --optional-client-cert (= LocalSend with web share on)
//  - /register: claimed fingerprint must equal presented client cert fingerprint
//  - single session slot (409), upload must come from the same IP + valid token (403), sha256 check (422)
//  - single text/plain file with preview = message -> 204 after accept, no upload
//  - with --pair-code: acts like Grasp for Windows' code pairing (POST /api/grasp/v1/pair) and outbox
//    (GET /api/grasp/v1/outbox, GET .../outbox/file?id=, POST .../outbox/done?id=; paired phones only), `grasp: 2`
// Usage: node tools/mock-receiver.mjs [--auto-accept|--reject] [--pin 1234] [--port 53317] [--inbox ./mock-inbox] [--throttle-kbps 500]
//        [--pair-code 427] [--send PATH]... (queue files/folders for the phone) [--send-text TEXT]
import https from 'node:https';
import { createHash, randomUUID } from 'node:crypto';
import { createReadStream, createWriteStream, existsSync, mkdirSync, renameSync, statSync, unlinkSync } from 'node:fs';
import { join, basename, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import readline from 'node:readline';
import { API, GRASP_API, GRASP_LEVEL, PORT, VERSION, ensureCert, fingerprintOfDer, outboxEntries } from './lib.mjs';

const args = process.argv.slice(2);
const flag = (n) => args.includes(n);
const opt = (n, d) => (args.includes(n) ? args[args.indexOf(n) + 1] : d);
const port = Number(opt('--port', PORT));
const inbox = opt('--inbox', './mock-inbox');
const pin = opt('--pin', null);
const mode = flag('--auto-accept') ? 'accept' : flag('--reject') ? 'reject' : 'ask';
const mandatoryClientCert = !flag('--optional-client-cert');
const throttleKbps = Number(opt('--throttle-kbps', 0)); // slow uploads so Cancel / memory can be exercised
// Code pairing, same rules as windows/core/src/pairing.rs: one window, 5 wrong tries closes it.
let pairing = opt('--pair-code', null) != null ? { code: opt('--pair-code'), attempts: 0 } : null;
const graspMode = pairing != null;
const paired = new Set();
mkdirSync(inbox, { recursive: true });
// Windows -> iPhone queue, same shape as windows/core/src/outbox.rs.
const values = (n) => args.flatMap((a, i) => (a === n && args[i + 1] != null ? [args[i + 1]] : []));
const outbox = [
  ...outboxEntries(values('--send')).map((e) => ({ kind: 'file', id: randomUUID(), ...e })),
  ...values('--send-text').map((text) => ({ kind: 'text', id: randomUUID(), text })),
];
const wire = ({ path, ...rest }) => rest; // never show the phone a local path

const here = dirname(fileURLToPath(import.meta.url));
const me = ensureCert(join(here, '.mock-server-cert'), 'Mock PC');
const info = { alias: 'Mock PC', version: VERSION, deviceModel: 'Windows', deviceType: 'desktop',
  fingerprint: randomUUID(), download: false, ...(graspMode ? { grasp: GRASP_LEVEL } : {}) };

let session = null; // { id, ip, files: {fileId: {dto, token, done}} }
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);

const rl = readline.createInterface({ input: process.stdin });
const ask = (q) => new Promise((res) => { process.stdout.write(q); rl.once('line', (l) => res(/^y/i.test(l.trim()))); });

const json = (res, status, body) => {
  res.writeHead(status, body ? { 'content-type': 'application/json' } : {});
  res.end(body ? JSON.stringify(body) : undefined);
};
const readJson = (req) => new Promise((res, rej) => {
  const chunks = []; req.on('data', (c) => chunks.push(c));
  req.on('end', () => { try { res(JSON.parse(Buffer.concat(chunks).toString() || '{}')); } catch (e) { rej(e); } });
});

const server = https.createServer({ key: me.key, cert: me.cert, requestCert: true, rejectUnauthorized: false },
  async (req, res) => {
    const ip = req.socket.remoteAddress;
    const peerCert = req.socket.getPeerCertificate();
    const clientFp = peerCert && peerCert.raw ? fingerprintOfDer(peerCert.raw) : null;
    if (mandatoryClientCert && !clientFp) {
      log('REJECT no client certificate from', ip, req.url);
      req.socket.destroy(); // rustls aborts the handshake; closest we can get in Node
      return;
    }
    const url = new URL(req.url, 'https://x');
    const q = Object.fromEntries(url.searchParams);
    try {
      switch (`${req.method} ${url.pathname}`) {
        case `POST ${API}/register`: {
          const body = await readJson(req);
          if (clientFp && body.fingerprint?.toUpperCase() !== clientFp) log('WARN register fingerprint != client cert, ignored');
          else log(`register from ${body.alias} ${ip} client-cert fingerprint ${clientFp ?? 'none'}`);
          return json(res, 200, info);
        }
        case `GET ${API}/info`:
          return json(res, 200, info);

        case `POST ${API}/prepare-upload`: {
          if (pin && q.pin !== pin) return json(res, 401, { message: 'PIN required' });
          const body = await readJson(req);
          const files = Object.values(body.files || {});
          if (!files.length) return json(res, 400, { message: 'No files provided' });
          if (session) return json(res, 409, { message: 'Blocked by another session' });
          session = { id: randomUUID(), ip, files: {}, active: false };
          const isMessage = files.length === 1 && files[0].fileType === 'text/plain' && files[0].preview != null;
          log(isMessage ? `MESSAGE from ${body.info.alias} (client-cert fingerprint ${clientFp}): "${files[0].preview}"`
            : `prepare-upload from ${body.info.alias} (${clientFp?.slice(0, 8)}…${paired.has(clientFp) ? ', paired' : ''}): ${files.map((f) => `${f.fileName} ${f.size}B ${f.fileType}`).join(', ')}`);
          // Like the Rust receiver's PendingGuard: a sender that disconnects mid-prompt frees the slot.
          const mine = session; let gone = false;
          req.socket.once('close', () => { gone = true; if (session === mine && !mine.active) { log('sender disconnected before answer'); session = null; } });
          let accepted = mode === 'accept' ? true : mode === 'reject' ? false : await ask('Accept? [y/N] ');
          if (gone || session !== mine) return;
          if (!accepted) { session = null; return json(res, 403, { message: 'Rejected' }); }
          mine.active = true;
          if (isMessage) { session = null; return json(res, 204); }
          const tokens = {};
          for (const f of files) { const t = randomUUID(); session.files[f.id] = { dto: f, token: t, done: false }; tokens[f.id] = t; }
          return json(res, 200, { sessionId: session.id, files: tokens });
        }

        case `POST ${API}/upload`: {
          const f = session?.files[q.fileId];
          if (!q.sessionId || !q.fileId || !q.token) return json(res, 400, { message: 'Missing parameters' });
          if (!session || session.id !== q.sessionId || session.ip !== ip || !f || f.token !== q.token)
            return json(res, 403, { message: 'Invalid token or IP address' });
          const tmp = join(inbox, `.${q.fileId}.part`), out = join(inbox, basename(f.dto.fileName));
          const hash = createHash('sha256'); let bytes = 0;
          const ws = createWriteStream(tmp); ws.on('error', () => {});
          req.on('data', (c) => {
            hash.update(c); bytes += c.length;
            if (throttleKbps) { req.pause(); setTimeout(() => req.resume(), (c.length / 1024 / throttleKbps) * 1000); }
          });
          req.socket.once('close', () => { if (!req.complete) { ws.destroy(); try { unlinkSync(tmp); } catch {} log('upload aborted by sender', f.dto.fileName); } });
          req.pipe(ws);
          ws.on('finish', () => {
            const actual = hash.digest('hex');
            if (f.dto.sha256 && actual.toLowerCase() !== f.dto.sha256.toLowerCase()) {
              unlinkSync(tmp); log('CHECKSUM MISMATCH', f.dto.fileName); return json(res, 422, { message: 'Checksum mismatch' });
            }
            renameSync(tmp, out); f.done = true;
            log(`saved ${out} (${bytes}B${f.dto.sha256 ? ', sha256 ok' : ''})`);
            if (Object.values(session.files).every((x) => x.done)) { log('session complete'); session = null; }
            json(res, 200);
          });
          return;
        }

        case `POST ${GRASP_API}/pair`: {
          if (!graspMode) return json(res, 404, { message: 'Not found' });
          const body = await readJson(req);
          if (!clientFp) return json(res, 400, { message: 'Client certificate required' });
          if (!pairing) return json(res, 409, { message: 'Pairing is not open on the PC' });
          if (String(body.code ?? '').trim() !== pairing.code) {
            pairing.attempts += 1;
            if (pairing.attempts >= 5) { pairing = null; log('PAIR locked after 5 wrong codes'); return json(res, 429, { message: 'Too many wrong codes' }); }
            log(`PAIR wrong code from ${body.info?.alias}`);
            return json(res, 401, { message: 'Wrong code', attemptsLeft: 5 - pairing.attempts });
          }
          pairing = null; paired.add(clientFp);
          log(`PAIRED ${body.info?.alias} ${clientFp}`);
          return json(res, 200, info);
        }

        case `GET ${GRASP_API}/outbox`:
        case `GET ${GRASP_API}/outbox/file`:
        case `POST ${GRASP_API}/outbox/done`: {
          if (!graspMode) return json(res, 404, { message: 'Not found' });
          if (!clientFp) return json(res, 403, { message: 'Client certificate required' });
          if (!paired.has(clientFp)) return json(res, 403, { message: 'Not paired: pair this iPhone by code first' });
          if (url.pathname.endsWith('/outbox')) {
            for (const gone of outbox.filter((i) => i.kind === 'file' && !existsSync(i.path))) {
              outbox.splice(outbox.indexOf(gone), 1); log(`OUTBOX ${gone.fileName} was moved or deleted, dropped`);
            }
            return json(res, 200, { items: outbox.map(wire) });
          }
          if (!q.id) return json(res, 400, { message: 'Missing id' });
          const i = outbox.findIndex((x) => x.id === q.id);
          if (url.pathname.endsWith('/done')) {
            if (i >= 0) { const [it] = outbox.splice(i, 1); log(`DELIVERED ${it.fileName ?? it.text} (${outbox.length} left)`); }
            return json(res, 200);
          }
          const it = outbox[i];
          if (!it) return json(res, 404, { message: 'Not in the outbox' });
          if (it.kind !== 'file') return json(res, 400, { message: 'Not a file' });
          if (!existsSync(it.path)) { outbox.splice(i, 1); return json(res, 404, { message: 'File was moved or deleted' }); }
          res.writeHead(200, { 'content-type': 'application/octet-stream', 'content-length': statSync(it.path).size });
          return createReadStream(it.path).pipe(res);
        }

        case `POST ${API}/cancel`:
          if (session && session.id === q.sessionId) { log('cancelled by sender'); session = null; }
          return json(res, 200);

        default:
          return json(res, 404, { message: 'Not found' });
      }
    } catch (e) { log('error', e); json(res, 500, { message: String(e) }); }
  });

server.listen(port, '0.0.0.0', () => {
  log(`Mock LocalSend receiver on https://0.0.0.0:${port}  mode=${mode}  clientCert=${mandatoryClientCert ? 'mandatory' : 'optional'}${pin ? '  pin=' + pin : ''}`);
  log(`server cert fingerprint ${me.fingerprint}`);
  if (outbox.length) log(`outbox: ${outbox.length} item(s) waiting for a paired phone`);
});
