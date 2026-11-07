// Browser-side fetcher for the low-detail rings: vector tiles (decoded, stripped to the layers/properties the
// route builder reads, delta-coded integer geometry) and Terrarium elevation tiles (delta-coded int16 of 2*h).
// Output: window.__packBin(prefix) -> gzip of [u32 namelen][u32 datalen][name][data]..., base64 in window.__out.
window.__res = window.__res || {}; window.__log = window.__log || [];
const KEEP14 = { transportation: ['class', 'subclass', 'brunnel', 'surface', 'layer', 'ramp'], building: ['hide_3d', 'render_height', 'render_min_height'],
  landcover: ['class', 'subclass'], landuse: ['class'], park: ['class'], water: ['class', 'brunnel'], waterway: ['class', 'brunnel'], place: ['class', 'name', 'name:latin'] };
const KEEP12 = { landcover: ['class', 'subclass'], landuse: ['class'], park: ['class'], water: ['class', 'brunnel'], waterway: ['class', 'brunnel'] };
function reader(buf) {
  let p = 0;
  const r = {
    get pos() { return p; }, end: buf.length,
    varint() { let v = 0, s = 1, b; do { b = buf[p++]; v += (b & 0x7f) * s; s *= 128; } while (b & 0x80); return v; },
    bytes() { const n = r.varint(); const o = buf.subarray(p, p + n); p += n; return o; },
    skip(w) { if (w === 0) r.varint(); else if (w === 1) p += 8; else if (w === 2) { const n = r.varint(); p += n; } else if (w === 5) p += 4; else throw new Error('wire ' + w); },
    f32() { const v = new DataView(buf.buffer, buf.byteOffset + p, 4).getFloat32(0, true); p += 4; return v; },
    f64() { const v = new DataView(buf.buffer, buf.byteOffset + p, 8).getFloat64(0, true); p += 8; return v; },
  };
  return r;
}
const td = new TextDecoder();
const zz = n => (n % 2 ? -(n + 1) / 2 : n / 2);
function packed(b) { const r = reader(b), o = []; while (r.pos < r.end) o.push(r.varint()); return o; }
function decodeValue(b) { const r = reader(b); let v = null;
  while (r.pos < r.end) { const t = r.varint(), f = t >> 3, w = t & 7;
    if (f === 1) v = td.decode(r.bytes()); else if (f === 2) v = r.f32(); else if (f === 3) v = r.f64(); else if (f === 4 || f === 5) v = r.varint();
    else if (f === 6) v = zz(r.varint()); else if (f === 7) v = !!r.varint(); else r.skip(w); }
  return v; }
function geom(cmds) {   // -> rings of absolute points
  const rings = []; let x = 0, y = 0, cur = null, i = 0;
  while (i < cmds.length) { const c = cmds[i++], id = c & 7, n = c >> 3;
    if (id === 7) continue;
    for (let k = 0; k < n; k++) { x += zz(cmds[i++]); y += zz(cmds[i++]);
      if (id === 1) { cur = [[x, y]]; rings.push(cur); } else cur.push([x, y]); } }
  return rings;
}
function strip(buf, keep) {
  const out = {}; const r = reader(buf);
  while (r.pos < r.end) { const t = r.varint(); if ((t >> 3) !== 3) { r.skip(t & 7); continue; }
    const lr = reader(r.bytes()); let name = '', ext = 4096; const feats = [], keys = [], vals = [];
    while (lr.pos < lr.end) { const t2 = lr.varint(), f = t2 >> 3;
      if (f === 1) name = td.decode(lr.bytes()); else if (f === 2) feats.push(lr.bytes()); else if (f === 3) keys.push(td.decode(lr.bytes()));
      else if (f === 4) vals.push(decodeValue(lr.bytes())); else if (f === 5) ext = lr.varint(); else lr.skip(t2 & 7); }
    const want = keep[name]; if (!want) continue;
    const F = [];
    for (const fb of feats) { const fr = reader(fb); let tags = [], type = 0, g = [];
      while (fr.pos < fr.end) { const t3 = fr.varint(), f = t3 >> 3;
        if (f === 2) tags = packed(fr.bytes()); else if (f === 3) type = fr.varint(); else if (f === 4) g = packed(fr.bytes()); else fr.skip(t3 & 7); }
      const props = {}; for (let k = 0; k < tags.length; k += 2) { const key = keys[tags[k]]; if (want.includes(key)) props[key] = vals[tags[k + 1]]; }
      if (name === 'waterway' && keep === KEEP12 && props.class === 'stream') continue;
      const rings = geom(g).map(ring => { const d = []; let px = 0, py = 0; for (const [x, y] of ring) { d.push(x - px, y - py); px = x; py = y; } return d; });
      if (!rings.length) continue;
      F.push([type, props, rings]); }
    out[name] = { e: ext, f: F };
  }
  return out;
}
async function get(url, tries = 4) {
  for (let t = 0; t < tries; t++) { try { const r = await fetch(url); if (r.ok) return r; window.__log.push(url.slice(-40) + ' ' + r.status); if (r.status === 404) return null; }
    catch (e) { window.__log.push(url.slice(-40) + ' ' + e); } await new Promise(r => setTimeout(r, 3000 * (t + 1))); }
  throw new Error('failed ' + url);
}
const enc = new TextEncoder();
window.__fetchVT = async (base, list, par = 6) => {
  let i = 0; const work = async () => { while (i < list.length) { const zxy = list[i++]; const id = 'vt|' + zxy; if (window.__res[id]) continue;
    const r = await get(base + zxy + '.pbf'); if (!r) { window.__res[id] = enc.encode('{}'); continue; }
    const z = +zxy.split('/')[0];
    window.__res[id] = enc.encode(JSON.stringify(strip(new Uint8Array(await r.arrayBuffer()), z >= 14 ? KEEP14 : KEEP12))); } };
  await Promise.all(Array.from({ length: par }, work)); return 'vt done';
};
window.__fetchDEM = async (list, par = 6) => {
  let i = 0; const work = async () => { while (i < list.length) { const zxy = list[i++]; const id = 'dem|' + zxy + '.png'; if (window.__res[id]) continue;
    const r = await get('https://s3.amazonaws.com/elevation-tiles-prod/terrarium/' + zxy + '.png');
    const bm = await createImageBitmap(await r.blob()); const cv = new OffscreenCanvas(256, 256); const cx = cv.getContext('2d'); cx.drawImage(bm, 0, 0);
    const px = cx.getImageData(0, 0, 256, 256).data; const out = new Int16Array(65536); let prev = 0;
    for (let k = 0; k < 65536; k++) { const h = px[k * 4] * 256 + px[k * 4 + 1] + px[k * 4 + 2] / 256 - 32768; const q = Math.round(h * 2); out[k] = q - prev; prev = q; }
    window.__res[id] = new Uint8Array(out.buffer); } };
  await Promise.all(Array.from({ length: par }, work)); return 'dem done';
};
window.__packBin = async (prefix) => {
  const parts = []; let n = 0;
  for (const k in window.__res) { if (!k.startsWith(prefix)) continue; const nm = enc.encode(k), d = window.__res[k];
    const h = new Uint8Array(8); const dv = new DataView(h.buffer); dv.setUint32(0, nm.length); dv.setUint32(4, d.length); parts.push(h, nm, d); n++; }
  const cs = new Blob(parts).stream().pipeThrough(new CompressionStream('gzip'));
  const b = new Uint8Array(await new Response(cs).arrayBuffer()); let s = ''; for (let k = 0; k < b.length; k += 8192) s += String.fromCharCode(...b.subarray(k, k + 8192));
  window.__out = btoa(s); return { keys: n, b64: window.__out.length };
};
'ok'
