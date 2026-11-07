// node shoot.js '[{"name":..,"q":"route=..&pack=..&s=.."}]' outdir
const { chromium } = require('playwright');
(async () => {
  const jobs = JSON.parse(process.argv[2]); const out = process.argv[3] || 'shots';
  require('fs').mkdirSync(out, { recursive: true });
  const b = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'] });
  for (const j of jobs) {
    const [w, h] = [j.w || 480, j.h || 270];
    const p = await b.newPage({ viewport: { width: w, height: h } });
    let err = null;
    p.on('console', m => { const t = m.text(); if (t.startsWith('[pv]') || m.type() === 'error') { if (m.type() === 'error' && !/404|Failed to load resource/.test(t)) err = t; console.log(j.name, t.slice(0, 300)); } });
    p.on('pageerror', e => { err = e.message; console.log(j.name, 'PAGEERR', e.message); });
    try {
      await p.goto(`http://localhost:${process.env.VIEWER_PORT || 8124}/tools/viewer/viewer.html?${j.q}&w=${w}&h=${h}`);
      await p.waitForFunction('window.__done===true', null, { timeout: 300000 });
      await p.locator('canvas').screenshot({ path: `${out}/${j.name}.png` });
      console.log(j.name, 'ok');
    } catch (e) { console.log(j.name, 'FAILED', err || e.message); }
    await p.close();
  }
  await b.close();
})();
