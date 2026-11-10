// node treeshot.js <model.json> <texture dir> <out.png> <pixels per metre>
// Draws a 3D tree (trees3d.py's model: parts with v = x,y,z,nx,ny,nz,u,v and i) from the side, orthographic, at the
// pack's pixel size, lit like the game lights it (atlas/trees.lua), on a see-through background: the picture drawn
// for the tree away from the rider.
const { chromium } = require('playwright');
const fs = require('fs'), path = require('path');
(async () => {
  const [model, texdir, out, ppm] = process.argv.slice(2);
  const three = path.resolve(__dirname, '../gmodcheck/node_modules/three/build/three.module.js');
  const M = JSON.parse(fs.readFileSync(model));
  const tex = {};
  for (const p of M.parts) tex[p.tex] = 'data:image/png;base64,' + fs.readFileSync(path.join(texdir, p.file)).toString('base64');
  const html = `<!doctype html><html><body style="margin:0"><script type="importmap">{"imports":{"three":"file://${three}"}}</script>
<script type="module">
import * as THREE from 'three';
const M = ${JSON.stringify(M)}, TEX = ${JSON.stringify(tex)}, PPM = ${+ppm};
const SUN = [0.45, -0.35, 0.82]; const sl = Math.hypot(...SUN); for (let i = 0; i < 3; i++) SUN[i] /= sl;
let x0 = 1e9, x1 = -1e9, z1 = 0;
for (const p of M.parts) for (let i = 0; i < p.v.length; i += 8) { x0 = Math.min(x0, p.v[i]); x1 = Math.max(x1, p.v[i]); z1 = Math.max(z1, p.v[i + 2]); }
const half = Math.max(-x0, x1), W = Math.max(4, Math.round(2 * half * PPM)), H = Math.max(4, Math.round(z1 * PPM));
const r = new THREE.WebGLRenderer({ antialias: false, alpha: true, preserveDrawingBuffer: true }); r.setSize(W, H); r.setClearColor(0, 0);
document.body.appendChild(r.domElement);
const s = new THREE.Scene(), tl = new THREE.TextureLoader();
for (const p of M.parts) {
  const t = await new Promise(res => tl.load(TEX[p.tex], t => { t.magFilter = t.minFilter = THREE.NearestFilter; t.wrapS = t.wrapT = THREE.RepeatWrapping; t.flipY = false; t.colorSpace = THREE.SRGBColorSpace; res(t); }));
  const n = p.v.length / 8, pos = new Float32Array(n * 3), uv = new Float32Array(n * 2), col = new Float32Array(n * 3);
  for (let i = 0; i < n; i++) {
    const o = i * 8, vx = p.v[o], vy = p.v[o + 1], vz = p.v[o + 2], nx = p.v[o + 3], ny = p.v[o + 4], nz = p.v[o + 5];
    pos[i * 3] = vx; pos[i * 3 + 1] = vy; pos[i * 3 + 2] = vz; uv[i * 2] = p.v[o + 6]; uv[i * 2 + 1] = p.v[o + 7];
    const sun = Math.max(0, nx * SUN[0] + ny * SUN[1] + nz * SUN[2]);
    let light = p.leaf ? 0.50 + 0.28 * Math.min(1, vz / z1) + 0.12 * Math.min(1, Math.hypot(vx, vy) / (z1 * 0.35)) + 0.18 * sun : 0.55 + 0.30 * sun;
    light = Math.min(1.08, light) * 236 / 255;
    col[i * 3] = col[i * 3 + 1] = col[i * 3 + 2] = Math.pow(light, 2.2);
  }
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.BufferAttribute(pos, 3)); g.setAttribute('uv', new THREE.BufferAttribute(uv, 2)); g.setAttribute('color', new THREE.BufferAttribute(col, 3)); g.setIndex(p.i);
  s.add(new THREE.Mesh(g, new THREE.MeshBasicMaterial({ map: t, vertexColors: true, side: THREE.DoubleSide, alphaTest: 0.5 })));
}
// looking north, from the south
const cam = new THREE.OrthographicCamera(-W / 2 / PPM, W / 2 / PPM, H / PPM, 0, -100, 100);
cam.up.set(0, 0, 1); cam.position.set(0, -50, 0); cam.lookAt(0, 0, 0);
r.render(s, cam);
window.SIZE = [W, H, half * 2, z1];
window.IMG = r.domElement.toDataURL('image/png'); window.DONE = true;
</script></body></html>`;
  const tmp = path.resolve(out) + '.html'; fs.writeFileSync(tmp, html);
  const b = await chromium.launch({ args: ['--use-gl=swiftshader', '--enable-unsafe-swiftshader', '--allow-file-access-from-files'] });
  const pg = await b.newPage();
  pg.on('pageerror', e => console.log('PAGE ERROR', e.message));
  await pg.goto('file://' + tmp);
  await pg.waitForFunction(() => window.DONE === true, null, { timeout: 60000 });
  const [img, size] = await pg.evaluate(() => [window.IMG, window.SIZE]);
  fs.writeFileSync(out, Buffer.from(img.split(',')[1], 'base64'));
  fs.unlinkSync(tmp);
  console.log(JSON.stringify({ w: size[0], h: size[1], width_m: size[2], height_m: size[3] }));
  await b.close();
})();
