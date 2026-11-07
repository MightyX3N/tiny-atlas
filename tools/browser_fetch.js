// Runs the route builder's downloads inside a browser (used when the build machine has no direct
// internet). Rebuilds the builder's corridor queries from the GPX files, fetches OSM / elevation /
// climate, and keeps everything in window.__res for collection.
window.__res = window.__res || {}; window.__log = [];
const FILTERS = [
  'way[~"^(highway|building|landuse|natural|leisure|waterway|railway|amenity|man_made|place)$"~"."]',
  'relation[~"^(natural|landuse|leisure|building|water|waterway)$"~"."]',
  'node[~"^(natural|place)$"~"^(tree|city|town|village|hamlet|suburb|neighbourhood|quarter)$"]'];
const KEEP = new Set(['highway','building','landuse','natural','leisure','waterway','railway','amenity','surface','bridge','tunnel','layer','building:levels','height','name','water','man_made','area','lanes','width','cycleway','service','roof:shape','roof:colour','building:colour','leaf_type','genus','place','sport','crop','wetland','tracktype','smoothness','covered','population']);
function polylines(text, maxKm) {
  const doc = new DOMParser().parseFromString(text, 'application/xml');
  const pts = el => [...el.children].filter(c => /trkpt|rtept/.test(c.localName)).map(c => [+c.getAttribute('lat'), +c.getAttribute('lon')]).filter(p => isFinite(p[0]) && isFinite(p[1]));
  let segs = [...doc.getElementsByTagNameNS('*', 'trkseg')].map(pts).filter(s => s.length >= 2);
  if (!segs.length) segs = [...doc.getElementsByTagNameNS('*', 'rte')].map(pts).filter(s => s.length >= 2);
  const P = segs.flat(); const lat0 = P[0][0], lon0 = P[0][1];
  const kx = Math.cos(lat0 * Math.PI / 180) * 111320, ky = 110540;
  let X = [], Y = [], D = [];
  for (const [la, lo] of P) { const x = (lo - lon0) * kx, y = (la - lat0) * ky;
    const d = X.length ? D[D.length - 1] + Math.hypot(x - X[X.length - 1], y - Y[Y.length - 1]) : 0;
    if (X.length && d - D[D.length - 1] <= 0.05) continue; X.push(x); Y.push(y); D.push(d); }
  if (maxKm) { const n = D.findIndex(d => d > maxKm * 1000 + 5); if (n > 0) { X = X.slice(0, n); Y = Y.slice(0, n); D = D.slice(0, n); } }
  const L = D[D.length - 1]; const S = []; for (let s = 0; s <= L + 1e-6; s += 5) S.push(s);
  let j = 0; const xs = [], ys = [];
  for (const s of S) { while (j < D.length - 2 && D[j + 1] < s) j++; const f = Math.min(1, Math.max(0, (s - D[j]) / ((D[j + 1] - D[j]) || 1))); xs.push(X[j] + (X[j + 1] - X[j]) * f); ys.push(Y[j] + (Y[j + 1] - Y[j]) * f); }
  const out = []; const n = Math.max(1, Math.ceil(L / 6000));
  for (let k = 0; k < n; k++) { const lo = k * 6000, hi = Math.min(L, (k + 1) * 6000);
    const idx = []; S.forEach((s, i) => { if (s >= lo - 50 && s <= hi + 50) idx.push(i); });
    const sel = idx.filter((_, i) => i % 32 === 0);
    out.push(sel.map(i => `${(lat0 + ys[i] / ky).toFixed(5)},${(lon0 + xs[i] / kx).toFixed(5)}`).join(',')); }
  return out;
}
function compact(j) {
  const r6 = v => Math.round(v * 1e6) / 1e6, G = g => g.map(q => q ? { lat: r6(q.lat), lon: r6(q.lon) } : null);
  const tg = t => { const o = {}; for (const k in (t || {})) if (KEEP.has(k)) o[k] = t[k]; return o; };
  return { elements: j.elements.map(e => e.type === 'node' ? { type: 'node', id: e.id, lat: r6(e.lat), lon: r6(e.lon), tags: tg(e.tags) }
    : e.type === 'way' ? { type: 'way', id: e.id, tags: tg(e.tags), geometry: G(e.geometry || []) }
    : { type: 'relation', id: e.id, tags: tg(e.tags), members: (e.members || []).filter(m => m.geometry).map(m => ({ type: m.type, role: m.role, geometry: G(m.geometry) })) }) };
}
async function get(url, opt, tries = 4) {
  for (let t = 0; t < tries; t++) { try { const c = new AbortController(); const tm = setTimeout(() => c.abort(), 200000);
      const r = await fetch(url, { ...opt, signal: c.signal }); clearTimeout(tm); if (r.ok) return r; window.__log.push(url.slice(0, 60) + ' ' + r.status); }
    catch (e) { window.__log.push(url.slice(0, 60) + ' ' + e); } await new Promise(r => setTimeout(r, 4000 * (t + 1))); }
  throw new Error('failed ' + url);
}
window.__runOSM = async (routes) => {
  for (const [file, maxKm] of routes) {
    const text = await (await get('https://gpxviewer.app/samples/' + file)).text();
    const polys = polylines(text, maxKm);
    for (let k = 0; k < polys.length; k++) { const id = `osm|${file}|${k}`; if (window.__res[id]) continue;
      const q = `[out:json][timeout:180];(${FILTERS.map(f => `${f}(around:600,${polys[k]});`).join('')});out geom;`;
      const r = await get('https://maps.mail.ru/osm/tools/overpass/api/interpreter', { method: 'POST', body: 'data=' + encodeURIComponent(q) });
      window.__res[id] = JSON.stringify(compact(await r.json())); }
  }
};
window.__runURLs = async (items, par = 6) => {   // items: [id, url]
  let i = 0; const work = async () => { while (i < items.length) { const [id, url] = items[i++]; if (window.__res[id]) continue;
      const b = new Uint8Array(await (await get(url)).arrayBuffer()); let s = ''; for (let k = 0; k < b.length; k += 8192) s += String.fromCharCode(...b.subarray(k, k + 8192)); window.__res[id] = 'B64:' + btoa(s); } };
  await Promise.all(Array.from({ length: par }, work));
};
window.__pack = async (prefix) => {
  const o = {}; for (const k in window.__res) if (k.startsWith(prefix)) o[k] = window.__res[k];
  const cs = new Blob([JSON.stringify(o)]).stream().pipeThrough(new CompressionStream('gzip'));
  const b = new Uint8Array(await new Response(cs).arrayBuffer()); let s = ''; for (let k = 0; k < b.length; k += 8192) s += String.fromCharCode(...b.subarray(k, k + 8192));
  window.__out = btoa(s); return { keys: Object.keys(o).length, b64: window.__out.length };
};
'ok'
