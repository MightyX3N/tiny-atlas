"""Street trees for towns. Vector tiles don't carry individual trees, so plant rows along town streets and
water-side quays: on pavement or grass, never on the road, never inside a building. Deterministic."""
import math, zlib
import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage
from .tags import ID

TREE_ROADS = {'primary': .55, 'secondary': .55, 'tertiary': .45, 'residential': .35, 'living_street': .3, 'pedestrian': .35}
OK_GROUND = {ID['paving'], ID['urban'], ID['grass'], ID['rural']}


def street_trees(W, key, cls, ox, oy, size, cres, buildings):
    if cls.mean() == 0: return []
    n = cls.shape[0]
    bm = Image.new('L', (n, n), 0); d = ImageDraw.Draw(bm)
    for b in buildings:
        d.polygon([((x - ox) / cres, (oy + size - y) / cres) for x, y in b['p']], fill=1)
    blocked = ndimage.binary_dilation(np.array(bm) > 0, iterations=4)      # keep 2 m from walls
    road_px = np.isin(cls, [ID['asphalt'], ID['cycleway'], ID['cobble'], ID['rail'], ID['parking'], ID['water']])
    blocked |= ndimage.binary_dilation(road_px, iterations=1)
    # never on the ride itself: keep 3 m clear of the route line
    tx, ty = W.T['x'], W.T['y']; m = (tx > ox - 5) & (tx < ox + size + 5) & (ty > oy - 5) & (ty < oy + size + 5)
    if m.any():
        rt = Image.new('L', (n, n), 0); dr = ImageDraw.Draw(rt)
        idx = np.nonzero(m)[0]
        for a, b in zip(idx, idx[1:]):
            if b == a + 1:   # only consecutive samples, so separate passes through the chunk aren't joined
                dr.line([((tx[a] - ox) / cres, (oy + size - ty[a]) / cres), ((tx[b] - ox) / cres, (oy + size - ty[b]) / cres)], fill=1, width=int(6 / cres))
        blocked |= np.array(rt) > 0
    out = []

    def try_put(x, y):
        j = int((x - ox) / cres); i = int((oy + size - y) / cres)
        if 0 <= i < n and 0 <= j < n and not blocked[i, j] and cls[i, j] in OK_GROUND:
            out.append((x, y)); blocked[max(0, i - 12):i + 13, max(0, j - 12):j + 13] = True   # ~6 m apart minimum

    # along streets (some streets have trees, some don't: decided per road so a street is consistent)
    for (e, tag, w, sw), bb in zip(W.roads, W.road_bb):
        hw = e['g'].get('highway')
        if hw not in TREE_ROADS or bb[2] < ox - 10 or bb[0] > ox + size + 10 or bb[3] < oy - 10 or bb[1] > oy + size + 10: continue
        h = zlib.crc32(repr(e['p'][0]).encode()) / 2 ** 32
        if h > TREE_ROADS[hw]: continue
        off = w / 2 + (sw * 0.55 if sw else 1.6)
        p = e['p']
        for (ax, ay), (bx, by) in zip(p, p[1:]):
            L = math.hypot(bx - ax, by - ay)
            if L < 1: continue
            nx, ny = -(by - ay) / L, (bx - ax) / L
            k = 0
            while k * 10 + 5 < L:
                t = (k * 10 + 5) / L; x, y = ax + (bx - ax) * t, ay + (by - ay) * t
                for s in (1, -1): try_put(x + nx * off * s, y + ny * off * s)
                k += 1
    # along quays: 2-4 m from the water's edge
    water = cls == ID['water']
    if water.mean() > 0.01:
        dist = ndimage.distance_transform_edt(~water) * cres
        band = (dist > 2.0) & (dist < 3.5)
        ii, jj = np.nonzero(band[::12, ::12])
        for i, j in zip(ii * 12, jj * 12):
            if zlib.crc32(f'{key}{i}{j}'.encode()) % 3 == 0: continue
            try_put(ox + (j + .5) * cres, oy + size - (i + .5) * cres)
    return out
