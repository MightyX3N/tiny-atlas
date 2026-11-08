"""Render dumped cell triangulations (from game/tests/atlas/test_cells.lua) into pictures.
usage: render_cells.py DUMP_DIR OUT_DIR [px per cell]
One picture per vector tile (8 x 8 cells), plus every cell alone at full size when px >= 512."""
import os, sys, glob, collections
from PIL import Image, ImageDraw
COL = {'building': (184, 120, 104), 'road': (90, 90, 96), 'path': (196, 170, 120), 'rail': (120, 100, 110),
       'pier': (150, 140, 120), 'water': (70, 130, 200), 'paved': (150, 150, 150), 'sand': (230, 210, 150),
       'wetland': (110, 160, 140), 'wood': (50, 120, 60), 'park': (120, 190, 100), 'grass': (140, 200, 110),
       'pitch': (100, 180, 120), 'cemetery': (130, 170, 130), 'farmland': (210, 200, 130), 'rock': (160, 150, 140),
       'ice': (230, 240, 250), 'residential': (215, 205, 195), 'commercial': (220, 195, 195),
       'industrial': (200, 190, 210), 'ground': (200, 196, 170)}
dump, out = sys.argv[1], sys.argv[2]
px = int(sys.argv[3]) if len(sys.argv) > 3 else 256
os.makedirs(out, exist_ok=True)
tiles = collections.defaultdict(list)
for f in glob.glob(os.path.join(dump, '*.txt')):
    tx, ty, cx, cy = map(int, os.path.basename(f)[:-4].split('_'))
    tiles[(tx, ty)].append((cx, cy, f))
for (tx, ty), cells in sorted(tiles.items()):
    im = Image.new('RGB', (8 * px, 8 * px), (255, 0, 255))
    d = ImageDraw.Draw(im)
    for cx, cy, f in cells:
        lines = open(f).read().split('\n')
        S = int(lines[0].split()[0]); k = px / S
        ox, oy = cx * px, cy * px
        tris = []
        for ln in lines[1:]:
            if not ln: continue
            p = ln.split()
            xy = [float(v) for v in p[:6]]
            pts = [(ox + xy[0] * k, oy + xy[1] * k), (ox + xy[2] * k, oy + xy[3] * k), (ox + xy[4] * k, oy + xy[5] * k)]
            tris.append((pts, p[6], p[7]))
            d.polygon(pts, fill=COL.get(p[6], (255, 0, 255)))
        for pts, s, c in tris:
            for i in range(3):
                if c[i] == '1':
                    d.line([pts[i], pts[(i + 1) % 3]], fill=(40, 40, 40), width=1)
    im.save(os.path.join(out, f'tile_{tx}_{ty}.png'))
    print(os.path.join(out, f'tile_{tx}_{ty}.png'))
