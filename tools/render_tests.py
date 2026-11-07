"""Render test views for every built route and make one contact sheet per route.
usage: render_tests.py ROUTE_ID [...]   (needs a local web server on :8124 serving the repo root, e.g. python3 -m http.server 8124)"""
import json, os, subprocess, sys
from PIL import Image, ImageDraw

BASE = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
PACK = '../../packs/tinyatlas_pack_default'


def views(rid):
    R = json.load(open(f'{BASE}/routes/{rid}/route.json'))
    L = R['distance_m']; picks = [('start', min(60, L * 0.02))]
    if R['climbs']:
        c = max(R['climbs'], key=lambda c: c['gain_m']); picks.append(('climb', (c['start_m'] + c['end_m']) / 2))
    picks += [('mid', L * 0.5), ('late', L * 0.8)]
    jobs = []
    for name, s in picks:
        jobs.append({'name': f'{rid}__{name}_third', 'q': f'route=../../routes/{rid}&pack={PACK}&s={s:.0f}&view=third'})
    jobs.append({'name': f'{rid}__mid_first', 'q': f'route=../../routes/{rid}&pack={PACK}&s={L * 0.5:.0f}&view=first'})
    jobs.append({'name': f'{rid}__mid_overview', 'q': f'route=../../routes/{rid}&pack={PACK}&s={L * 0.5:.0f}&view=third&back=220&up=140&midradius=6000'})
    jobs.append({'name': f'{rid}__start_iso', 'q': f'route=../../routes/{rid}&pack={PACK}&s={picks[0][1]:.0f}&view=iso&span=170', 'w': 960, 'h': 540})
    return R, jobs


for rid in sys.argv[1:]:
    R, jobs = views(rid)
    out = f'{BASE}/shots/test'
    r = subprocess.run(['node', 'shoot.js', json.dumps(jobs), out], cwd=f'{BASE}/tools/viewer', capture_output=True, text=True, timeout=1800)
    fails = [l for l in r.stdout.splitlines() if 'FAILED' in l or 'PAGEERR' in l]
    tiles = []
    for j in jobs:
        p = f'{out}/{j["name"]}.png'
        if os.path.exists(p):
            im = Image.open(p).convert('RGB'); tiles.append((j['name'].split('__')[1], im.resize((640, 360), Image.NEAREST)))
    sheet = Image.new('RGB', (1280, 360 * ((len(tiles) + 1) // 2) + 40), (20, 20, 24)); d = ImageDraw.Draw(sheet)
    d.text((10, 12), f"{R['name']}  |  {R['distance_m'] / 1000:.1f} km  +{R['gain_m']} m  |  {R['activity']}  |  bike: {R['recommended']}  |  "
                     f"surfaces: {R['surfaces_pct']}", fill=(230, 230, 230))
    for k, (lbl, im) in enumerate(tiles):
        x, y = (k % 2) * 640, 40 + (k // 2) * 360; sheet.paste(im, (x, y)); d.text((x + 8, y + 6), lbl, fill=(255, 255, 0))
    sheet.save(f'{BASE}/shots/sheet_{rid}.png')
    print(rid, len(tiles), 'views', 'FAIL: ' + '; '.join(fails) if fails else 'ok')
