"""Tiny Atlas logo: drawn pixel by pixel on a true grid with a fixed palette (no smoothing, no AI).
Real continents from a world land mask in an orthographic view, lit from the upper left; brass ring,
wooden stand, a route line across Europe ending at a pin. Outputs 1x masters and nearest-neighbour
upscales."""
import math, os, sys
import numpy as np
from PIL import Image
from global_land_mask import globe

OUT = sys.argv[1] if len(sys.argv) > 1 else 'out'
os.makedirs(OUT, exist_ok=True)

H = lambda s: tuple(int(s[i:i + 2], 16) for i in (1, 3, 5)) + (255,)
PAL = {
    'outline': H('#10203a'), 'shadow': H('#0b1528'),
    'o0': H('#173f7a'), 'o1': H('#1f58a8'), 'o2': H('#2e76d0'), 'o3': H('#5aa6ec'), 'oh': H('#a9dbff'),
    'l0': H('#2a6b33'), 'l1': H('#428f37'), 'l2': H('#6cb544'), 'l3': H('#9ad65c'),
    's0': H('#a9803c'), 's1': H('#d2ab5f'), 's2': H('#ead08a'),
    'i0': H('#a9c3d6'), 'i1': H('#e8f2f8'),
    'b0': H('#6b3f10'), 'b1': H('#a8701f'), 'b2': H('#dba63a'), 'b3': H('#f7dc7a'),
    'w0': H('#3b2010'), 'w1': H('#5f351a'), 'w2': H('#874b25'), 'w3': H('#ad6c3a'),
    'r0': H('#a3171c'), 'r1': H('#e8402e'), 'r2': H('#ffd36a'), 'white': H('#fffbe8'),
}
N = 64
img = np.zeros((N, N, 4), np.uint8)


def put(x, y, c):
    if 0 <= x < N and 0 <= y < N: img[y, x] = PAL[c]


CX, CY, R = 31, 27, 20
LON0, LAT0, TILT = 12.0, 28.0, math.radians(-18)    # Europe/Africa facing, axis tilted like a desk globe
L = np.array([-0.55, 0.62, 0.56]); L /= np.linalg.norm(L)


def to_lonlat(nx, ny, nz):
    # undo the axis tilt (rotate around the view axis), then the view rotation to (LON0, LAT0)
    x = nx * math.cos(TILT) - ny * math.sin(TILT); y = nx * math.sin(TILT) + ny * math.cos(TILT); z = nz
    la0, lo0 = math.radians(LAT0), math.radians(LON0)
    # orthographic inverse
    rho = math.hypot(x, y)
    if rho < 1e-9: return LON0, LAT0
    c = math.asin(min(1, rho))
    lat = math.asin(math.cos(c) * math.sin(la0) + y * math.sin(c) * math.cos(la0) / rho)
    lon = lo0 + math.atan2(x * math.sin(c), rho * math.cos(la0) * math.cos(c) - y * math.sin(la0) * math.sin(c))
    return (math.degrees(lon) + 540) % 360 - 180, math.degrees(lat)


def project(lon, lat):
    la0, lo0 = math.radians(LAT0), math.radians(LON0); la, lo = math.radians(lat), math.radians(lon)
    cosc = math.sin(la0) * math.sin(la) + math.cos(la0) * math.cos(la) * math.cos(lo - lo0)
    x = math.cos(la) * math.sin(lo - lo0); y = math.cos(la0) * math.sin(la) - math.sin(la0) * math.cos(la) * math.cos(lo - lo0)
    xr = x * math.cos(-TILT) - y * math.sin(-TILT); yr = x * math.sin(-TILT) + y * math.cos(-TILT)
    return CX + xr * R, CY - yr * R, cosc > 0


# ---- shadow under the globe on nothing (soft pixel ellipse is skipped: keep it clean)
# ---- the globe
inside = np.zeros((N, N), bool)
for py in range(N):
    for px in range(N):
        dx, dy = (px + 0.5 - CX) / R, (CY - (py + 0.5)) / R
        r2 = dx * dx + dy * dy
        if r2 > 1: continue
        inside[py, px] = True
        nz = math.sqrt(1 - r2)
        lon, lat = to_lonlat(dx, dy, nz)
        land = bool(globe.is_land(np.array([lat]), np.array([lon]))[0])
        lit = float(np.dot([dx, dy, nz], L))
        band = 3 if lit > 0.72 else 2 if lit > 0.38 else 1 if lit > 0.05 else 0
        if abs(lat) > 70: c = ['i0', 'i0', 'i1', 'i1'][band] if land or abs(lat) > 76 else ['o0', 'o1', 'o2', 'o3'][band]
        elif land:
            desert = 14 < lat < 31 and -18 < lon < 58 or (-30 < lat < -18 and 15 < lon < 30) or (18 < lat < 33 and 40 < lon < 60)
            c = (['s0', 's0', 's1', 's2'] if desert else ['l0', 'l1', 'l2', 'l3'])[band]
        else:
            c = ['o0', 'o1', 'o2', 'o3'][band]
        put(px, py, c)
# specular glint (2-3 pixels), upper left
for gx, gy in ((-0.48, 0.52), (-0.42, 0.56), (-0.52, 0.46)):
    put(int(CX + gx * R), int(CY - gy * R), 'oh')
# route across Europe to a pin (Lisbon -> Pyrenees -> Lyon -> Alps -> Copenhagen)
route = [(-9.1, 38.7), (-3.7, 40.4), (1.0, 42.6), (4.8, 45.8), (8.5, 47.4), (10.0, 51.0), (12.6, 55.7)]
pts = []
for (a, b), (c_, d) in zip(route, route[1:]):
    for t in np.linspace(0, 1, 12, endpoint=False):
        x, y, vis = project(a + (c_ - a) * t, b + (d - b) * t)
        if vis: pts.append((int(x), int(y)))
seen = []
for k, p in enumerate(pts):
    if p in seen: continue
    seen.append(p)
for k, (x, y) in enumerate(seen):
    put(x, y, 'r2' if k % 3 == 2 else 'r1')
ex, ey, _ = project(*route[-1])
ex, ey = int(ex), int(ey)
for (dx, dy, c) in ((0, -1, 'r1'), (0, -2, 'r1'), (-1, -3, 'r1'), (0, -3, 'r1'), (1, -3, 'r0'), (0, -4, 'r1'), (0, -3, 'white'), (0, 0, 'r0')):
    put(ex + dx, ey + dy - 1, c)
# outline round the globe
out = np.zeros_like(inside)
for py in range(N):
    for px in range(N):
        if inside[py, px]: continue
        if any(0 <= px + dx < N and 0 <= py + dy < N and inside[py + dy, px + dx] for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))):
            out[py, px] = True
for py, px in zip(*np.nonzero(out)): put(px, py, 'outline')

# ---- brass meridian ring: right half of a ring, tilted with the axis
RR = R + 3.2
ring = {}
for a in np.linspace(-math.pi * 0.62, math.pi * 0.62, 400):
    x = math.cos(a) * RR; y = math.sin(a) * RR
    xr = x * math.cos(-TILT) - y * math.sin(-TILT); yr = x * math.sin(-TILT) + y * math.cos(-TILT)
    px, py = int(round(CX + xr)), int(round(CY - yr))
    ring[(px, py)] = a
for (px, py), a in ring.items():
    if 0 <= py < N and 0 <= px < N and not inside[py, px]:
        shade = 'b3' if a > 0.6 else 'b2' if a > -0.3 else 'b1'
        put(px, py, shade)
        put(px + 1, py, 'b1' if shade != 'b1' else 'b0')
# axis pivots (top and bottom of the tilted axis)
for s in (1, -1):
    x = 0; y = s * (R + 1.5)
    xr = x * math.cos(-TILT) - y * math.sin(-TILT); yr = x * math.sin(-TILT) + y * math.cos(-TILT)
    px, py = int(round(CX + xr)), int(round(CY - yr))
    for dx, dy, c in ((0, 0, 'b2'), (1, 0, 'b1'), (0, 1, 'b1'), (1, 1, 'b0'), (-1, 0, 'b3')):
        put(px + dx, py + dy, c)

# ---- stand: brass collar, pole, wooden stepped base
bottom = max(py for (px, py) in ring) if ring else CY + R
for y in range(CY + R + 2, 54):
    put(CX - 1, y, 'b1'); put(CX, y, 'b2'); put(CX + 1, y, 'b1')
for x in range(CX - 3, CX + 4): put(x, 52, 'b3' if x < CX else 'b2'); put(x, 53, 'b1')
for (y, half, top, mid, low) in ((54, 9, 'w3', 'w2', 'w1'), (55, 11, 'w3', 'w2', 'w1'), (56, 11, 'w2', 'w2', 'w1'),
                                 (57, 14, 'w3', 'w2', 'w1'), (58, 14, 'w2', 'w1', 'w1'), (59, 14, 'w1', 'w1', 'w0')):
    for x in range(CX - half, CX + half + 1):
        c = top if x < CX - half + 3 else (low if x > CX + half - 3 else mid)
        put(x, y, c)
for x in range(CX - 15, CX + 16):
    put(x, 60, 'w0')
for y in range(54, 61):        # outline the base ends
    pass

icon = Image.fromarray(img, 'RGBA')
icon.save(os.path.join(OUT, 'tiny_atlas_icon_64.png'))
for s in (2, 4, 8):
    icon.resize((N * s, N * s), Image.NEAREST).save(os.path.join(OUT, f'tiny_atlas_icon_{N * s}.png'))

# ---- wordmark: a chunky 6x8 pixel font, cream with a dark outline and a blue drop shadow
GLYPH = {
    'T': ["######", "######", "..##..", "..##..", "..##..", "..##..", "..##..", "..##.."],
    'I': ["######", "######", "..##..", "..##..", "..##..", "..##..", "######", "######"],
    'N': ["##..##", "###.##", "######", "######", "##.###", "##..##", "##..##", "##..##"],
    'Y': ["##..##", "##..##", "##..##", ".####.", "..##..", "..##..", "..##..", "..##.."],
    'A': [".####.", "######", "##..##", "##..##", "######", "######", "##..##", "##..##"],
    'L': ["##....", "##....", "##....", "##....", "##....", "##....", "######", "######"],
    'S': [".#####", "######", "##....", "#####.", ".#####", "....##", "######", "#####."],
    ' ': ["...", "...", "...", "...", "...", "...", "...", "..."],
}


def wordmark(text):
    w = sum(len(GLYPH[c][0]) + 1 for c in text) + 4; h = 8 + 6
    m = np.zeros((h, w), np.uint8)        # 1 = letter
    x = 2
    for c in text:
        g = GLYPH[c]
        for j, row in enumerate(g):
            for i, ch in enumerate(row):
                if ch == '#': m[2 + j, x + i] = 1
        x += len(g[0]) + 1
    out = np.zeros((h, w, 4), np.uint8)
    for y in range(h):
        for x in range(w):
            if m[y, x]:
                out[y, x] = PAL['white'] if y < 2 + 4 else H('#ffe6a8')
            elif any(0 <= y + dy < h and 0 <= x + dx < w and m[y + dy, x + dx] for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, -1), (1, -1), (-1, 1))):
                out[y, x] = PAL['outline']
    # drop shadow one pixel down-right where empty
    sh = np.zeros_like(out)
    for y in range(h - 1):
        for x in range(w - 1):
            if out[y, x, 3] and not out[y + 1, x + 1, 3]: sh[y + 1, x + 1] = PAL['o1']
    sh[out[..., 3] > 0] = out[out[..., 3] > 0]
    return Image.fromarray(sh, 'RGBA')


wm = wordmark('TINY ATLAS')
wm.save(os.path.join(OUT, 'tiny_atlas_wordmark_1x.png'))
wm.resize((wm.width * 6, wm.height * 6), Image.NEAREST).save(os.path.join(OUT, 'tiny_atlas_wordmark_6x.png'))

# ---- lockups: icon + name side by side, and stacked
side = Image.new('RGBA', (N + wm.width + 2, N), (0, 0, 0, 0)); side.alpha_composite(icon, (0, 0)); side.alpha_composite(wm, (N + 1, N // 2 - wm.height // 2))
side.resize((side.width * 6, side.height * 6), Image.NEAREST).save(os.path.join(OUT, 'tiny_atlas_logo_wide_6x.png'))
stack = Image.new('RGBA', (max(N, wm.width) + 4, N + wm.height + 2), (0, 0, 0, 0))
stack.alpha_composite(icon, ((stack.width - N) // 2, 0)); stack.alpha_composite(wm, ((stack.width - wm.width) // 2, N + 1))
stack.resize((stack.width * 6, stack.height * 6), Image.NEAREST).save(os.path.join(OUT, 'tiny_atlas_logo_stacked_6x.png'))
print('ok', OUT)
