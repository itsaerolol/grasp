// Shared helpers for the Grasp protocol tools. No npm deps; needs `openssl` on PATH.
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

export const PORT = 53317;
export const API = '/api/localsend/v2';
// Grasp for Windows extension: code pairing (advertised as `grasp: 1` in /info and /register).
export const GRASP_API = '/api/grasp/v1';
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
