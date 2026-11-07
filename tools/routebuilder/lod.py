"""Lower-detail rings around the full-detail ride corridor.

  near (terrain.py)  256 m chunks, 1 m heights, 0.5 m ground tags, every building and tree   (route +300 m)
  mid  (this file)   1024 m pages, 4 m heights, 2 m ground tags, box buildings, tree points (route +1.5 km,
                     plus every hole the route encloses, e.g. the inside of a loop)
  far  (this file)   one grid for the whole area, 32 m heights, 16 m ground tags            (+8 km)

Mid pages only draw the 256 m sub-chunks marked present (the near chunks are drawn by the near level).
Shared edges are made identical: page-to-page edges are averaged, then near-chunk borders are copied into
the pages, then the far grid's vertices on the border of the covered area take the nearer level's height
and its vertices inside the covered area are lowered out of sight."""
import math, zlib
from collections import OrderedDict
import numpy as np
from PIL import Image
from scipy import ndimage
from shapely.geometry import Polygon

from . import terrain as TR
from . import vtiles
from .tags import ID

PAGE = 1024.0
SUB = int(PAGE / TR.CHUNK)          # 4x4 chunks per page
MID_R = 1500.0
MID_CRES, MID_HRES, MID_MARGIN = 2.0, 4.0, 16.0
FAR_PAD, FAR_HRES, FAR_CRES = 8000.0, 32.0, 16.0
MID_Z, FAR_Z = 14, 12               # vector tile zoom levels


# ------------------------------------------------------------------ what to build
def mid_chunks(T, near):
    """Chunks for the mid ring: within MID_R of the route, plus enclosed holes; never a near chunk."""
    reach = set(TR.chunks_for(T, MID_R)) | set(near)
    xs = [k[0] for k in reach]; ys = [k[1] for k in reach]
    x0, y0 = min(xs) - 1, min(ys) - 1
    m = np.zeros((max(ys) - y0 + 2, max(xs) - x0 + 2), bool)
    for cx, cy in reach: m[cy - y0, cx - x0] = True
    m = ndimage.binary_fill_holes(m)
    out = {(int(j + x0), int(i + y0)) for i, j in zip(*np.nonzero(m))}
    return sorted(out - set(near))


def pages_of(mids):
    pages = {}
    for cx, cy in mids:
        pages.setdefault((cx // SUB, cy // SUB), set()).add((cx, cy))
    return pages


def far_box(near, mids):
    ks = list(near) + list(mids)
    x0 = min(k[0] for k in ks) * TR.CHUNK - FAR_PAD; x1 = (max(k[0] for k in ks) + 1) * TR.CHUNK + FAR_PAD
    y0 = min(k[1] for k in ks) * TR.CHUNK - FAR_PAD; y1 = (max(k[1] for k in ks) + 1) * TR.CHUNK + FAR_PAD
    a = PAGE
    return math.floor(x0 / a) * a, math.floor(y0 / a) * a, math.ceil(x1 / a) * a, math.ceil(y1 / a) * a


def _tiles_over(P, boxes, z, step=200.0):
    """Tiles at zoom z touching any of the (x0, y0, x1, y1) boxes (sampled every `step` metres)."""
    out = set()
    for (x0, y0, x1, y1) in boxes:
        xs = np.append(np.arange(x0, x1, step), x1); ys = np.append(np.arange(y0, y1, step), y1)
        gx, gy = np.meshgrid(xs, ys)
        lat, lon = P.inv(gx.ravel(), gy.ravel())
        tx, ty = vtiles.tile_of(lat, lon, z)
        out.update(zip(tx.tolist(), ty.tolist()))
    return sorted(out)


def page_box(pk, pad=0.0):
    return (pk[0] * PAGE - pad, pk[1] * PAGE - pad, (pk[0] + 1) * PAGE + pad, (pk[1] + 1) * PAGE + pad)


def plan(T, near):
    """Everything the rings need, before any download: mid chunks/pages, far box, tile lists."""
    P = T['proj']
    mids = mid_chunks(T, near); pages = pages_of(mids)
    fb = far_box(near, mids)
    mid_vt = _tiles_over(P, [(c[0] * TR.CHUNK - MID_MARGIN, c[1] * TR.CHUNK - MID_MARGIN, (c[0] + 1) * TR.CHUNK + MID_MARGIN,
                              (c[1] + 1) * TR.CHUNK + MID_MARGIN) for c in mids], MID_Z, 250.0)
    far_vt = _tiles_over(P, [fb], FAR_Z, 1500.0)
    return {'mids': mids, 'pages': pages, 'far_box': fb, 'mid_vt': mid_vt, 'far_vt': far_vt,
            'mid_dem_boxes': [page_box(pk, 64) for pk in pages], 'far_dem_boxes': [fb]}


def dem_tiles(P, boxes, z):
    from .dem import lonlat_to_tile
    out = set()
    for (x0, y0, x1, y1) in boxes:
        step = 400.0
        xs = np.append(np.arange(x0, x1, step), x1); ys = np.append(np.arange(y0, y1, step), y1)
        gx, gy = np.meshgrid(xs, ys); lat, lon = P.inv(gx.ravel(), gy.ravel())
        tx, ty = lonlat_to_tile(lon, lat, z)
        out.update(zip(tx.astype(int).tolist(), ty.astype(int).tolist()))
    return sorted(out)


# ------------------------------------------------------------------ grids
class Grid:
    """A raster window with its own resolution; quacks like terrain.ChunkGrid for raster_classes."""
    def __init__(self, x0, y0, x1, y1, cres, hres):
        self.x0, self.y0, self.x1, self.y1, self.cres, self.hres = x0, y0, x1, y1, cres, hres
        self.cw = int(round((x1 - x0) / cres)); self.hw = int(round((x1 - x0) / hres)) + 1
        self.ch = int(round((y1 - y0) / cres)); self.hh = int(round((y1 - y0) / hres)) + 1
        self.hx = x0 + np.arange(self.hw) * hres; self.hy = y1 - np.arange(self.hh) * hres

    def cpx(self, p):
        return ((p[0] - self.x0) / self.cres, (self.y1 - p[1]) / self.cres)

    def overlaps(self, bb, pad=0):
        return not (bb[2] < self.x0 - pad or bb[0] > self.x1 + pad or bb[3] < self.y0 - pad or bb[1] > self.y1 + pad)


def _raster(W, G):
    """raster_classes on a non-square or coarse window (it draws on a square canvas of side cw)."""
    if G.cw != G.ch: raise ValueError('square windows only')
    return TR.raster_classes(W, G)


def _signed_dist(water, cres, step, shape):
    sd = (ndimage.distance_transform_edt(~water) - ndimage.distance_transform_edt(water)) * cres
    sd = ndimage.gaussian_filter(sd, 5.0 / cres)
    sd = sd[::step, ::step]
    return np.pad(sd, ((0, max(0, shape[0] - sd.shape[0])), (0, max(0, shape[1] - sd.shape[1]))), mode='edge')[:shape[0], :shape[1]]


def water_level_sample(h, water, step):
    wm = water[::step, ::step]
    wm = np.pad(wm, ((0, max(0, h.shape[0] - wm.shape[0])), (0, max(0, h.shape[1] - wm.shape[1]))), mode='edge')[:h.shape[0], :h.shape[1]]
    wz = h[ndimage.binary_erosion(wm, iterations=2)]
    if wz.size < 20: wz = h[wm]
    return float(np.percentile(wz, 15)) if wz.size else None


# ------------------------------------------------------------------ mid ring
class TileFeats:
    """Decoded vector tiles, cached (pages next to each other share tiles)."""
    def __init__(self, raw, P, z, keep=48):
        self.raw, self.P, self.z, self.keep, self.cache = raw, P, z, keep, OrderedDict()

    def feats(self, tiles):
        out = []
        for t in tiles:
            if t not in self.raw: continue
            if t not in self.cache:
                self.cache[t] = vtiles.to_feats({t: self.raw[t]}, self.P, self.z)
                if len(self.cache) > self.keep: self.cache.popitem(last=False)
            else:
                self.cache.move_to_end(t)
            out += self.cache[t]
        return out


def _box_of(p):
    try:
        poly = Polygon(p)
        if not poly.is_valid: poly = poly.buffer(0)
        if poly.area < 25: return None
        r = poly.minimum_rotated_rectangle
        c = list(r.exterior.coords)[:4]
    except Exception:
        return None
    e1 = (c[1][0] - c[0][0], c[1][1] - c[0][1]); e2 = (c[2][0] - c[1][0], c[2][1] - c[1][1])
    L1, L2 = math.hypot(*e1), math.hypot(*e2)
    if L1 < L2: e1, e2, L1, L2 = e2, e1, L2, L1
    cx = sum(q[0] for q in c) / 4; cy = sum(q[1] for q in c) / 4
    return cx, cy, L1, L2, math.degrees(math.atan2(e1[1], e1[0])) % 180


PLACE_R = {'city': 2600, 'town': 1100, 'village': 380, 'suburb': 800, 'quarter': 450, 'neighbourhood': 260, 'hamlet': 120}


TREE_TAGS = {ID['forest_floor']: (16, 0.75), ID['orchard']: (12, 0.6), ID['scrub']: (20, 0.35), ID['grass']: (24, 0.12), ID['wetland']: (24, 0.15)}


def build_mid(T, P, plan_, raw_vt, dem_xy, mlat):
    """Pass 1 per page: ground tags, water masks, objects. Returns state for the water level field and pass 2."""
    TF = TileFeats(raw_vt, P, MID_Z)
    pages = {}
    conifer = abs(float(mlat)) > 50
    for pk in sorted(plan_['pages']):
        present = plan_['pages'][pk]
        x0, y0, x1, y1 = page_box(pk, MID_MARGIN)
        G = Grid(x0, y0, x1, y1, MID_CRES, MID_HRES)
        tiles = _tiles_over(P, [(x0, y0, x1, y1)], MID_Z, 300.0)
        W = TR.World(TF.feats(tiles), T, dem_xy, grade=False)
        cls, water_pre, bg, sea = _raster(W, G)
        m = int(round(MID_MARGIN / MID_CRES)); n = int(round(PAGE / MID_CRES))
        # objects in the present sub-chunks only
        inside = lambda x, y: (int(math.floor(x / TR.CHUNK)), int(math.floor(y / TR.CHUNK))) in present
        boxes = []
        for b in W.buildings:
            p = b['p']; cxm = sum(q[0] for q in p) / len(p); cym = sum(q[1] for q in p) / len(p)
            if not (pk[0] * PAGE <= cxm < (pk[0] + 1) * PAGE and pk[1] * PAGE <= cym < (pk[1] + 1) * PAGE) or not inside(cxm, cym): continue
            bx = _box_of(p)
            if bx is None: continue
            try: ht = float(b['g'].get('height', 0)) or 0
            except ValueError: ht = 0
            if not ht: ht = 7.5 if bg != ID['urban'] else 13.0
            boxes.append(list(bx) + [ht])
        trees = []
        for tid, (step, prob) in TREE_TAGS.items():
            sp = int(step / MID_CRES)
            ii, jj = np.nonzero(cls[m:m + n:sp, m:m + n:sp] == tid)
            for i, j in zip(ii, jj):
                x = pk[0] * PAGE + (j * sp + .5) * MID_CRES; y = (pk[1] + 1) * PAGE - (i * sp + .5) * MID_CRES
                hsh = zlib.crc32(f'{x:.0f},{y:.0f}'.encode())
                if (hsh % 1000) / 1000 > prob or not inside(x, y): continue
                jx = ((hsh >> 10) % 100) / 100 - .5; jy = ((hsh >> 17) % 100) / 100 - .5
                kind = 'shrub' if tid == ID['scrub'] else 'orchard' if tid == ID['orchard'] else \
                       ('conifer' if tid == ID['forest_floor'] and (conifer or (hsh >> 24) % 3 == 0) else 'broadleaf')
                trees.append([x + jx * step * .8, y + jy * step * .8, kind, (hsh >> 4) % 1000])
        hd = ndimage.gaussian_filter(_dem_grid(dem_xy, G), 12.0 / MID_HRES, mode='nearest')
        step = int(MID_HRES / MID_CRES)
        # water level per 256 m chunk (same footprint as the near ring's samples, so they agree)
        lvls = {}
        if water_pre.any():
            mh = int(round(MID_MARGIN / MID_HRES)); per = int(TR.CHUNK / MID_HRES)
            for (cx, cy) in present:
                j0 = mh + (cx - pk[0] * SUB) * per; i0 = mh + (SUB - 1 - (cy - pk[1] * SUB)) * per
                wsub = water_pre[i0 * step:(i0 + per) * step, j0 * step:(j0 + per) * step]
                if not wsub.any(): continue
                if sea is not None and sea[i0 * step:(i0 + per) * step, j0 * step:(j0 + per) * step].any(): lvls[(cx, cy)] = 0.0; continue
                v = water_level_sample(hd[i0:i0 + per + 1, j0:j0 + per + 1], wsub, step)
                if v is not None: lvls[(cx, cy)] = v
        lvl = None
        flw = type('F', (), {'flow_lines': W.flow_lines})()       # keep only the waterway lines for pass 2
        pages[pk] = {'W_flow': flw, 'present': present, 'cls': cls[m:m + n, m:m + n].copy(), 'water': np.packbits(water_pre), 'wshape': water_pre.shape,
                     'boxes': boxes, 'trees': trees, 'level_samples': lvls, 'bg': bg}
    return pages


def _dem_grid(dem_xy, G):
    xx, yy = np.meshgrid(G.hx, G.hy)
    h = dem_xy(xx.ravel(), yy.ravel()).reshape(xx.shape)
    if np.isnan(h).any(): h = np.where(np.isnan(h), np.nanmean(h) if np.isfinite(h).any() else 0, h)
    return h


def level_samples(pages):
    """Mid pages' water estimates as 256 m chunk samples for terrain.LevelField."""
    out = {}
    for pg in pages.values(): out.update(pg['level_samples'])
    return out


def mid_heights(pages, dem_xy, LF):
    """Pass 2: heights at 4 m with embankments and water beds from the shared level field."""
    step = int(MID_HRES / MID_CRES)
    for pk, pg in pages.items():
        x0, y0, x1, y1 = page_box(pk, MID_MARGIN)
        G = Grid(x0, y0, x1, y1, MID_CRES, MID_HRES)
        h = ndimage.gaussian_filter(_dem_grid(dem_xy, G), 12.0 / MID_HRES, mode='nearest')
        water = np.unpackbits(pg['water'])[:pg['wshape'][0] * pg['wshape'][1]].reshape(pg['wshape']).astype(bool)
        pg['water_corners'] = {}; pg['water_chunks'] = []; pg['wsurf'] = None; pg['water_flow'] = {}
        if water.any() and LF is not None and LF.grid is not None:
            sd = _signed_dist(water, MID_CRES, step, h.shape)
            xx, yy = np.meshgrid(G.hx, G.hy); lv = LF.at(xx, yy)
            narrow = ndimage.uniform_filter((ndimage.minimum_filter(sd, size=9) > -6.0).astype(float), 3)
            h, surf = TR.shore(h, sd, lv, narrow)
            m = int(round(MID_MARGIN / MID_CRES)); n = int(round(PAGE / MID_CRES))
            wc = water[m:m + n, m:m + n]; sub = n // SUB
            for (cx, cy) in pg['present']:
                j = (cx - pk[0] * SUB) * sub; i = (SUB - 1 - (cy - pk[1] * SUB)) * sub
                if wc[i:i + sub, j:j + sub].any():
                    pg['water_chunks'].append([cx, cy])
                    fd = TR.flow_dir(pg['W_flow'], cx * TR.CHUNK, cy * TR.CHUNK, (cx + 1) * TR.CHUNK, (cy + 1) * TR.CHUNK)
                    if fd: pg['water_flow'][f'{cx},{cy}'] = fd
            if pg['water_chunks']:
                mh_ = int(round(MID_MARGIN / MID_HRES)); nh_ = int(round(PAGE / MID_HRES)) + 1
                pg['wsurf'] = surf[mh_:mh_ + nh_:2, mh_:mh_ + nh_:2].astype(np.float32)     # 8 m water surface grid
        mh = int(round(MID_MARGIN / MID_HRES)); nh = int(round(PAGE / MID_HRES)) + 1
        pg['h'] = h[mh:mh + nh, mh:mh + nh].astype(np.float32)
        del pg['water']; pg.pop('W_flow', None)


def _page_slots(pages, X, Y):
    """(page, i, j) for every page whose height grid has a vertex at world (X, Y) (metres, on the 4 m lattice)."""
    out = []
    for px in {int(math.floor(X / PAGE)), int(math.floor(X / PAGE)) - 1}:
        for py in {int(math.floor(Y / PAGE)), int(math.floor(Y / PAGE)) - 1}:
            pg = pages.get((px, py))
            if pg is None: continue
            j = (X - px * PAGE) / MID_HRES; i = ((py + 1) * PAGE - Y) / MID_HRES
            n = pg['h'].shape[0]
            if 0 <= j <= n - 1 and 0 <= i <= n - 1: out.append((pg, int(round(i)), int(round(j))))
    return out


def stitch(pages, near):
    """Make every shared vertex identical: page edges averaged, then near-chunk borders copied in."""
    n = int(round(PAGE / MID_HRES)) + 1
    edge = np.zeros((n, n), bool); edge[0, :] = edge[-1, :] = edge[:, 0] = edge[:, -1] = True
    ei, ej = np.nonzero(edge)
    acc = {}
    for (px, py), pg in pages.items():
        X = px * PAGE + ej * MID_HRES; Y = (py + 1) * PAGE - ei * MID_HRES
        for x, y, v in zip(X.tolist(), Y.tolist(), pg['h'][ei, ej].tolist()):
            a = acc.setdefault((round(x), round(y)), [0.0, 0]); a[0] += v; a[1] += 1
    for (px, py), pg in pages.items():
        X = px * PAGE + ej * MID_HRES; Y = (py + 1) * PAGE - ei * MID_HRES
        pg['h'][ei, ej] = [acc[(round(x), round(y))][0] / acc[(round(x), round(y))][1] for x, y in zip(X.tolist(), Y.tolist())]
    st = int(MID_HRES / TR.HRES); m = int(TR.CHUNK / TR.HRES)
    for (cx, cy), c in near.items():
        hh = c['h']; X0 = cx * TR.CHUNK; Y1 = (cy + 1) * TR.CHUNK
        for k in range(0, m + 1, st):
            for (i, j) in ((0, k), (m, k), (k, 0), (k, m)):
                X = X0 + j * TR.HRES; Y = Y1 - i * TR.HRES
                for pg, pi, pj in _page_slots(pages, X, Y): pg['h'][pi, pj] = hh[i, j]


# ------------------------------------------------------------------ far ring
def build_far(T, P, plan_, raw_vt, dem_far, dem_xy):
    x0, y0, x1, y1 = plan_['far_box']
    G = Grid(x0, y0, x1, y1, FAR_CRES, FAR_HRES)
    side = max(x1 - x0, y1 - y0)
    Gs = Grid(x0, y1 - side, x0 + side, y1, FAR_CRES, FAR_HRES)       # square canvas for raster_classes
    feats = vtiles.to_feats(raw_vt, P, FAR_Z)
    W = TR.World(feats, T, dem_xy, grade=False)
    W.buildings = []; W.bld_bb = []
    cls, water_pre, bg, sea = _raster(W, Gs)
    cls = cls[:G.ch, :G.cw]
    sea = sea[:G.ch, :G.cw] if sea is not None else None
    # low-zoom tiles leave most built-up land unmapped: paint towns around place points (size by kind),
    # only over plain countryside, so mapped fields, woods and water stay
    from PIL import ImageDraw
    town = Image.new('L', (G.cw, G.ch), 0); dr = ImageDraw.Draw(town)
    for pl in W.places:
        r = PLACE_R.get(pl['kind'])
        if not r: continue
        cx, cy = (pl['x'] - x0) / FAR_CRES, (y1 - pl['y']) / FAR_CRES; rr = r / FAR_CRES
        seed = zlib.crc32(f"{pl['x']:.0f},{pl['y']:.0f}".encode())
        ph = [((seed >> (k * 5)) % 628) / 100 for k in range(3)]
        pts = []
        for a in np.linspace(0, 2 * math.pi, 48, endpoint=False):     # lumpy outline, not a perfect disc
            f = 0.78 + 0.16 * math.sin(2 * a + ph[0]) + 0.1 * math.sin(3 * a + ph[1]) + 0.07 * math.sin(5 * a + ph[2])
            pts.append((cx + math.cos(a) * rr * f, cy + math.sin(a) * rr * f))
        dr.polygon(pts, fill=1)
    tm = np.array(town) > 0
    cls = np.where(tm & (cls == ID['rural']), ID['urban'], cls).astype(np.uint8)
    xx, yy = np.meshgrid(G.hx, G.hy)
    lat, lon = P.inv(xx.ravel(), yy.ravel())
    h = dem_far.sample_lonlat(lon, lat).reshape(xx.shape)
    if np.isnan(h).any(): h = np.where(np.isnan(h), np.nanmean(h) if np.isfinite(h).any() else 0, h)
    if sea is not None and sea.any():
        sv = sea[::2, ::2]; sv = np.pad(sv, ((0, h.shape[0] - sv.shape[0]), (0, h.shape[1] - sv.shape[1])), mode='edge')[:h.shape[0], :h.shape[1]]
        h = np.where(sv, np.minimum(h, -0.5), h)
    return {'G': G, 'h': h.astype(np.float32), 'cls': cls}


def far_join(far, near, pages):
    """Vertices on the border of the covered area take the nearer level's height; inside it, drop out of sight."""
    G = far['G']; h = far['h']
    covered = set(near) | {c for pg in pages.values() for c in pg['present']}
    X = G.hx[None, :].repeat(len(G.hy), 0); Y = G.hy[:, None].repeat(len(G.hx), 1)
    fx = X / TR.CHUNK; fy = Y / TR.CHUNK
    onx = np.isclose(fx, np.round(fx)); ony = np.isclose(fy, np.round(fy))
    cnt = np.zeros(h.shape, int); tot = np.zeros(h.shape, int)
    for dx in (0, -1):
        for dy in (0, -1):
            use = (onx | (dx == 0)) & (ony | (dy == 0))
            kx = np.floor(fx + 1e-6).astype(int) + dx; ky = np.floor(fy + 1e-6).astype(int) + dy
            tot += use
            for i, j in zip(*np.nonzero(use)):
                if (kx[i, j], ky[i, j]) in covered: cnt[i, j] += 1
    inner = (cnt == tot) & (tot > 0)
    border = (cnt > 0) & ~inner
    for i, j in zip(*np.nonzero(border)):
        v = vertex_height(float(X[i, j]), float(Y[i, j]), near, pages)
        if v is not None: h[i, j] = v
    h[inner] -= 25.0
    far['h'] = h
    return int(border.sum()), int(inner.sum())


def vertex_height(x, y, near, pages):
    """Height of the nearest level that owns a chunk touching world vertex (x, y)."""
    ks = {(int(math.floor((x + ex) / TR.CHUNK)), int(math.floor((y + ey) / TR.CHUNK))) for ex in (0.5, -0.5) for ey in (0.5, -0.5)}
    for k in ks:
        c = near.get(k)
        if c is not None:
            j = int(round((x - k[0] * TR.CHUNK) / TR.HRES)); i = int(round(((k[1] + 1) * TR.CHUNK - y) / TR.HRES))
            return float(c['h'][i, j])
    for k in ks:
        pk = (k[0] // SUB, k[1] // SUB); pg = pages.get(pk)
        if pg is not None and k in pg['present']:
            j = int(round((x - pk[0] * PAGE) / MID_HRES)); i = int(round(((pk[1] + 1) * PAGE - y) / MID_HRES))
            return float(pg['h'][i, j])
    return None


def page_h_at(pg, pk, x, y):
    h = pg['h']; n = h.shape[0]
    j = (x - pk[0] * PAGE) / MID_HRES; i = ((pk[1] + 1) * PAGE - y) / MID_HRES
    j = min(max(j, 0), n - 1.001); i = min(max(i, 0), n - 1.001); j0, i0 = int(j), int(i); fx, fy = j - j0, i - i0
    return float(h[i0, j0] * (1 - fx) * (1 - fy) + h[i0, j0 + 1] * fx * (1 - fy) + h[i0 + 1, j0] * (1 - fx) * fy + h[i0 + 1, j0 + 1] * fx * fy)
