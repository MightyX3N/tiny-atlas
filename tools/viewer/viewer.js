// Route viewer: renders a route package with an asset pack (stand-in for the GMod / LÖVE renderers).
// URL: viewer.html?route=<dir>&pack=<addon dir>&s=<metres along route>&view=third|first|iso|free&month=jul
import * as THREE from 'three';
import { FBXLoader } from 'three/addons/loaders/FBXLoader.js';
import { mergeGeometries } from 'three/addons/utils/BufferGeometryUtils.js';

const Q = new URLSearchParams(location.search);
const VIEW = Q.get('view') || 'third', RW = +Q.get('w') || 480, RH = +Q.get('h') || 270;
const ROUTE = Q.get('route'), PACKDIR = Q.get('pack');
const log = (...a) => console.log('[pv]', ...a);
const J = async (u) => { const r = await fetch(u); if (!r.ok) throw new Error(u + ' ' + r.status); return r.json(); };
const BIN = async (u) => new Uint16Array(await (await fetch(u)).arrayBuffer());
const IMG = (u) => new Promise((res, rej) => { const i = new Image(); i.onload = () => res(i); i.onerror = () => rej(new Error('image ' + u)); i.src = u; });
const near = (t) => { t.magFilter = t.minFilter = THREE.NearestFilter; t.generateMipmaps = false; t.colorSpace = THREE.SRGBColorSpace; return t; };

const R = await J(`${ROUTE}/route.json`), TK = await J(`${ROUTE}/track.json`), BR = await J(`${ROUTE}/bridges.json`);
const packId = (await J(`${PACKDIR}/pack_index.json`)).id;
const MAT = `${PACKDIR}/materials/tinyatlas/packs/${packId}`;
const PK = await J(`${MAT}/pack.json`);
const MONTHS = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
const month = Q.get('month') || 'jul';
const clim = R.climate && R.climate.months ? R.climate.months[month] : null;
const season = clim && clim.snow_likely ? 'winter' : ['sep', 'oct', 'nov'].includes(month) ? 'autumn' : (['dec', 'jan', 'feb'].includes(month) ? 'winter' : 'summer');
const seasonal = (PK.seasons || {})[season] || {};
const groundOf = (tag) => (seasonal.ground && seasonal.ground[tag]) || PK.ground[tag] || PK.ground.rural;
const treesOf = (kind) => Object.assign({}, PK.trees[kind] || PK.trees.broadleaf, (seasonal.trees || {})[kind] || {});
const TAGS = R.ground_tags;

// ---------------- track helpers
const S_AT = Math.min(+Q.get('s') || 20, R.distance_m - 10);
function trackAt(s) {
  const i = Math.max(0, Math.min(TK.n - 2, Math.floor(s / TK.step))), f = (s - TK.s[i]) / TK.step;
  const L = (a) => a[i] + (a[i + 1] - a[i]) * f;
  const j = Math.min(TK.n - 1, i + 3), k = Math.max(0, i - 3);
  return { x: L(TK.x), y: L(TK.y), z: L(TK.z), hd: Math.atan2(TK.y[j] - TK.y[k], TK.x[j] - TK.x[k]), bridge: TK.bridge[i], ferry: TK.ferry ? TK.ferry[i] : 0 };
}
const RP = trackAt(S_AT);
const V = (x, y, z) => new THREE.Vector3(x, z, -y);

// ---------------- chunks near the camera
const CS = R.chunk_size, NEED = +Q.get('radius') || 650;
const chunkList = R.chunks.filter(c => { const mx = (c.cx + .5) * CS, my = (c.cy + .5) * CS; return Math.hypot(mx - RP.x, my - RP.y) < NEED + CS * .71; });
const CH = new Map();
await Promise.all(chunkList.map(async (c) => {
  const m = await J(`${ROUTE}/chunks/${c.file}`);
  const h = await BIN(`${ROUTE}/chunks/${m.height.file}`);
  const hf = new Float32Array(h.length); for (let i = 0; i < h.length; i++) hf[i] = m.height.base + h[i] * m.height.scale;
  m.hf = hf; m.cls = await IMG(`${ROUTE}/chunks/${m.ground.file}`); CH.set(`${c.cx},${c.cy}`, m);
  if (m.water) { const w = await BIN(`${ROUTE}/chunks/${m.water.file}`); m.wf = Float32Array.from(w, v => m.water.base + v * m.water.scale); }
}));
function hAt(x, y) {
  const c = CH.get(`${Math.floor(x / CS)},${Math.floor(y / CS)}`); if (!c) return null;
  const n = c.height.n, j = (x - c.x0) / c.height.res, i = (c.y0 + CS - y) / c.height.res;
  const j0 = Math.min(n - 2, Math.floor(j)), i0 = Math.min(n - 2, Math.floor(i)), dx = j - j0, dy = i - i0, g = (a, b) => c.hf[a * n + b];
  return g(i0, j0) * (1 - dx) * (1 - dy) + g(i0, j0 + 1) * dx * (1 - dy) + g(i0 + 1, j0) * (1 - dx) * dy + g(i0 + 1, j0 + 1) * dx * dy;
}
// ---------------- mid ring pages (4 m heights, 2 m tags) near the camera
const MIDR = +Q.get('midradius') || 3500, MID = [];
if (R.mid) {
  const PS = R.mid.page_size;
  const pl = R.mid.pages.filter(p => Math.hypot((p.px + .5) * PS - RP.x, (p.py + .5) * PS - RP.y) < MIDR + PS * .71);
  await Promise.all(pl.map(async (p) => {
    const m = await J(`${ROUTE}/mid/${p.file}`); const h = await BIN(`${ROUTE}/mid/${m.height.file}`);
    const hf = new Float32Array(h.length); for (let i = 0; i < h.length; i++) hf[i] = m.height.base + h[i] * m.height.scale;
    m.hf = hf; m.cls = await IMG(`${ROUTE}/mid/${m.ground.file}`); MID.push(m);
    if (m.water) { const w = await BIN(`${ROUTE}/mid/${m.water.file}`); m.wf = Float32Array.from(w, v => m.water.base + v * m.water.scale); }
  }));
}
log('chunks', CH.size, 'mid pages', MID.length, 'season', season);

// ---------------- renderer + sky
const renderer = new THREE.WebGLRenderer({ antialias: false, preserveDrawingBuffer: true });
renderer.setPixelRatio(1); renderer.setSize(RW, RH); renderer.shadowMap.enabled = true; renderer.outputColorSpace = THREE.SRGBColorSpace;
document.body.appendChild(renderer.domElement);
const scene = new THREE.Scene();
const sky = PK.sky || {}, sunP = PK.sun || {};
const HAZE = new THREE.Color(sky.haze || '#c8dbe8');
let wet = clim && clim.rain_days > 14 ? 0.15 : 0;
scene.background = new THREE.Color(sky.top || '#6fa6dc');
scene.fog = new THREE.Fog(HAZE, sky.fog_near || 300, VIEW === 'iso' ? 12000 : (sky.fog_far || 7000));
const hemi = new THREE.HemisphereLight(sunP.ambient || '#dfeeff', sunP.ground || '#6b6050', 1.25); scene.add(hemi);
const sun = new THREE.DirectionalLight(sunP.colour || '#fff1d6', sunP.strength || 2.4);
sun.castShadow = true; sun.shadow.mapSize.set(4096, 4096); sun.shadow.bias = -0.0004; sun.shadow.normalBias = 0.6; scene.add(sun, sun.target);
const SUN_DIR = new THREE.Vector3(-0.55, 0.62, 0.45).normalize();
{
  const g = new THREE.SphereGeometry(9000, 32, 16), c = [], p = g.attributes.position;
  for (let i = 0; i < p.count; i++) { const t = Math.max(0, p.getY(i) / 9000); const col = HAZE.clone().lerp(new THREE.Color(sky.top || '#6fa6dc'), Math.pow(t, 0.55)); c.push(col.r, col.g, col.b); }
  g.setAttribute('color', new THREE.Float32BufferAttribute(c, 3));
  window.__sky = new THREE.Mesh(g, new THREE.MeshBasicMaterial({ vertexColors: true, side: THREE.BackSide, fog: false, depthWrite: false }));
  window.__sky.renderOrder = -1; scene.add(window.__sky);
}

// ---------------- ground atlas from the pack: column = tag id, row = variant
const CELL = 32;
const atlasCv = document.createElement('canvas'); atlasCv.width = CELL * 32; atlasCv.height = CELL * 4;
{
  const ax = atlasCv.getContext('2d'); ax.imageSmoothingEnabled = false;
  for (let t = 0; t < TAGS.length; t++) {
    const list = groundOf(TAGS[t]);
    for (let v = 0; v < 4; v++) { const im = await IMG(`${MAT}/${list[v % list.length]}`); ax.drawImage(im, t * CELL, v * CELL, CELL, CELL); }
  }
}
const atlas = near(new THREE.CanvasTexture(atlasCv));
const wallIm = await IMG(`${MAT}/${(PK.wall || {}).texture || groundOf('cobble')[0]}`);
{ const ax = atlasCv.getContext('2d'); for (let v = 0; v < 4; v++) ax.drawImage(wallIm, 31 * CELL, v * CELL, CELL, CELL); atlas.needsUpdate = true; }
const prio = PK.ground_priority || {};
const prioArr = TAGS.map(t => prio[t] || 3);
const tileM = PK.tile_metres || 3.3, edgeK = PK.edge_darken ?? 0.28;
const wallTint = (PK.wall && PK.wall.tint) || [0.95, 0.9, 0.85];
const bedTint = (PK.water && PK.water.bed_tint) || [0.55, 0.6, 0.62];

function groundMat(ct, tx0, ty0, tsize, tn, lvl) {
  const mat = new THREE.MeshLambertMaterial({ color: 0xffffff });
  mat.onBeforeCompile = (sh) => {
    Object.assign(sh.uniforms, { uCls: { value: ct }, uAtlas: { value: atlas }, uO: { value: new THREE.Vector3(tx0, ty0, tsize) },
      uN: { value: tn }, uPrio: { value: prioArr }, uLvl: { value: lvl } });
    sh.vertexShader = sh.vertexShader.replace('#include <common>', '#include <common>\nvarying vec3 vW; varying float vNy;')
      .replace('#include <worldpos_vertex>', '#include <worldpos_vertex>\nvW = (modelMatrix * vec4(transformed,1.0)).xyz; vNy = normalize(mat3(modelMatrix) * objectNormal).y;');
    sh.fragmentShader = sh.fragmentShader.replace('#include <common>', `#include <common>
      varying vec3 vW; varying float vNy; uniform sampler2D uCls; uniform sampler2D uAtlas; uniform vec3 uO; uniform float uN; uniform float uPrio[${TAGS.length}]; uniform float uLvl;
      float cls(vec2 w){ vec2 uv = vec2((w.x-uO.x)/uO.z, (uO.y+uO.z-w.y)/uO.z); uv = clamp(uv, 0.5/uN, 1.0-0.5/uN); return floor(texture2D(uCls, uv).r*255.0+0.5); }
      float hash(vec2 p){ return fract(sin(dot(p, vec2(127.1,311.7)))*43758.5453); }
      float prio(float c){ float r = 3.0; for (int i=0;i<${TAGS.length};i++) if (float(i)==c) r = uPrio[i]; return r; }`)
      .replace('#include <map_fragment>', `
      vec2 w = vec2(vW.x, -vW.z);
      float c = cls(w);
      bool below = vW.y < uLvl + 0.6;
      bool wall = vNy < 0.55;                       // steep faces are stone, above or under the water
      // the ground under water is a river/lake bed, never the water texture: the water is its own surface
      float col = wall ? 31.0 : (c == ${TAGS.indexOf('water')}.0 ? ${TAGS.indexOf('gravel')}.0 : c);
      vec2 cell = wall ? vec2((w.x + w.y) * 0.7071, vW.y * 1.6) / ${tileM.toFixed(3)} : w / ${tileM.toFixed(3)};
      float var = floor(hash(floor(cell)) * 4.0);
      vec2 tuv = floor(fract(cell)*32.0)/32.0 + 0.5/32.0;
      vec4 tc = texture2D(uAtlas, vec2((col + tuv.x) / 32.0, 1.0 - (var + tuv.y) / 4.0));
      float px = uO.z / uN; float p0 = prio(c); float edge = 0.0;
      if (!wall) for (int k=0;k<4;k++){ vec2 o = k==0?vec2(px,0.):k==1?vec2(-px,0.):k==2?vec2(0.,px):vec2(0.,-px);
        float cn = cls(w+o); if (cn!=c && prio(cn)>p0) edge = 1.0; }
      if (wall) tc.rgb *= vec3(${wallTint.join(',')});
      if (below || c == ${TAGS.indexOf('water')}.0) tc.rgb *= vec3(${bedTint.join(',')});
      diffuseColor.rgb *= tc.rgb * (1.0 - edge*${edgeK.toFixed(3)});`);
  };
  return mat;
}
const clsTex = (im) => { const ct = new THREE.Texture(im); ct.magFilter = ct.minFilter = THREE.NearestFilter; ct.generateMipmaps = false; ct.flipY = false; ct.needsUpdate = true; return ct; };
// one ground patch: `cells` quads per side from a height grid (row-major, north row first), plus a skirt hanging
// below its edges so tiny height differences against a neighbour of another detail level never open a crack
function groundPatch(hf, hn, gres, gx0, gy1, i0, j0, cells, mat, skirt = 4) {
  const size = cells * gres, x0 = gx0 + j0 * gres, y1 = gy1 - i0 * gres;
  const g = new THREE.PlaneGeometry(size, size, cells, cells); g.rotateX(-Math.PI / 2);
  g.translate(x0 + size / 2, 0, -(y1 - size / 2));
  const p = g.attributes.position;
  for (let i = 0; i <= cells; i++) for (let j = 0; j <= cells; j++) p.setY(i * (cells + 1) + j, hf[(i0 + i) * hn + (j0 + j)]);
  g.computeVertexNormals();
  const m = new THREE.Mesh(g, mat); m.receiveShadow = true; scene.add(m);
  if (skirt > 0) {
    const pos = [], ring = [];
    for (let j = 0; j <= cells; j++) ring.push([0, j]); for (let i = 1; i <= cells; i++) ring.push([i, cells]);
    for (let j = cells - 1; j >= 0; j--) ring.push([cells, j]); for (let i = cells - 1; i >= 0; i--) ring.push([i, 0]);
    for (let k = 0; k < ring.length - 1; k++) {
      const [ia, ja] = ring[k], [ib, jb] = ring[k + 1];
      const A = [x0 + ja * gres, hf[(i0 + ia) * hn + j0 + ja], -(y1 - ia * gres)], B = [x0 + jb * gres, hf[(i0 + ib) * hn + j0 + jb], -(y1 - ib * gres)];
      const q = [A, B, [B[0], B[1] - skirt, B[2]], [A[0], A[1] - skirt, A[2]]];
      for (const t of [0, 1, 2, 0, 2, 3]) pos.push(...q[t]);
    }
    const sg = new THREE.BufferGeometry(); sg.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3)); sg.computeVertexNormals();
    const sm = new THREE.Mesh(sg, mat.userData.skirtMat || (mat.userData.skirtMat = Object.assign(mat.clone(), {}))); sm.material.side = THREE.DoubleSide; sm.material.onBeforeCompile = mat.onBeforeCompile; scene.add(sm);
  }
  return m;
}
let waterTex = null;
const WATER_ID = TAGS.indexOf('water');
// water surface from an 8 m height grid, drawn only over ground tagged as water (so streams can run downhill)
const WFRAME = +Q.get('wframe') || 0, wTex = {};
async function waterTexture(kind) {         // one frame of the pack's looping water (still or river), or its plain texture
  if (wTex[kind]) return wTex[kind];
  const a = (PK.water || {})[kind];
  let t;
  if (a && a.sheet) {
    const im = await IMG(`${MAT}/${a.sheet}`), n = im.width, cv = document.createElement('canvas'); cv.width = cv.height = n;
    cv.getContext('2d').drawImage(im, 0, -n * (WFRAME % a.frames)); t = near(new THREE.CanvasTexture(cv)); t.userData.metres = a.tile_metres || tileM * 3;
  } else {
    t = near(new THREE.Texture(await IMG(`${MAT}/${(PK.water || {}).texture || groundOf('water')[0]}`))); t.needsUpdate = true; t.userData.metres = tileM;
  }
  t.wrapS = t.wrapT = THREE.RepeatWrapping; wTex[kind] = t; return t;
}
async function waterGrid(wf, wn, wres, gx0, gy1, i0, j0, cells, ct, tx0, ty0, tsize, tn, flow) {
  const waterTex = await waterTexture(flow && (PK.water || {}).river ? 'river' : 'still'), TM = waterTex.userData.metres;
  // still water: texture straight; a river: the loop's "down" turned to point downstream
  const U = flow ? [-flow[1], flow[0]] : [1, 0], Vv = flow ? [-flow[0], -flow[1]] : [0, 1];
  const size = cells * wres, x0 = gx0 + j0 * wres, y1 = gy1 - i0 * wres;
  const g = new THREE.PlaneGeometry(size, size, cells, cells); g.rotateX(-Math.PI / 2); g.translate(x0 + size / 2, 0, -(y1 - size / 2));
  const p = g.attributes.position, uv = g.attributes.uv;
  for (let i = 0; i <= cells; i++) for (let j = 0; j <= cells; j++) { const k = i * (cells + 1) + j, X = x0 + j * wres, Y = y1 - i * wres;
    p.setY(k, wf[(i0 + i) * wn + j0 + j]); uv.setXY(k, (X * U[0] + Y * U[1]) / TM, (X * Vv[0] + Y * Vv[1]) / TM); }
  g.computeVertexNormals();
  const mat = new THREE.MeshLambertMaterial({ map: waterTex, transparent: true, opacity: (PK.water || {}).opacity || 0.86, depthWrite: false });
  mat.onBeforeCompile = (sh) => {
    Object.assign(sh.uniforms, { uCls: { value: ct }, uO: { value: new THREE.Vector3(tx0, ty0, tsize) }, uN: { value: tn } });
    sh.vertexShader = sh.vertexShader.replace('#include <common>', '#include <common>\nvarying vec3 vW;').replace('#include <worldpos_vertex>', '#include <worldpos_vertex>\nvW = (modelMatrix * vec4(transformed,1.0)).xyz;');
    sh.fragmentShader = sh.fragmentShader.replace('#include <common>', `#include <common>
      varying vec3 vW; uniform sampler2D uCls; uniform vec3 uO; uniform float uN;
      float clsAt(vec2 w){ vec2 uv = vec2((w.x-uO.x)/uO.z, (uO.y+uO.z-w.y)/uO.z); uv = clamp(uv, 0.5/uN, 1.0-0.5/uN); return floor(texture2D(uCls, uv).r*255.0+0.5); }`)
      .replace('#include <map_fragment>', `#include <map_fragment>
      { vec2 w = vec2(vW.x, -vW.z); float px = uO.z / uN; bool wet = false;
        for (int k = 0; k < 5; k++) { vec2 o = k==0?vec2(0.):k==1?vec2(px,0.):k==2?vec2(-px,0.):k==3?vec2(0.,px):vec2(0.,-px); if (clsAt(w+o) == ${WATER_ID}.0) wet = true; }
        if (!wet) discard; }`);
  };
  const wm = new THREE.Mesh(g, mat); wm.receiveShadow = true; wm.renderOrder = 2; scene.add(wm);
}
for (const c of CH.values()) {
  const n = c.height.n;
  const lvl = c.water_level === null ? -1e9 : c.water_level;
  c.__ct = clsTex(c.cls);
  groundPatch(c.hf, n, c.height.res, c.x0, c.y0 + CS, 0, 0, n - 1, groundMat(c.__ct, c.x0, c.y0, CS, c.ground.n, lvl));
  if (c.wf) await waterGrid(c.wf, c.water.n, c.water.res, c.x0, c.y0 + CS, 0, 0, c.water.n - 1, c.__ct, c.x0, c.y0, CS, c.ground.n, c.water.flow);
}
for (const pg of MID) {
  const ct = clsTex(pg.cls), per = Math.round(CS / pg.height.res), n = pg.height.n;
  for (const [cx, cy] of pg.present) {
    const j0 = (cx - pg.px * 4) * per, i0 = (3 - (cy - pg.py * 4)) * per;
    const wet = pg.wf && (pg.water_chunks || []).some(q => q[0] === cx && q[1] === cy);
    let lvl = -1e9;
    const wper = Math.round(CS / (pg.water ? pg.water.res : 8)), wi0 = (3 - (cy - pg.py * 4)) * wper, wj0 = (cx - pg.px * 4) * wper;
    if (wet) { lvl = 1e9; for (let i = 0; i <= wper; i++) for (let j = 0; j <= wper; j++) lvl = Math.min(lvl, pg.wf[(wi0 + i) * pg.water.n + wj0 + j]); }
    groundPatch(pg.hf, n, pg.height.res, pg.x0, pg.y0 + pg.size, i0, j0, per, groundMat(ct, pg.x0, pg.y0, pg.size, pg.ground.n, lvl), 6);
    if (wet) await waterGrid(pg.wf, pg.water.n, pg.water.res, pg.x0, pg.y0 + pg.size, wi0, wj0, wper, ct, pg.x0, pg.y0, pg.size, pg.ground.n, (pg.water_flow || {})[`${cx},${cy}`]);
  }
}

// ---------------- far terrain: whole area, coloured from the pack's ground textures by tag
{
  const F = R.far, fh = await BIN(`${ROUTE}/${F.file}`);
  const pal = TAGS.map((t, k) => { const d = atlasCv.getContext('2d').getImageData(k * CELL, 0, CELL, CELL).data; let r = 0, g = 0, bl = 0;
    for (let i = 0; i < d.length; i += 4) { r += d[i]; g += d[i + 1]; bl += d[i + 2]; } const n = d.length / 4; return new THREE.Color().setRGB(r / n / 255, g / n / 255, bl / n / 255, THREE.SRGBColorSpace); });
  let fc = null, fcn = 0, fcw = 0;
  if (F.ground) { const im = await IMG(`${ROUTE}/${F.ground.file}`); const cv = document.createElement('canvas'); cv.width = im.width; cv.height = im.height;
    const cx = cv.getContext('2d'); cx.drawImage(im, 0, 0); fc = cx.getImageData(0, 0, im.width, im.height).data; fcw = im.width; fcn = im.height; }
  const st = F.nx * F.ny > 400000 ? 2 : 1, nx = Math.floor((F.nx - 1) / st) + 1, ny = Math.floor((F.ny - 1) / st) + 1;
  const g = new THREE.PlaneGeometry(F.res * st * (nx - 1), F.res * st * (ny - 1), nx - 1, ny - 1); g.rotateX(-Math.PI / 2);
  g.translate(F.x0 + F.res * st * (nx - 1) / 2, 0, -(F.y1 - F.res * st * (ny - 1) / 2));
  const p = g.attributes.position, col = [];
  const snowC = new THREE.Color('#f2f4f8');
  for (let i = 0; i < ny; i++) for (let j = 0; j < nx; j++) {
    const k = i * nx + j, h = F.base + fh[(i * st) * F.nx + j * st] * F.scale;
    const x = F.x0 + j * st * F.res, y = F.y1 - i * st * F.res;
    p.setY(k, F.ground ? h : (CH.has(`${Math.floor(x / CS)},${Math.floor(y / CS)}`) ? h - 8 : h - 0.5));
    let c;
    if (fc) { const u = Math.min(fcw - 1, Math.floor((x - F.x0) / F.ground.res)), v = Math.min(fcn - 1, Math.floor((F.y1 - y) / F.ground.res));
      c = pal[fc[(v * fcw + u) * 4]] || pal[TAGS.indexOf('rural')]; c = c.clone(); }
    else c = h <= 0.5 ? new THREE.Color('#4f86b8') : new THREE.Color('#7da34f');
    if (h > 2700 && TAGS[fc ? fc[(Math.min(fcn - 1, Math.floor((F.y1 - y) / F.ground.res)) * fcw + Math.min(fcw - 1, Math.floor((x - F.x0) / F.ground.res))) * 4] : 0] !== 'water') c.lerp(snowC, 0.7);
    c.offsetHSL(0, 0, Math.sin(x * 0.013) * Math.cos(y * 0.011) * 0.04); col.push(c.r, c.g, c.b);
  }
  g.setAttribute('color', new THREE.Float32BufferAttribute(col, 3)); g.computeVertexNormals();
  const fm = new THREE.Mesh(g, new THREE.MeshLambertMaterial({ vertexColors: true })); fm.receiveShadow = true; scene.add(fm);
}

// ---------------- buildings
{
  const fac = near(new THREE.Texture(await IMG(`${MAT}/${PK.buildings.facades}`))); fac.needsUpdate = true;
  const roofT = near(new THREE.Texture(await IMG(`${MAT}/${PK.buildings.roofs[0]}`))); roofT.needsUpdate = true; roofT.wrapS = roofT.wrapT = THREE.RepeatWrapping;
  const B = PK.buildings, NS = B.styles || 6, tints = B.roof_tints || [[1, 1, 1]];
  const wallPos = [], wallUV = [], roofPos = [], roofUV = [], roofCol = [];
  const allB = [];
  for (const c of CH.values()) for (const b of c.buildings) allB.push(b);
  for (const pg of MID) for (const [x, y, L1, L2, ang, h, base] of pg.buildings) {
    const a = ang * Math.PI / 180, ux = Math.cos(a) * L1 / 2, uy = Math.sin(a) * L1 / 2, vx = -Math.sin(a) * L2 / 2, vy = Math.cos(a) * L2 / 2;
    allB.push({ p: [[x - ux - vx, y - uy - vy], [x + ux - vx, y + uy - vy], [x + ux + vx, y + uy + vy], [x - ux + vx, y - uy + vy]], h, base, v: Math.abs(Math.round(x * 7 + y * 13)) % 1000 });
  }
  for (const b of allB) {
    let p = b.p; if (p.length < 3) continue;
    let a = 0; for (let k = 0; k < p.length; k++) { const q = p[(k + 1) % p.length]; a += p[k][0] * q[1] - q[0] * p[k][1]; }
    if (a < 0) p = p.slice().reverse();
    const z0 = b.base, z1 = b.base + Math.max(3, b.h), st = b.v % NS;
    for (let k = 0; k < p.length; k++) {
      const A = p[k], Bq = p[(k + 1) % p.length], L = Math.hypot(Bq[0] - A[0], Bq[1] - A[1]); if (L < 0.3) continue;
      const nb = Math.max(1, Math.round(L / (B.bay_metres || 2.9)));
      const quad = (za, zb, vb, row) => { const P = [V(A[0], A[1], za), V(Bq[0], Bq[1], za), V(Bq[0], Bq[1], zb), V(A[0], A[1], zb)];
        const U = [[0, 0], [nb, 0], [nb, vb], [0, vb]];
        for (const i of [0, 1, 2, 0, 2, 3]) { wallPos.push(P[i].x, P[i].y, P[i].z); wallUV.push(U[i][0], U[i][1], st, row); } };
      const zg = Math.min(z1, z0 + (B.ground_floor_metres || 4.2));
      quad(z0, zg, 1, 1); if (z1 > zg + 0.5) quad(zg, z1, Math.max(1, Math.round((z1 - zg) / (B.floor_metres || 3.2))), 0);
    }
    let tri; try { tri = THREE.ShapeUtils.triangulateShape(p.map(q => new THREE.Vector2(q[0], q[1])), []); } catch (e) { continue; }
    const rc = tints[b.v % tints.length];
    for (const t of tri) for (const i of t) { const v = V(p[i][0], p[i][1], z1); roofPos.push(v.x, v.y, v.z); roofUV.push(p[i][0] / 4, p[i][1] / 4); roofCol.push(...rc); }
  }
  const wg = new THREE.BufferGeometry(); wg.setAttribute('position', new THREE.Float32BufferAttribute(wallPos, 3)); wg.setAttribute('uv4', new THREE.Float32BufferAttribute(wallUV, 4)); wg.computeVertexNormals();
  const wm = new THREE.MeshLambertMaterial({ map: fac });
  wm.onBeforeCompile = (sh) => {
    sh.vertexShader = sh.vertexShader.replace('#include <common>', '#include <common>\nattribute vec4 uv4; varying vec4 vF;').replace('#include <uv_vertex>', '#include <uv_vertex>\nvF = uv4;');
    sh.fragmentShader = sh.fragmentShader.replace('#include <common>', '#include <common>\nvarying vec4 vF;')
      .replace('#include <map_fragment>', `vec2 f = fract(vF.xy); f = floor(f*vec2(16.0,20.0))/vec2(16.0,20.0)+vec2(0.5/16.0,0.5/20.0);
        diffuseColor *= texture2D(map, vec2((vF.z + f.x)/${NS.toFixed(1)}, 1.0 - (vF.w*20.0 + (1.0-f.y)*20.0)/40.0));`);
  };
  const wmesh = new THREE.Mesh(wg, wm); wmesh.castShadow = true; wmesh.receiveShadow = Q.get('wallshadow') !== '0'; scene.add(wmesh);
  const rg = new THREE.BufferGeometry(); rg.setAttribute('position', new THREE.Float32BufferAttribute(roofPos, 3)); rg.setAttribute('uv', new THREE.Float32BufferAttribute(roofUV, 2)); rg.setAttribute('color', new THREE.Float32BufferAttribute(roofCol, 3)); rg.computeVertexNormals();
  const rm = new THREE.Mesh(rg, new THREE.MeshLambertMaterial({ map: roofT, vertexColors: true, side: THREE.DoubleSide })); rm.castShadow = rm.receiveShadow = true; scene.add(rm);
}

// ---------------- bridges
{
  const groups = {}, side = [];
  for (const b of BR) {
    const p = b.p, n = p.length; if (n < 2) continue;
    if (Math.hypot(p[0][0] - RP.x, p[0][1] - RP.y) > NEED + 600) continue;
    const L = [], Rr = [], along = [0];
    for (let k = 0; k < n; k++) { const a = p[Math.max(0, k - 1)], c = p[Math.min(n - 1, k + 1)]; let dx = c[0] - a[0], dy = c[1] - a[1]; const l = Math.hypot(dx, dy) || 1; dx /= l; dy /= l;
      L.push([p[k][0] - dy * b.w / 2, p[k][1] + dx * b.w / 2]); Rr.push([p[k][0] + dy * b.w / 2, p[k][1] - dx * b.w / 2]); if (k) along.push(along[k - 1] + Math.hypot(p[k][0] - p[k - 1][0], p[k][1] - p[k - 1][1])); }
    const top = [], tuv = [], sk = [];
    for (let k = 0; k < n - 1; k++) {
      const z0 = b.pz[k], z1 = b.pz[k + 1];
      const q = [V(L[k][0], L[k][1], z0), V(Rr[k][0], Rr[k][1], z0), V(Rr[k + 1][0], Rr[k + 1][1], z1), V(L[k + 1][0], L[k + 1][1], z1)];
      const u = [[along[k] / tileM, 0], [along[k] / tileM, b.w / tileM], [along[k + 1] / tileM, b.w / tileM], [along[k + 1] / tileM, 0]];
      for (const i of [0, 2, 1, 0, 3, 2]) { top.push(q[i].x, q[i].y, q[i].z); tuv.push(u[i][0], u[i][1]); }
      for (const [A, Bq, za, zb] of [[L[k], L[k + 1], z0, z1], [Rr[k + 1], Rr[k], z1, z0]]) {
        const s4 = [V(A[0], A[1], za), V(Bq[0], Bq[1], zb), V(Bq[0], Bq[1], zb - 1.6), V(A[0], A[1], za - 1.6)];
        for (const i of [0, 1, 2, 0, 2, 3]) sk.push(s4[i].x, s4[i].y, s4[i].z); }
    }
    const g = new THREE.BufferGeometry(); g.setAttribute('position', new THREE.Float32BufferAttribute(top, 3)); g.setAttribute('uv', new THREE.Float32BufferAttribute(tuv, 2)); g.computeVertexNormals();
    if (g.attributes.normal.getY(0) < 0) { const ps = g.attributes.position.array, us = g.attributes.uv.array;
      for (let i = 0; i < ps.length; i += 9) for (let c = 0; c < 3; c++) { const t = ps[i + 3 + c]; ps[i + 3 + c] = ps[i + 6 + c]; ps[i + 6 + c] = t; }
      for (let i = 0; i < us.length; i += 6) for (let c = 0; c < 2; c++) { const t = us[i + 2 + c]; us[i + 2 + c] = us[i + 4 + c]; us[i + 4 + c] = t; } g.computeVertexNormals(); }
    (groups[b.tag] = groups[b.tag] || []).push(g);
    const s2 = new THREE.BufferGeometry(); s2.setAttribute('position', new THREE.Float32BufferAttribute(sk, 3)); s2.computeVertexNormals(); side.push(s2);
  }
  for (const tag in groups) {
    const t = near(new THREE.Texture(await IMG(`${MAT}/${groundOf(tag)[0]}`))); t.needsUpdate = true; t.wrapS = t.wrapT = THREE.RepeatWrapping;
    const m = new THREE.Mesh(mergeGeometries(groups[tag]), new THREE.MeshLambertMaterial({ map: t, side: THREE.DoubleSide, polygonOffset: true, polygonOffsetFactor: tag === 'asphalt' ? -1 : -2, polygonOffsetUnits: tag === 'asphalt' ? -1 : -2 }));
    m.castShadow = m.receiveShadow = true; scene.add(m);
  }
  if (side.length) { const m = new THREE.Mesh(mergeGeometries(side), new THREE.MeshLambertMaterial({ color: (PK.bridge || {}).side || '#b9a88f', side: THREE.DoubleSide })); m.castShadow = true; scene.add(m); }
}

// ---------------- trees and props as camera-facing sprites (built after the camera is placed)
const spriteCache = new Map();
async function spriteTex(path) { if (!spriteCache.has(path)) { const im = await IMG(`${MAT}/${path}`); spriteCache.set(path, { im }); } return spriteCache.get(path); }
async function addSprites(cam) {
  const items = [];  // [path, x, y, z, height]
  for (const c of CH.values()) {
    for (const t of c.trees) { const tk = treesOf(t.kind); const sp = tk.sprites; if (!sp || !sp.length) continue;
      const [h0, h1] = tk.height || [10, 16]; items.push([sp[t.v % sp.length], t.x, t.y, t.z, (h0 + (h1 - h0) * ((t.v * 7) % 100) / 100) * t.s]); }
    // props per ground tag, deterministic per chunk
    const props = Object.assign({}, PK.props || {}, seasonal.props || {}); /* a season may replace a tag props */ const cv = document.createElement('canvas'); cv.width = cv.height = c.ground.n; const cx = cv.getContext('2d'); cx.drawImage(c.cls, 0, 0);
    const px = cx.getImageData(0, 0, c.ground.n, c.ground.n).data;
    let seed = (c.cx * 73856093) ^ (c.cy * 19349663); const rnd = () => ((seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff);
    for (const [tag, list] of Object.entries(props)) { const tid = TAGS.indexOf(tag); if (tid < 0) continue;
      for (const pr of list) { if (!pr.sprites || !pr.sprites.length) continue; const tries = Math.round(CS * CS / 100 * pr.density);
        for (let k = 0; k < tries; k++) { const u = rnd(), v = rnd(); const i = Math.floor(v * c.ground.n), j = Math.floor(u * c.ground.n);
          if (px[(i * c.ground.n + j) * 4] !== tid) continue;
          const x = c.x0 + u * CS, y = c.y0 + CS - v * CS; if (Math.hypot(x - cam.position.x, -y - cam.position.z) > 220) continue;
          const z = hAt(x, y); if (z === null) continue; items.push([pr.sprites[k % pr.sprites.length], x, y, z, pr.size || 1]); } } }
  }
  for (const pg of MID) for (const [x, y, z, kind, v] of pg.trees) {
    if (Math.hypot(x - cam.position.x, -y - cam.position.z) > 2600) continue;
    const tk = treesOf(kind); const sp = tk.sprites; if (!sp || !sp.length) continue;
    const [h0, h1] = tk.height || [10, 16]; items.push([sp[v % sp.length], x, y, z, (h0 + (h1 - h0) * ((v * 7) % 100) / 100)]);
  }
  const byPath = new Map(); for (const it of items) { if (!byPath.has(it[0])) byPath.set(it[0], []); byPath.get(it[0]).push(it); }
  const d = new THREE.Vector3(); cam.getWorldDirection(d);
  for (const [path, list] of byPath) {
    const { im } = await spriteTex(path); const aspect = im.width / im.height;
    const pos = [], uv = [];
    for (const [, x, y, z, hgt] of list) {
      const wid = hgt * aspect; let dx = cam.position.x - x, dy = cam.position.z - (-y);
      if (cam.isOrthographicCamera) { dx = -d.x; dy = -d.z; }
      const l = Math.hypot(dx, dy) || 1, rx = -dy / l, rz = dx / l, cz = -y;
      const P = [[x - rx * wid / 2, z - 0.15, cz - rz * wid / 2], [x + rx * wid / 2, z - 0.15, cz + rz * wid / 2], [x + rx * wid / 2, z - 0.15 + hgt, cz + rz * wid / 2], [x - rx * wid / 2, z - 0.15 + hgt, cz - rz * wid / 2]];
      for (const i of [0, 1, 2, 0, 2, 3]) pos.push(...P[i]);
      uv.push(0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1);
    }
    const g = new THREE.BufferGeometry(); g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3)); g.setAttribute('uv', new THREE.Float32BufferAttribute(uv, 2));
    const nrm = new Float32Array(pos.length); for (let i = 1; i < nrm.length; i += 3) nrm[i] = 1; g.setAttribute('normal', new THREE.BufferAttribute(nrm, 3));
    const t = near(new THREE.Texture(im)); t.needsUpdate = true;
    const m = new THREE.Mesh(g, new THREE.MeshLambertMaterial({ map: t, alphaTest: 0.5, side: THREE.DoubleSide, color: new THREE.Color(1.3, 1.3, 1.22) }));
    m.castShadow = true; m.customDepthMaterial = new THREE.MeshDepthMaterial({ depthPacking: THREE.RGBADepthPacking, map: t, alphaTest: 0.5 }); scene.add(m);
  }
  log('sprites', items.length);
}

// ---------------- bike + rider
const bikeTex = near(new THREE.Texture(await IMG(`${MAT}/${PK.bikes.mtb.texture}`))); bikeTex.needsUpdate = true;
const fbx = await new FBXLoader().loadAsync('assets/bikes.fbx');
const parts = {}; fbx.traverse(o => { if (o.isMesh) parts[o.name] = o; }); fbx.updateMatrixWorld(true);
function boxLimb(a, b, w, d, color) { const len = a.distanceTo(b); const g = new THREE.BoxGeometry(w, len, d); g.translate(0, len / 2, 0);
  const m = new THREE.Mesh(g, new THREE.MeshLambertMaterial({ color })); m.position.copy(a); m.quaternion.setFromUnitVectors(new THREE.Vector3(0, 1, 0), b.clone().sub(a).normalize()); m.castShadow = true; return m; }
function ik2(root, target, l1, l2, hint) { const d = Math.min(target.distanceTo(root), l1 + l2 - 1e-4); const dir = target.clone().sub(root).normalize();
  const a = (l1 * l1 - l2 * l2 + d * d) / (2 * d), h = Math.sqrt(Math.max(0, l1 * l1 - a * a)); const side = hint.clone().sub(dir.clone().multiplyScalar(hint.dot(dir))).normalize();
  return root.clone().add(dir.multiplyScalar(a)).add(side.multiplyScalar(h)); }
function makeCyclist(crank = 0.6) {
  const g = new THREE.Group(), bike = new THREE.Group(), got = {};
  for (const n of ['Mountain Bike Body', 'Mountain Bike Front Wheel', 'Mountain Bike Rear Wheel', 'Mountain Bike Pedals', 'Mountain Bike Handle']) {
    const src = Object.values(parts).find(o => o.name.replace(/_/g, ' ').startsWith(n)); if (!src) continue;
    const m = new THREE.Mesh(src.geometry.clone().applyMatrix4(src.matrixWorld), new THREE.MeshLambertMaterial({ map: bikeTex })); m.castShadow = true; got[n] = m; bike.add(m); }
  const bbW = new THREE.Box3().setFromObject(got['Mountain Bike Rear Wheel']), k = 0.70 / (bbW.max.y - bbW.min.y);
  const cF = new THREE.Box3().setFromObject(got['Mountain Bike Front Wheel']).getCenter(new THREE.Vector3()), cR = bbW.getCenter(new THREE.Vector3()), all = new THREE.Box3().setFromObject(bike);
  bike.children.forEach(m => { m.geometry.translate(-cR.x, -all.min.y, -cR.z); m.geometry.scale(k, k, k); });
  const ang = Math.atan2(-(cF.z - cR.z), cF.x - cR.x); bike.children.forEach(m => m.geometry.rotateY(-ang));
  g.add(bike);
  const B = (n) => new THREE.Box3().setFromObject(got[n]); const ped = B('Mountain Bike Pedals'), hand = B('Mountain Bike Handle');
  const pos = got['Mountain Bike Body'].geometry.attributes.position; const pc = ped.getCenter(new THREE.Vector3());
  let top = -1e9; for (let i = 0; i < pos.count; i++) { const v = new THREE.Vector3().fromBufferAttribute(pos, i); if (v.x < pc.x + 0.05) top = Math.max(top, v.y); }
  let sx = 0, n = 0; for (let i = 0; i < pos.count; i++) { const v = new THREE.Vector3().fromBufferAttribute(pos, i); if (v.x < pc.x + 0.05 && v.y > top - 0.03) { sx += v.x; n++; } }
  const saddle = new THREE.Vector3(sx / n, top, 0), crankC = new THREE.Vector3(pc.x, pc.y, 0);
  const hp = got['Mountain Bike Handle'].geometry.attributes.position; let gl = null, gr = null;
  for (let i = 0; i < hp.count; i++) { const v = new THREE.Vector3().fromBufferAttribute(hp, i); if (!gl || v.z < gl.z) gl = v.clone(); if (!gr || v.z > gr.z) gr = v.clone(); }
  gl.y = gr.y = hand.max.y - 0.03; gl.z += 0.06; gr.z -= 0.06;
  const pm = got['Mountain Bike Pedals']; pm.geometry.translate(-crankC.x, -crankC.y, 0); pm.rotation.z = -crank; pm.position.set(crankC.x, crankC.y, 0);
  const CL = 0.17, PW = 0.14, pedR = new THREE.Vector3(crankC.x + Math.cos(-crank) * CL, crankC.y + Math.sin(-crank) * CL, PW), pedL = new THREE.Vector3(crankC.x - Math.cos(-crank) * CL, crankC.y - Math.sin(-crank) * CL, -PW);
  const RC = PK.rider || {}, skin = RC.skin || '#e3b48f', shorts = RC.shorts || '#1f1f24', jersey = RC.jersey || '#c8392f';
  const hipC = saddle.clone().add(new THREE.Vector3(0.02, 0.07, 0)), shoulderC = hipC.clone().add(new THREE.Vector3(0.36, 0.43, 0));
  const hide = (m) => { m.userData.hideFP = 1; return m; };
  g.add(hide(boxLimb(hipC, shoulderC, 0.22, 0.34, jersey)));
  const neck = shoulderC.clone().add(new THREE.Vector3(0.08, 0.10, 0));
  const head = hide(new THREE.Mesh(new THREE.BoxGeometry(0.22, 0.24, 0.2), new THREE.MeshLambertMaterial({ color: skin }))); head.position.copy(neck).add(new THREE.Vector3(0.03, 0.12, 0)); head.castShadow = true; g.add(head);
  const helmet = hide(new THREE.Mesh(new THREE.BoxGeometry(0.28, 0.13, 0.25), new THREE.MeshLambertMaterial({ color: RC.helmet || '#f2f2f2' }))); helmet.position.copy(head.position).add(new THREE.Vector3(-0.01, 0.13, 0)); helmet.castShadow = true; g.add(helmet);
  for (const s of [-1, 1]) {
    const hip = hipC.clone().add(new THREE.Vector3(0, 0, 0.1 * s)); const foot = (s > 0 ? pedR : pedL).clone().add(new THREE.Vector3(0, 0.05, 0)); foot.z = 0.12 * s;
    const knee = ik2(hip, foot, 0.46, 0.46, new THREE.Vector3(1, 0.3, 0.05 * s));
    g.add(hide(boxLimb(hip, knee, 0.13, 0.14, shorts)), hide(boxLimb(knee, foot, 0.11, 0.11, skin)));
    const sh = new THREE.Mesh(new THREE.BoxGeometry(0.22, 0.07, 0.1), new THREE.MeshLambertMaterial({ color: '#2a2a2a' })); sh.position.copy(foot).add(new THREE.Vector3(0.03, -0.02, 0)); g.add(hide(sh));
    const shoulder = shoulderC.clone().add(new THREE.Vector3(0, -0.03, 0.17 * s)), grip = (s > 0 ? gr : gl).clone();
    const elbow = ik2(shoulder, grip, 0.30, 0.30, new THREE.Vector3(-0.3, -1, 0.4 * s));
    g.add(hide(boxLimb(shoulder, elbow, 0.1, 0.1, jersey)), hide(boxLimb(elbow, grip, 0.07, 0.07, skin)));
    const hnd = new THREE.Mesh(new THREE.BoxGeometry(0.12, 0.09, 0.13), new THREE.MeshLambertMaterial({ color: '#1f1f24' })); hnd.position.copy(grip); g.add(hnd);
  }
  g.userData.eye = neck.clone().add(new THREE.Vector3(0.12, 0.14, 0));
  return g;
}

// ---------------- camera
const rider = makeCyclist(0.6);
const groundZ = (x, y) => { const h = hAt(x, y); return h === null ? RP.z : h; };
const rz = RP.bridge ? RP.z : Math.max(groundZ(RP.x, RP.y), RP.z - 0.3);
const isWater = R.activity === 'water';
const onBoat = isWater || RP.ferry;
const wl = (CH.get(`${Math.floor(RP.x / CS)},${Math.floor(RP.y / CS)}`) || {}).water_level ?? 0;
const riderZ = onBoat ? wl + 0.9 : (RP.bridge ? RP.z : groundZ(RP.x, RP.y));
rider.position.copy(V(RP.x, RP.y, riderZ)); rider.rotation.y = RP.hd; scene.add(rider);
if (onBoat) {   // stand-in boat until boat models exist in packs
  const boat = new THREE.Group();
  const hull = new THREE.Mesh(new THREE.BoxGeometry(isWater ? 4.5 : 9, 1.2, isWater ? 1.8 : 3.4), new THREE.MeshLambertMaterial({ color: '#f2efe6' }));
  hull.position.set(0.5, -0.5, 0); hull.castShadow = true; boat.add(hull);
  const stripe = new THREE.Mesh(new THREE.BoxGeometry(isWater ? 4.55 : 9.05, 0.25, isWater ? 1.85 : 3.45), new THREE.MeshLambertMaterial({ color: '#2d5f8a' }));
  stripe.position.set(0.5, -0.85, 0); boat.add(stripe);
  boat.position.copy(rider.position); boat.rotation.y = RP.hd; scene.add(boat);
}
const fwd = new THREE.Vector3(Math.cos(RP.hd), 0, -Math.sin(RP.hd));
const setSun = (c, span = 160) => { sun.position.copy(c).addScaledVector(SUN_DIR, 400); sun.target.position.copy(c); const sc = sun.shadow.camera; sc.left = sc.bottom = -span; sc.right = sc.top = span; sc.near = 1; sc.far = 1500; sc.updateProjectionMatrix(); };
let cam, vm = null;
const base = V(RP.x, RP.y, riderZ);
if (Q.get('cam')) {
  const [cx_, cy_, cz_] = Q.get('cam').split(',').map(Number), [lx, ly, lz] = (Q.get('look') || `${RP.x},${RP.y},${riderZ}`).split(',').map(Number);
  cam = new THREE.PerspectiveCamera(+Q.get('fov') || 60, RW / RH, 0.1, 12000);
  cam.position.copy(V(cx_, cy_, cz_)); cam.lookAt(V(lx, ly, lz)); setSun(V(lx, ly, lz), 120);
} else if (VIEW === 'iso') {
  const span = +Q.get('span') || 130;
  cam = new THREE.OrthographicCamera(-span / 2, span / 2, span / 2 * RH / RW, -span / 2 * RH / RW, -3000, 6000);
  const yaw = 3 * Math.PI / 4 + (+Q.get('yaw') || 0), el = Math.atan(0.5);
  cam.position.copy(base).add(new THREE.Vector3(Math.cos(yaw) * Math.cos(el), Math.sin(el), Math.sin(yaw) * Math.cos(el)).multiplyScalar(1500)); cam.lookAt(base); setSun(base, span);
} else if (VIEW === 'first') {
  cam = new THREE.PerspectiveCamera(80, RW / RH, 0.05, 12000);
  rider.traverse(o => { if (o.userData.hideFP) o.visible = false; });
  const eye = rider.localToWorld(rider.userData.eye.clone());
  cam.position.copy(eye).addScaledVector(fwd, -0.1); cam.lookAt(cam.position.clone().addScaledVector(fwd, 10).add(new THREE.Vector3(0, -1.2, 0)));
  rider.traverse(o => o.layers.set(1)); vm = cam.clone(); vm.layers.set(1);
  vm.position.copy(eye).addScaledVector(fwd, -0.55).add(new THREE.Vector3(0, 0.05, 0)); vm.lookAt(vm.position.clone().addScaledVector(fwd, 10).add(new THREE.Vector3(0, -4.8, 0)));
  setSun(base.clone().addScaledVector(fwd, 60));
} else {
  cam = new THREE.PerspectiveCamera(58, RW / RH, 0.1, 12000);
  const back = +Q.get('back') || 3.6, up = +Q.get('up') || 1.75;
  cam.position.copy(base).addScaledVector(fwd, -back).add(new THREE.Vector3(0, up, 0));
  const g2 = groundZ(RP.x - Math.cos(RP.hd) * back, RP.y - Math.sin(RP.hd) * back); if (cam.position.y < g2 + 1.2) cam.position.y = g2 + 1.2;
  cam.lookAt(base.clone().addScaledVector(fwd, 8).add(new THREE.Vector3(0, 1.1, 0))); setSun(base.clone().addScaledVector(fwd, 50));
}
await addSprites(cam);
if (!cam.isOrthographicCamera) window.__sky.position.copy(cam.position);
renderer.render(scene, cam);
if (vm) { renderer.autoClear = false; renderer.clearDepth(); scene.background = null; scene.fog = null; sun.layers.enable(1); hemi.layers.enable(1); renderer.render(scene, vm); }
window.__info = { s: S_AT, x: RP.x, y: RP.y, z: riderZ, season, chunks: CH.size };
window.__done = true; log('done', JSON.stringify(window.__info));
