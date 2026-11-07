"""Chunked terrain: semantic ground tags, smoothed heights, rivers and sea, graded roads, the ride corridor,
bridges and abutments. Every chunk is processed with a margin so borders line up."""
import math
import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage
from .tags import ID, AREA_RANK, area_tag, road_tag
from .osm import join_rings
from shapely.geometry import Polygon, LineString, box as shp_box

CHUNK = 256.0      # metres per chunk side
CRES = 0.5         # class map metres per pixel
HRES = 1.0         # height grid metres per sample
MARGIN = 120.0     # processing margin around each chunk
CORRIDOR = 300.0   # chunks whose centre is within this distance of the route are built


def chunks_for(T, corridor=CORRIDOR):
    xs, ys = T['x'], T['y']; need = set()
    r = int(math.ceil((corridor + CHUNK) / CHUNK))
    idx = np.arange(0, len(xs), 8)
    for i in idx:
        cx0, cy0 = int(math.floor(xs[i] / CHUNK)), int(math.floor(ys[i] / CHUNK))
        for dx in range(-r, r + 1):
            for dy in range(-r, r + 1):
                cx, cy = cx0 + dx, cy0 + dy
                mx, my = (cx + .5) * CHUNK, (cy + .5) * CHUNK
                if (mx - xs[i]) ** 2 + (my - ys[i]) ** 2 <= corridor ** 2: need.add((cx, cy))
    return sorted(need)


# ------------------------------------------------------------------ global preparation
class World:
    def __init__(self, feats, T, dem_sample, sea_from_terrain=False, grade=True):
        self.T = T; self.dem = dem_sample; self.sea_from_terrain = sea_from_terrain
        self.areas = []      # (rank, tag, ring, holes)
        self.coast = []      # coastline ways (land on the left)
        self.roads = []      # (feature, tag, width, sidewalk)
        self.rails = []; self.bridges = []; self.buildings = []; self.trees = []; self.tree_rows = []; self.places = []
        self.river_lines = []; self.ocean = []; self.flow_lines = []
        for e in feats:
            g = e['g']
            if e['t'] == 'n':
                if g.get('natural') == 'tree': self.trees.append({'x': e['p'][0], 'y': e['p'][1], 'g': g})
                elif g.get('place') in ('city', 'town', 'village', 'hamlet', 'suburb', 'neighbourhood', 'quarter'):
                    self.places.append({'x': e['p'][0], 'y': e['p'][1], 'name': g.get('name', ''), 'kind': g['place']})
                continue
            if 'building' in g and g.get('building') not in ('roof', 'no'):
                rings = [e['p']] if e['t'] == 'w' else join_rings(e['m'])['outer']
                for p in rings:
                    if len(p) >= 4: self.buildings.append({'p': p, 'g': g})
                continue
            if g.get('natural') == 'coastline' and e['t'] == 'w':
                self.coast.append(e['p']); continue
            if g.get('natural') == 'tree_row' and e['t'] == 'w':
                self.tree_rows.append(e['p']); continue
            if e['t'] == 'w' and g.get('waterway') in ('river', 'canal', 'stream') and g.get('tunnel') is None:
                w = {'river': 10, 'canal': 8, 'stream': 3}[g['waterway']]
                try: w = float(g.get('width', w))
                except ValueError: pass
                self.river_lines.append((e['p'], w))
                if g['waterway'] in ('river', 'stream'): self.flow_lines.append(e['p'])     # drawn in the direction it flows
            rt = road_tag(g) if 'highway' in g and g.get('area') != 'yes' else None
            if rt and e['t'] == 'w':
                if g.get('tunnel') in ('yes', 'building_passage', 'culvert') or str(g.get('layer', '0')).startswith('-'):
                    continue
                if g.get('bridge') and g.get('bridge') != 'no':
                    self.bridges.append({'p': e['p'], 'tag': rt[0], 'w': rt[1] + 2 * rt[2], 'g': g})
                else:
                    self.roads.append((e, rt[0], rt[1], rt[2]))
                continue
            if e['t'] == 'w' and g.get('railway') in ('rail', 'light_rail', 'narrow_gauge') and not g.get('bridge') and g.get('tunnel') != 'yes':   # trams run in the street: leave the road surface
                self.rails.append(e['p']); continue
            tag = area_tag(g)
            if tag is None: continue
            if g.get('water') == 'ocean':
                for ring in ([e['p']] if e['t'] == 'w' else join_rings(e['m'])['outer']): self.ocean.append(ring)
            if e['t'] == 'w' and len(e['p']) >= 4 and _closed(e['p']):
                self.areas.append((AREA_RANK.get(tag, 3), tag, e['p'], []))
            elif e['t'] == 'r':
                rr = join_rings(e['m'])
                for ring in rr['outer']:
                    self.areas.append((AREA_RANK.get(tag, 3), tag, ring, rr['inner']))
        self.areas.sort(key=lambda a: a[0])
        self._bboxes()
        self.strokes = build_strokes(self.roads) if grade else []
        if grade: self._grade_strokes()

    def _bboxes(self):
        bb = lambda p: (min(q[0] for q in p), min(q[1] for q in p), max(q[0] for q in p), max(q[1] for q in p))
        self.area_bb = [bb(a[2]) for a in self.areas]
        self.road_bb = [bb(r[0]['p']) for r in self.roads]
        self.coast_bb = [bb(c) for c in self.coast]
        self.bld_bb = [bb(b['p']) for b in self.buildings]
        self.river_bb = [bb(r[0]) for r in self.river_lines]
        self.ocean_bb = [bb(r) for r in self.ocean]

    def _grade_strokes(self):
        """Each stroke (chain of road pieces) gets a smooth height profile, widened until it is <= 12 %."""
        for st in self.strokes:
            p = np.array(st['p'])
            seg = np.hypot(np.diff(p[:, 0]), np.diff(p[:, 1]))
            L = seg.sum()
            n = max(2, int(L) + 1)
            dd = np.concatenate([[0], np.cumsum(seg)])
            s = np.linspace(0, L, n)
            xs = np.interp(s, dd, p[:, 0]); ys = np.interp(s, dd, p[:, 1])
            z = self.dem(xs, ys)
            z = np.where(np.isnan(z), np.nanmean(z) if np.isfinite(z).any() else 0, z)
            for sig in (12, 20, 30, 45, 65, 90):
                zs = ndimage.gaussian_filter1d(z, sig, mode='nearest')
                if n < 3 or np.max(np.abs(np.diff(zs))) <= 0.12: break
            st['dense'] = np.stack([xs, ys, zs], 1)


def _closed(p):
    return abs(p[0][0] - p[-1][0]) < 0.05 and abs(p[0][1] - p[-1][1]) < 0.05


def build_strokes(roads):
    """Join road pieces that continue each other (same node, < 40 degree turn) into longer strokes,
    so roads split into many short OSM ways still get one smooth profile."""
    key = lambda q: (round(q[0] / 0.5), round(q[1] / 0.5))   # tile-clipped pieces meet within centimetres
    ends = {}
    for i, (e, tag, w, sw) in enumerate(roads):
        p = e['p']
        if len(p) < 2: continue
        ends.setdefault(key(p[0]), []).append((i, 0)); ends.setdefault(key(p[-1]), []).append((i, 1))
    used = [False] * len(roads); strokes = []

    def extend(path, widths, i, end):
        while True:
            p = roads[i][0]['p']
            a, b = (p[-2], p[-1]) if end == 1 else (p[1], p[0])
            hin = math.atan2(b[1] - a[1], b[0] - a[0]); node = key(b)
            best = None
            for j, je in ends.get(node, []):
                if used[j]: continue
                q = roads[j][0]['p']
                c, d = (q[0], q[1]) if je == 0 else (q[-1], q[-2])
                hout = math.atan2(d[1] - c[1], d[0] - c[0])
                turn = abs((hout - hin + math.pi) % (2 * math.pi) - math.pi)
                if turn < math.radians(40) and (best is None or turn < best[0]): best = (turn, j, je)
            if not best: return
            _, j, je = best; used[j] = True
            q = roads[j][0]['p']; seq = q if je == 0 else q[::-1]
            path += seq[1:]; widths.append(roads[j][2] + 2 * roads[j][3])
            i, end = j, (1 if je == 0 else 0)

    for i in range(len(roads)):
        if used[i] or len(roads[i][0]['p']) < 2: continue
        used[i] = True
        path = list(roads[i][0]['p']); widths = [roads[i][2] + 2 * roads[i][3]]
        extend(path, widths, i, 1)
        back = path[::-1]
        extend(back, widths, i, 0)
        strokes.append({'p': back, 'w': max(widths)})
    return strokes


# ------------------------------------------------------------------ per chunk
class ChunkGrid:
    def __init__(self, cx, cy):
        self.cx, self.cy = cx, cy
        self.x0 = cx * CHUNK - MARGIN; self.x1 = (cx + 1) * CHUNK + MARGIN
        self.y0 = cy * CHUNK - MARGIN; self.y1 = (cy + 1) * CHUNK + MARGIN
        self.cw = int(round((self.x1 - self.x0) / CRES)); self.hw = int(round((self.x1 - self.x0) / HRES)) + 1
        self.hx = self.x0 + np.arange(self.hw) * HRES; self.hy = self.y1 - np.arange(self.hw) * HRES

    def cpx(self, p):
        return ((p[0] - self.x0) / CRES, (self.y1 - p[1]) / CRES)

    def overlaps(self, bb, pad=0):
        return not (bb[2] < self.x0 - pad or bb[0] > self.x1 + pad or bb[3] < self.y0 - pad or bb[1] > self.y1 + pad)


def raster_classes(W: World, G: ChunkGrid):
    cres = getattr(G, 'cres', CRES)
    img = Image.new('L', (G.cw, G.cw), 0); dr = ImageDraw.Draw(img)
    # background: town or countryside, by building cover nearby
    bcount = sum(1 for bb in W.bld_bb if G.overlaps(bb))
    bg = ID['urban'] if bcount > 40 else ID['rural']
    dr.rectangle([0, 0, G.cw, G.cw], fill=bg)
    pad = 40.0
    win = (G.x0 - pad, G.y0 - pad, G.x1 + pad, G.y1 + pad)

    def inside_win(ring):
        xs = [q[0] for q in ring]; ys = [q[1] for q in ring]
        return min(xs) >= win[0] and max(xs) <= win[2] and min(ys) >= win[1] and max(ys) <= win[3]

    def polyfill(ring, c):
        # huge polygons (rivers, lakes, land use) are clipped exactly to the window first: the drawing
        # library's own clipping of far off-canvas vertices shifts edges by a fraction of a pixel depending
        # on where the window is, which neighbouring chunks would see differently
        if len(ring) < 3: return
        if inside_win(ring):
            dr.polygon([G.cpx(q) for q in ring], fill=c); return
        try:
            g = Polygon(ring)
            if not g.is_valid: g = g.buffer(0)
            g = g.intersection(shp_box(*win))
        except Exception:
            return
        for part in getattr(g, 'geoms', [g]):
            if part.is_empty or part.geom_type != 'Polygon': continue
            dr.polygon([G.cpx(q) for q in part.exterior.coords], fill=c)
            for hole in part.interiors: dr.polygon([G.cpx(q) for q in hole.coords], fill=bg)

    def line(p, c, w):
        if len(p) < 2: return
        if not inside_win(p):          # clip long lines exactly too (same reason as polygons)
            try:
                g = LineString(p).intersection(shp_box(*win))
            except Exception:
                return
            for part in getattr(g, 'geoms', [g]):
                if part.geom_type == 'LineString' and not part.is_empty and len(part.coords) >= 2: line(list(part.coords), c, w)
            return
        q = [G.cpx(t) for t in p]; wpx = max(1, int(round(w / cres)))
        dr.line(q, fill=c, width=wpx, joint='curve'); r = wpx / 2
        for x, y in (q[0], q[-1]): dr.ellipse([x - r, y - r, x + r, y + r], fill=c)

    # sea: coastline flood fill (land is on the left of coastline ways)
    sea = _sea_mask(W, G)
    for (rank, tag, ring, holes), bb in zip(W.areas, W.area_bb):
        if not G.overlaps(bb): continue
        polyfill(ring, ID[tag])
        for h in holes:
            if len(h) >= 3: polyfill(h, bg)
    for (p, w), bb in zip(W.river_lines, W.river_bb):
        if G.overlaps(bb, w): line(p, ID['water'], w)
    cls = np.array(img)
    if sea is not None: cls[sea] = ID['water']
    water_pre = cls == ID['water']
    img = Image.fromarray(cls); dr = ImageDraw.Draw(img)
    # roads: sidewalks under everything, then surfaces by width
    sel = [(r, bb) for r, bb in zip(W.roads, W.road_bb) if G.overlaps(bb, 20)]
    sel.sort(key=lambda t: t[0][2])
    for (e, tag, w, sw), bb in sel:
        if sw: line(e['p'], ID['paving'], w + 2 * sw)
    for (e, tag, w, sw), bb in sel:
        line(e['p'], ID[tag], w)
    for p in W.rails: line(p, ID['rail'], 3)
    cls = np.array(img)
    core = ndimage.binary_erosion(water_pre, iterations=max(1, int(round(1.5 / cres))))
    cls[core] = ID['water']            # paths drawn over a river edge don't cut into the water
    return cls, water_pre, bg, sea


def _sea_mask(W, G):
    oc = [r for r, bb in zip(W.ocean, W.ocean_bb) if G.overlaps(bb)]
    if oc:                                   # vector tiles give the sea as polygons
        im = Image.new('L', (G.cw, G.cw), 0); d = ImageDraw.Draw(im)
        win = (G.x0 - 40, G.y0 - 40, G.x1 + 40, G.y1 + 40)
        for r in oc:
            try: g = Polygon(r).buffer(0).intersection(shp_box(*win))
            except Exception: continue
            for part in getattr(g, 'geoms', [g]):
                if part.is_empty or part.geom_type != 'Polygon': continue
                d.polygon([G.cpx(q) for q in part.exterior.coords], fill=255)
                for hole in part.interiors: d.polygon([G.cpx(q) for q in hole.coords], fill=0)
        return np.array(im) > 0
    if W.ocean_bb and not any(G.overlaps(bb, 3000) for bb in W.ocean_bb) and not W.coast: return None
    segs = [c for c, bb in zip(W.coast, W.coast_bb) if G.overlaps(bb, 50)]
    if not segs:
        if not W.sea_from_terrain: return None     # vector tiles already give the sea as polygons
        # far from any coastline: open sea if the terrain says it's below sea level and nothing is mapped on it
        xx, yy = np.meshgrid(G.x0 + (np.arange(0, G.cw, 8) + .5) * CRES, G.y1 - (np.arange(0, G.cw, 8) + .5) * CRES)
        z = W.dem(xx.ravel(), yy.ravel()).reshape(xx.shape)
        m = np.nan_to_num(z, nan=0) < -2.0
        if not m.any(): return None
        m = np.kron(m, np.ones((8, 8), bool))[:G.cw, :G.cw]
        has_land = any(G.overlaps(bb) for bb in W.road_bb) or any(G.overlaps(bb) for bb in W.bld_bb)
        return None if has_land and m.mean() < 0.95 else m
    bar = Image.new('L', (G.cw, G.cw), 0); d = ImageDraw.Draw(bar)
    for c in segs: d.line([G.cpx(q) for q in c], fill=255, width=2)
    barrier = np.array(bar) > 0
    lab, n = ndimage.label(~barrier)
    votes = np.zeros(n + 1)
    for c in segs:
        for a, b in zip(c, c[1:]):
            dx, dy = b[0] - a[0], b[1] - a[1]; L = math.hypot(dx, dy)
            if L < 1e-3: continue
            nx, ny = dy / L, -dx / L                        # right-hand side = water
            for f in (0.25, 0.5, 0.75):
                mx, my = a[0] + dx * f, a[1] + dy * f
                for sgn, v in ((1, 1), (-1, -1)):
                    px, py = G.cpx((mx + nx * 3 * sgn, my + ny * 3 * sgn))
                    if 0 <= px < G.cw and 0 <= py < G.cw:
                        votes[lab[int(py), int(px)]] += v
    seaid = np.where(votes[1:] > 0)[0] + 1
    return np.isin(lab, seaid) | (barrier & ndimage.binary_dilation(np.isin(lab, seaid), iterations=2))


def dem_smoothed(W: World, G: ChunkGrid):
    xx, yy = np.meshgrid(G.hx, G.hy)
    h = W.dem(xx.ravel(), yy.ravel()).reshape(xx.shape)
    if np.isnan(h).any(): h = np.where(np.isnan(h), np.nanmean(h) if np.isfinite(h).any() else 0, h)
    return ndimage.gaussian_filter(h, 12.0 / HRES, mode='nearest')   # 13 m data; towns show up as bumps otherwise


def water_sample(G: ChunkGrid, h, water_pre, sea):
    """This chunk's own estimate of the water surface (used to build the route-wide water level field)."""
    if not water_pre.any(): return None
    if sea is not None and sea.any(): return 0.0
    wm = water_pre[::int(HRES / CRES), ::int(HRES / CRES)]
    wm = np.pad(wm, ((0, G.hw - wm.shape[0]), (0, G.hw - wm.shape[1])), mode='edge')
    wz = h[ndimage.binary_erosion(wm, iterations=2)]
    if wz.size < 20: wz = h[wm]
    return float(np.percentile(wz, 15)) if wz.size else None


class LevelField:
    """Water surface height as one smooth field over the whole route, stored on the chunk-corner lattice:
    a chunk's water surface is exactly the bilinear surface through its 4 corner values, so what is
    drawn, what is capped under the rider and what neighbours share are all the same surface."""
    def __init__(self, samples):
        self.s = {k: v for k, v in samples.items() if v is not None}
        if not self.s: self.grid = None; return
        ks = list(self.s); xs = [k[0] for k in ks]; ys = [k[1] for k in ks]
        self.x0, self.y0 = min(xs) - 2, min(ys) - 2
        acc = np.zeros((max(ys) - self.y0 + 4, max(xs) - self.x0 + 4)); cnt = np.zeros_like(acc)
        for (cx, cy), v in self.s.items():
            i, j = cy - self.y0, cx - self.x0          # chunk (cx, cy) touches corner nodes (i..i+1, j..j+1)
            acc[i:i + 2, j:j + 2] += v; cnt[i:i + 2, j:j + 2] += 1
        g = np.where(cnt > 0, acc / np.maximum(cnt, 1), np.nan)
        known = ~np.isnan(g)
        _, (ii, jj) = ndimage.distance_transform_edt(~known, return_indices=True)
        self.grid = g[ii, jj]

    def _ij(self, x, y):
        fx = np.asarray(x, float) / CHUNK - self.x0; fy = np.asarray(y, float) / CHUNK - self.y0
        fx = np.clip(fx, 0, self.grid.shape[1] - 1.001); fy = np.clip(fy, 0, self.grid.shape[0] - 1.001)
        j = np.floor(fx).astype(int); i = np.floor(fy).astype(int)
        return i, j, fx - j, fy - i

    def cap(self, x, y, zmax, iters=20):
        """Lower the field until it is <= zmax at every point (x, y) (e.g. the ride height along the route)."""
        if self.grid is None: return 0
        x = np.asarray(x, float); y = np.asarray(y, float); zmax = np.asarray(zmax, float)
        for _ in range(iters):
            over = self.at(x, y) - zmax
            bad = over > 0.005
            if not bad.any(): return 0
            i, j, _, _ = self._ij(x[bad], y[bad])
            low = np.zeros_like(self.grid)
            for di, dj in ((0, 0), (0, 1), (1, 0), (1, 1)):
                np.maximum.at(low, (i + di, j + dj), over[bad] + 0.01)
            self.grid = self.grid - low
        return int(bad.sum())

    def at(self, x, y):
        i, j, dx, dy = self._ij(x, y); g = self.grid      # node (i, j) sits at world (j+x0, i+y0) * CHUNK
        return g[i, j] * (1 - dx) * (1 - dy) + g[i, j + 1] * dx * (1 - dy) + g[i + 1, j] * (1 - dx) * dy + g[i + 1, j + 1] * dx * dy


def flow_dir(W, x0, y0, x1, y1, pad=20.0):
    """Which way rivers and streams flow over a box: length-weighted mean direction of the waterway lines
    there (OSM draws waterways downstream), as a unit [dx, dy], or None for still water / no clear flow."""
    sx = sy = tot = 0.0
    for p in W.flow_lines:
        for (ax, ay), (bx, by) in zip(p, p[1:]):
            mx, my = (ax + bx) / 2, (ay + by) / 2
            if x0 - pad <= mx <= x1 + pad and y0 - pad <= my <= y1 + pad:
                dx, dy = bx - ax, by - ay; L = math.hypot(dx, dy)
                sx += dx; sy += dy; tot += L
    m = math.hypot(sx, sy)
    if tot < 10 or m < 0.4 * tot: return None
    return [round(sx / m, 3), round(sy / m, 3)]


def shore(h, sd, lv, narrow=None):
    """Banks, beds and the water surface. h: smoothed terrain, sd: signed distance to water (m, negative
    inside), lv: the shared water level. The level is only trusted within a few metres of the terrain:
    lakes, rivers and sea sit at it with raised banks; where the terrain is far above it (a stream running
    down a slope) or far below it (the level field filled in from a lake higher up), the water follows the
    terrain with a shallow bed instead. Returns (heights, water surface)."""
    # 'level far above the terrain' only means a wrong level for narrow water (streams); under a lake or the
    # sea the bed is simply deep. narrow: 1 where the water is a narrow channel, 0 for wide water.
    nar = 1.0 if narrow is None else narrow
    f = np.maximum(np.clip((h - lv - 3.0) / 4.0, 0, 1), np.clip((lv - h - 2.0) / 3.0, 0, 1) * nar)
    lv_eff = lv + (h - 0.4 - lv) * f
    nw = np.clip((60.0 - sd) / 10.0, 0, 1)                    # smooth, no hard cut-off distance
    land = h + nw * np.clip(lv_eff + 1.0 * (1 - f) - h, 0, 2.5)
    wat = lv_eff - np.clip(-sd, 0, 30) * 0.12 * (1 - 0.8 * f)        # beds slope in gently (beaches, banks)
    t = np.clip((sd + 2.5) / 5.0, 0, 1)
    return wat + (land - wat) * t, lv_eff


def heights(W: World, G: ChunkGrid, cls, water_pre, sea, h, LF):
    T = W.T
    sd_full = (ndimage.distance_transform_edt(~water_pre) - ndimage.distance_transform_edt(water_pre)) * CRES
    sd_full = ndimage.gaussian_filter(sd_full, 5.0)
    sd = sd_full[::int(HRES / CRES), ::int(HRES / CRES)]
    sd = np.pad(sd, ((0, G.hw - sd.shape[0]), (0, G.hw - sd.shape[1])), mode='edge')
    level = None; surf = None
    if LF is not None and LF.grid is not None and (sd < 60).any():
        xx, yy = np.meshgrid(G.hx, G.hy)
        lv = LF.at(xx, yy)
        narrow = ndimage.uniform_filter((ndimage.minimum_filter(sd, size=31) > -6.0).astype(float), 9)
        if sea is not None and sea.any():
            sm = sea[::int(HRES / CRES), ::int(HRES / CRES)]
            sm = np.pad(sm, ((0, G.hw - sm.shape[0]), (0, G.hw - sm.shape[1])), mode='edge')[:G.hw, :G.hw]
            narrow = narrow * (1 - ndimage.uniform_filter(sm.astype(float), 9))
        h, surf = shore(h, sd, lv, narrow)
        if water_pre.any(): level = float(LF.at(np.array((G.x0 + G.x1) / 2), np.array((G.y0 + G.y1) / 2)))
    h_shore = h.copy()
    # graded roads
    acc_z = np.zeros_like(h); acc_w = np.zeros_like(h)
    for st in W.strokes:
        dn = st['dense']
        m = (dn[:, 0] > G.x0 - 10) & (dn[:, 0] < G.x1 + 10) & (dn[:, 1] > G.y0 - 10) & (dn[:, 1] < G.y1 + 10)
        if not m.any(): continue
        w = st.get('w', 6.0)
        _stamp(acc_z, acc_w, G, dn[m], w / 2, 2.0)
    has = acc_w > 0
    road_h = np.where(has, acc_z / np.maximum(acc_w, 1e-6), h)
    blend = ndimage.gaussian_filter(np.clip(acc_w, 0, 1), 1.5)
    lw = np.clip(sd + 0.5, 0, 1); lw = lw * lw * (3 - 2 * lw)          # smooth land weight (no hard cut at the waterline)
    h = h + (road_h - h) * blend * lw
    # the ride corridor follows the GPX's own elevation profile
    m = (T['x'] > G.x0 - 90) & (T['x'] < G.x1 + 90) & (T['y'] > G.y0 - 90) & (T['y'] < G.y1 + 90)   # same set for every chunk near a shared edge
    if m.any():
        cz = np.zeros_like(h); cw = np.zeros_like(h)
        R0, RF = 4.0, 18.0; r = int(R0 + RF)
        oi, oj = np.mgrid[-r:r + 1, -r:r + 1]; od = np.hypot(oi, oj) * HRES
        wt = np.clip(1 - (od - R0) / RF, 0, 1); wt = wt * wt * (3 - 2 * wt)
        wbl = np.exp(-(od / 3.0) ** 2) + 1e-9; sw = np.zeros_like(h)
        # deep cuts/fills get wider sides (about as wide as deep), so they read as a notch, not a wall
        kern = {}
        for RFk in (RF, 40.0, 80.0):
            rk = int(R0 + RFk); oik, ojk = np.mgrid[-rk:rk + 1, -rk:rk + 1]; odk = np.hypot(oik, ojk) * HRES
            wk = np.clip(1 - (odk - R0) / RFk, 0, 1); kern[RFk] = (rk, wk * wk * (3 - 2 * wk), np.exp(-(odk / 3.0) ** 2) + 1e-9)
        mis = T.get('mis', np.zeros(len(T['x'])))
        for x, y, z, ms in zip(T['x'][m], T['y'][m], T['zc'][m], mis[m]):
            r, wt, wbl = kern[RF if ms < 14 else 40.0 if ms < 35 else 80.0]
            i0 = int(round((G.y1 - y) / HRES)); j0 = int(round((x - G.x0) / HRES))
            if not (-r <= i0 < G.hw + r and -r <= j0 < G.hw + r): continue
            # (samples over water still stamp: the land weights below keep open water untouched)
            i_a, i_b = max(0, i0 - r), min(G.hw, i0 + r + 1); j_a, j_b = max(0, j0 - r), min(G.hw, j0 + r + 1)
            if i_a >= i_b or j_a >= j_b: continue
            ww = wt[i_a - i0 + r:i_b - i0 + r, j_a - j0 + r:j_b - j0 + r]
            wb = wbl[i_a - i0 + r:i_b - i0 + r, j_a - j0 + r:j_b - j0 + r]
            cz[i_a:i_b, j_a:j_b] += z * wb; sw[i_a:i_b, j_a:j_b] += wb
            cw[i_a:i_b, j_a:j_b] = np.maximum(cw[i_a:i_b, j_a:j_b], ww)
        # height = distance-weighted blend of nearby samples (smooth along the line, and across hairpins
        # whose legs are a few metres apart), strength = the nearest sample's stamp
        cz = cz / np.maximum(sw, 1e-12)
        globals()['_dbg'] = {'cz': cz.copy(), 'cw': cw.copy(), 'sw': sw.copy(), 'acc_w': acc_w.copy()}
        # where the rider is on land, the corridor wins right up to (and 2.5 m past) the water's edge:
        # a route hugging a quay must not tip into the canal
        lwc = np.clip((sd + 2.5) / 2.5, 0, 1); lwc = lwc * lwc * (3 - 2 * lwc)
        # a street drawn over mapped water (not a tagged bridge) is solid ground for the rider
        st = int(HRES / CRES)
        paved = np.isin(cls[::st, ::st], [ID['asphalt'], ID['paving'], ID['cycleway'], ID['cobble']])
        paved = np.pad(paved, ((0, G.hw - paved.shape[0]), (0, G.hw - paved.shape[1])), mode='edge')[:G.hw, :G.hw]
        paved = ndimage.gaussian_filter(paved.astype(float), 1.0)
        h = h + (cz - h) * cw * np.maximum(np.maximum(lw, lwc), paved)
    if surf is not None:
        # where roads or the ride corridor cut the ground down, water crossing the cut drops with it (a ford),
        # instead of hanging in the air at the old slope's height
        surf = surf - np.clip(h_shore - h, 0, None)
    return h, sd, has, level, surf


def _stamp(acc_z, acc_w, G, pts, half, feather):
    r = int(math.ceil(half + feather))
    oi, oj = np.mgrid[-r:r + 1, -r:r + 1]; od = np.hypot(oi, oj) * HRES
    keep = od <= half + feather
    oi, oj, od = oi[keep], oj[keep], od[keep]
    owt = np.where(od <= half, 1.0, (half + feather - od) / feather)
    I = (np.round((G.y1 - pts[:, 1]) / HRES).astype(int)[:, None] + oi[None]).ravel()
    J = (np.round((pts[:, 0] - G.x0) / HRES).astype(int)[:, None] + oj[None]).ravel()
    Z = np.repeat(pts[:, 2], len(oi)); WT = np.tile(owt, len(pts))
    m = (I >= 0) & (I < G.hw) & (J >= 0) & (J < G.hw)
    np.add.at(acc_z, (I[m], J[m]), Z[m] * WT[m]); np.add.at(acc_w, (I[m], J[m]), WT[m])


def crop_h(G, a):
    m = int(round(MARGIN / HRES)); n = int(round(CHUNK / HRES)) + 1
    return a[m:m + n, m:m + n]


def crop_c(G, a):
    m = int(round(MARGIN / CRES)); n = int(round(CHUNK / CRES))
    return a[m:m + n, m:m + n]
