// node ride.js <capture prefix (absolute path)> <out dir> [from to]  - renders a ride capture (see ride.html)
const { chromium } = require('playwright');
const fs = require('fs');
(async () => {
  const [cap, out, from, to] = process.argv.slice(2);
  const port = process.env.VIEWER_PORT || 8125;
  fs.mkdirSync(out, { recursive: true });
  const b = await chromium.launch({ args: ['--use-gl=swiftshader', '--enable-unsafe-swiftshader'] });
  const p = await b.newPage({ viewport: { width: 640, height: 360 } });
  p.on('pageerror', e => console.log('PAGE ERROR', e.message)); p.on('console', m => { if (m.type() === 'error') console.log('console', m.text()); });
  let n = 0;
  await p.exposeFunction('save', (name, data) => { fs.writeFileSync(out + '/' + name, Buffer.from(data.split(',')[1], 'base64')); if (++n % 100 == 0) console.log(n, 'pictures'); });
  // the viewer server serves the whole file system (cd / && python3 -m http.server 8125 --bind 127.0.0.1)
  const here = __dirname, repo = require('path').resolve(here, '../..');
  await p.goto(`http://localhost:${port}${here}/ride.html?cap=${cap}&mat=${process.env.MAT || repo + '/packs/tinyatlas_pack_default/materials'}&from=${from || 0}&to=${to || 1e9}&px=${process.env.PX || 1}`);
  await p.waitForFunction(() => window.DONE === true, null, { timeout: 0, polling: 2000 });
  console.log('done', n, 'pictures');
  await b.close();
})();
