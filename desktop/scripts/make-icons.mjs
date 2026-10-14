// Generates the placeholder app icon (blue squircle, white arrow dropping into a tray) with no
// dependencies. Writes src-tauri/icons/{32x32.png,128x128.png,icon.png,icon.ico}.
//   node scripts/make-icons.mjs
import { deflateSync } from 'node:zlib';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const out = join(dirname(fileURLToPath(import.meta.url)), '..', 'src-tauri', 'icons');
mkdirSync(out, { recursive: true });

const inRoundRect = (x, y, cx, cy, hw, hh, r) => {
  const dx = Math.max(Math.abs(x - cx) - (hw - r), 0), dy = Math.max(Math.abs(y - cy) - (hh - r), 0);
  return dx * dx + dy * dy <= r * r;
};
const inRect = (x, y, x0, y0, x1, y1) => x >= x0 && x <= x1 && y >= y0 && y <= y1;
const inTriangle = (x, y) => { // arrow head, apex down
  if (y < 0.50 || y > 0.67) return false;
  const half = 0.17 * (1 - (y - 0.50) / 0.17);
  return Math.abs(x - 0.5) <= half;
};
const glyph = (x, y) =>
  inRect(x, y, 0.46, 0.22, 0.54, 0.52) || inTriangle(x, y) ||
  inRect(x, y, 0.30, 0.74, 0.70, 0.79) || inRect(x, y, 0.30, 0.64, 0.35, 0.79) || inRect(x, y, 0.65, 0.64, 0.70, 0.79);

function render(size) {
  const SS = 4, px = Buffer.alloc(size * size * 4);
  for (let py = 0; py < size; py++) for (let pxl = 0; pxl < size; pxl++) {
    let r = 0, g = 0, b = 0, a = 0;
    for (let sy = 0; sy < SS; sy++) for (let sx = 0; sx < SS; sx++) {
      const x = (pxl + (sx + 0.5) / SS) / size, y = (py + (sy + 0.5) / SS) / size;
      if (!inRoundRect(x, y, 0.5, 0.5, 0.47, 0.47, 0.22)) continue;
      const t = (x + y) / 2; // diagonal gradient
      const white = glyph(x, y);
      r += white ? 255 : 58 + (10 - 58) * t; g += white ? 255 : 168 + (92 - 168) * t; b += white ? 255 : 255;
      a += 255;
    }
    const n = SS * SS, i = (py * size + pxl) * 4;
    const cov = a / (255 * n);
    px[i] = cov ? r / (a / 255) : 0; px[i + 1] = cov ? g / (a / 255) : 0; px[i + 2] = cov ? b / (a / 255) : 0; px[i + 3] = Math.round(a / n);
  }
  return px;
}

const crcTable = Array.from({ length: 256 }, (_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0; });
const crc32 = (buf) => { let c = 0xffffffff; for (const b of buf) c = crcTable[(c ^ b) & 0xff] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
const chunk = (type, data) => {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
};
function png(size) {
  const raw = render(size), rows = Buffer.alloc((size * 4 + 1) * size);
  for (let y = 0; y < size; y++) { rows[y * (size * 4 + 1)] = 0; raw.copy(rows, y * (size * 4 + 1) + 1, y * size * 4, (y + 1) * size * 4); }
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(size, 0); ihdr.writeUInt32BE(size, 4); ihdr[8] = 8; ihdr[9] = 6;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', deflateSync(rows)), chunk('IEND', Buffer.alloc(0))]);
}

const sizes = { '32x32.png': 32, '128x128.png': 128, 'icon.png': 512 };
for (const [name, s] of Object.entries(sizes)) writeFileSync(join(out, name), png(s));

// .ico with PNG-compressed entries (supported since Vista).
const ico = [16, 32, 48, 256].map((s) => ({ s, data: png(s) }));
const head = Buffer.alloc(6); head.writeUInt16LE(1, 2); head.writeUInt16LE(ico.length, 4);
let offset = 6 + 16 * ico.length;
const dir = ico.map(({ s, data }) => {
  const e = Buffer.alloc(16); e[0] = s === 256 ? 0 : s; e[1] = s === 256 ? 0 : s; e.writeUInt16LE(1, 4); e.writeUInt16LE(32, 6);
  e.writeUInt32LE(data.length, 8); e.writeUInt32LE(offset, 12); offset += data.length; return e;
});
writeFileSync(join(out, 'icon.ico'), Buffer.concat([head, ...dir, ...ico.map((i) => i.data)]));
console.log('icons written to', out);
