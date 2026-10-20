import { readFileSync, writeFileSync } from 'node:fs';

// Windows' bundled QuickJS lacks BigInt. Noble only needs it here to encode
// safe-integer byte/bit lengths, so preserve the cipher and encode those lengths
// as two unsigned 32-bit words. Fail closed if a dependency update changes the
// generated sites; never silently ship a partially adapted crypto bundle.
const path = new URL('../../assets/js/lnreader_cheerio.js', import.meta.url);
let source = readFileSync(path, 'utf8');
if (!source.includes('globalThis.__lnSetUint64 = function')) {
  const shim = readFileSync(new URL('./shim.mjs', import.meta.url), 'utf8');
  const start = shim.indexOf('globalThis.__lnSetUint64 = function');
  const end = shim.indexOf('\n};', start);
  if (start < 0 || end < 0) throw new Error('Missing QuickJS length helper');
  source = `${shim.slice(start, end + 3)}\n${source}`;
}
const replacements = [
  ['view.setBigUint64(0, BigInt(aadLength), isLE2);',
   'globalThis.__lnSetUint64(view, 0, aadLength, isLE2);'],
  ['view.setBigUint64(8, BigInt(dataLength), isLE2);',
   'globalThis.__lnSetUint64(view, 8, dataLength, isLE2);'],
  ['view.setBigUint64(8, BigInt(nonce.length * 8), false);',
   'globalThis.__lnSetUint64(view, 8, nonce.length * 8, false);'],
];
for (const [before, after] of replacements) {
  if (source.includes(before)) source = source.replace(before, after);
  else if (!source.includes(after)) throw new Error(`Missing Noble length site: ${before}`);
}
writeFileSync(path, source);
