// node shoot.js capture.bin out.png [extra query]  - renders a captured GMod frame (server must serve the repo root)
const { chromium } = require('playwright');
(async () => {
  const [cap, out, extra] = process.argv.slice(2);
  const port = process.env.VIEWER_PORT || 8125;
  const b = await chromium.launch({ args: ['--use-gl=swiftshader', '--enable-unsafe-swiftshader'] });
  const p = await b.newPage({ viewport: { width: 1280, height: 720 } });
  p.on('pageerror', e => console.log('PAGE ERROR', e.message)); p.on('console', m => { if (m.type() === 'error') console.log('console', m.text()); });
  await p.goto(`http://localhost:${port}/tools/gmodcheck/view.html?cap=${cap}&mat=/packs/tinyatlas_pack_default/materials&${extra || ''}`);
  await p.waitForFunction(() => window.DONE === true, null, { timeout: 120000 });
  await p.screenshot({ path: out });
  await b.close();
})();
