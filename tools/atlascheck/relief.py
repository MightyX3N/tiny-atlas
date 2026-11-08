"""Shaded-relief pictures of built cells with heights (from game/tests/atlas/test_ground.lua RASTER_DIR dumps).
usage: relief.py DUMP_DIR OUT.png [px per cell] [tile x y to draw]"""
import sys, glob, os, math, collections
from PIL import Image, ImageDraw
COL = {'building': (184, 120, 104), 'road': (90, 90, 96), 'road_unpaved': (150, 130, 100), 'cycleway': (150, 80, 80),
       'path': (196, 170, 120), 'path_unpaved': (170, 140, 90), 'track': (160, 130, 90), 'rail': (120, 100, 110),
       'pier': (150, 140, 120), 'water': (70, 130, 200), 'sea': (60, 110, 190), 'stream': (80, 140, 210),
       'paved': (150, 150, 150), 'sand': (230, 210, 150), 'wetland': (110, 160, 140), 'wood': (50, 120, 60),
       'park': (120, 190, 100), 'grass': (140, 200, 110), 'pitch': (100, 180, 120), 'cemetery': (130, 170, 130),
       'farmland': (210, 200, 130), 'rock': (160, 150, 140), 'ice': (230, 240, 250), 'residential': (215, 205, 195),
       'commercial': (220, 195, 195), 'industrial': (200, 190, 210), 'ground': (200, 196, 170)}
dump, out = sys.argv[1], sys.argv[2]
px = int(sys.argv[3]) if len(sys.argv) > 3 else 256
sel = (int(sys.argv[4]), int(sys.argv[5])) if len(sys.argv) > 5 else None
tiles = collections.defaultdict(list)
for f in glob.glob(os.path.join(dump, '*.txt')):
    tx, ty, cx, cy = map(int, os.path.basename(f)[:-4].split('_'))
    if sel and (tx, ty) != sel: continue
    tiles[(tx, ty)].append((cx, cy, f))
(tx, ty), cells = sorted(tiles.items())[0]
im = Image.new('RGB', (8 * px, 8 * px), (255, 0, 255)); d = ImageDraw.Draw(im)
L = (-0.5, -0.6, 0.62)  # light from the north-west, above
ln = math.sqrt(sum(c * c for c in L)); L = tuple(c / ln for c in L)
for cx, cy, f in cells:
    lines = open(f).read().split('\n'); S, nt, mpu = lines[0].split(); S = int(S); mpu = float(mpu); k = px / S
    for ln_ in lines[1:]:
        if not ln_: continue
        p = ln_.split()
        v = [float(x) for x in p[:9]]; s = p[9]
        ax, ay, az, bx, by, bz, cxx, cyy, cz = v
        ux, uy, uz = (bx - ax) * mpu, -(by - ay) * mpu, bz - az
        vx, vy, vz = (cxx - ax) * mpu, -(cyy - ay) * mpu, cz - az
        nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
        n = math.sqrt(nx * nx + ny * ny + nz * nz) or 1
        if nz < 0: nx, ny, nz = -nx, -ny, -nz
        sh = max(0.25, (nx * L[0] + ny * L[1] + nz * L[2]) / n)
        c = COL.get(s, (255, 0, 255)); c = tuple(min(255, int(ch * (0.35 + 0.8 * sh))) for ch in c)
        if s in ('road', 'road_unpaved', 'cycleway') and nz > 0 and n > 0:
            area2 = nz                       # twice the horizontal area in m2
            slope = math.sqrt(nx * nx + ny * ny) / nz
            if area2 > 4 and slope > 0.30: c = (255, 0, 0)
        ox, oy = cx * px, cy * px
        d.polygon([(ox + ax * k, oy + ay * k), (ox + bx * k, oy + by * k), (ox + cxx * k, oy + cyy * k)], fill=c)
im.save(out); print(out, tx, ty)
