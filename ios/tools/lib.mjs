// Shared helpers for the Grasp protocol tools. No npm deps; needs `openssl` on PATH.
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { basename, join } from 'node:path';

export const PORT = 53317;
export const API = '/api/localsend/v2';
// Grasp for Windows extension, advertised as `grasp: N` in /info and /register. 1: code pairing.
// 2: also the outbox (Windows -> iPhone: the phone pulls; see windows/core/src/outbox.rs).
// 3: also durable pairing: GET /pair (is this phone paired), POST /unpair, removed phones refused.
export const GRASP_API = '/api/grasp/v1';
export const GRASP_LEVEL = 3;
export const VERSION = '2.2';

// LocalSend fingerprint: uppercase hex SHA-256 of cert DER (core/src/crypto/cert.rs).
export const fingerprintOfDer = (der) => createHash('sha256').update(der).digest('hex').toUpperCase();

export function pemToDer(pem) {
  const b64 = pem.toString().replace(/-----[^-]+-----/g, '').replace(/\s+/g, '');
  return Buffer.from(b64, 'base64');
}

// Self-signed RSA-2048 cert, same shape as LocalSend's generate_self_signed().
export function ensureCert(dir, cn) {
  mkdirSync(dir, { recursive: true });
  const key = join(dir, 'key.pem'), cert = join(dir, 'cert.pem');
  if (!existsSync(key) || !existsSync(cert)) {
    execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-sha256',
      '-days', '3650', '-subj', `/CN=${cn}`, '-keyout', key, '-out', cert], { stdio: 'ignore' });
  }
  const certPem = readFileSync(cert);
  return { key: readFileSync(key), cert: certPem, fingerprint: fingerprintOfDer(pemToDer(certPem)) };
}

export const MIME = { '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png', '.heic': 'image/heic',
  '.pdf': 'application/pdf', '.txt': 'text/plain', '.mov': 'video/quicktime', '.mp4': 'video/mp4', '.zip': 'application/zip' };
export const mimeOf = (name) => MIME[(name.match(/\.[^.]+$/)?.[0] ?? '').toLowerCase()] ?? 'application/octet-stream';

// Outbox entries for files and folders, same rules as windows/core/src/outbox.rs: a folder's files
// (recursive, name-sorted) keep their path under the folder's name with `/`; dotfiles, desktop.ini and
// Thumbs.db are skipped.
const skipped = (n) => n.startsWith('.') || /^(desktop\.ini|thumbs\.db)$/i.test(n);
export function outboxEntries(paths) {
  const out = [];
  const walk = (dir, prefix) => {
    for (const n of readdirSync(dir).sort((a, b) => a.toLowerCase().localeCompare(b.toLowerCase()))) {
      if (skipped(n)) continue;
      const p = join(dir, n), rel = `${prefix}/${n}`;
      if (statSync(p).isDirectory()) walk(p, rel);
      else out.push({ path: p, fileName: rel });
    }
  };
  for (const p of paths) {
    if (!existsSync(p)) continue;
    if (statSync(p).isDirectory()) walk(p, basename(p));
    else if (!skipped(basename(p))) out.push({ path: p, fileName: basename(p) });
  }
  return out.map((e) => ({ ...e, size: statSync(e.path).size, fileType: mimeOf(e.fileName) }));
}

// Where a pulled file lands under `root`, same rule as the iPhone (InboxEngine.destination): every path
// component is cleaned, `.`/`..`/empty ones dropped, so a name can never climb out of `root`.
export function safeRelative(fileName) {
  const parts = String(fileName).split(/[\\/]/).map((c) => c.replace(/[:*?"<>|\x00-\x1f]/g, '_').trim())
    .filter((c) => c && c !== '.' && c !== '..');
  return parts.length ? parts : ['file'];
}
