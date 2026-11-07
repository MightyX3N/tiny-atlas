"""Route builder: GPX in, ready-to-ride route package out.

usage:
  python -m routebuilder.build ROUTE.gpx --out routes/ID [--cache cache/] [--plan plan.json] [--max-km N]

Without --plan it downloads what it needs (OpenStreetMap via Overpass, Terrain Tiles elevation,
Open-Meteo climate). With --plan it never downloads: it writes the missing requests to plan.json
and exits with status 'needs_data', so another program can fetch them into the cache."""
import argparse, json, math, os, re, sys, time, hashlib
import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage
from scipy.spatial import cKDTree

from .gpx import read_gpx, GPXError
from .fetch import Fetcher
from .track import build_track, finish_elevation, find_climbs, find_sprints, STEP
from .osm import fetch_osm, parse
from . import vtiles
from .dem import DEM, tiles_for
from .climate import fetch_climate
from .tags import TAGS, ID, RIDE_SURFACE
from . import terrain as TR
from .streettrees import street_trees
from . import lod as LOD

FORMAT_VERSION = 1
BUILDER_VERSION = '0.1.0'


def log(*a):
    print('[routebuilder]', *a, flush=True)


def slug(s):
    s = re.sub(r'[^a-z0-9]+', '-', s.lower()).strip('-')
    return s[:48] or 'route'


def guess_activity(gpx, T):
    text = (gpx['name'] + ' ' + gpx['desc']).lower()
    for words, kind in ((('sail', 'kite', 'kayak', 'row', 'paddle', 'boat'), 'water'), (('hike', 'walk', 'trek'), 'walk'),
                        (('run', 'marathon', 'jog'), 'run'), (('mtb', 'bike', 'ride', 'cycl', 'gravel'), 'ride'),
                        (('drive', 'car'), 'ride')):
        if any(w in text for w in words): return kind
    return 'ride'


def build(gpx_path, out_dir, cache_dir, plan_path=None, max_km=None, dem_zoom=13, source='tiles'):
    t0 = time.time()
    try:
        gpx = read_gpx(open(gpx_path, 'rb').read())
    except GPXError as e:
        return {'status': 'error', 'message': str(e)}
    T = build_track(gpx, max_km)
    if T['length'] < 50:
        return {'status': 'error', 'message': 'the track is shorter than 50 m'}
    log(f"{gpx['name']}: {T['length'] / 1000:.1f} km, {len(T['s'])} samples, elevation in GPX: {T['has_ele']}")
    F = Fetcher(cache_dir, 'plan' if plan_path else 'online')

    if source == 'overpass': raws, miss_osm = fetch_osm(F, T)
    else: vt, miss_osm = vtiles.fetch(F, T)
    near_keys = TR.chunks_for(T)
    LP = LOD.plan(T, near_keys)                                                 # mid and far rings around the corridor
    mid_vt, miss_mid = vtiles.fetch_tiles(F, LOD.MID_Z, LP['mid_vt'])
    far_vt, miss_far = vtiles.fetch_tiles(F, LOD.FAR_Z, LP['far_vt'])
    dem13 = DEM(F, dem_zoom).load(sorted(set(tiles_for(T, dem_zoom, 950, 150)) | set(LOD.dem_tiles(T['proj'], LP['mid_dem_boxes'], dem_zoom))))
    dem11 = DEM(F, dem_zoom - 2).load(sorted(set(tiles_for(T, dem_zoom - 2, 4500, 600)) | set(LOD.dem_tiles(T['proj'], LP['far_dem_boxes'], dem_zoom - 2))))
    mid = len(T['s']) // 2
    mlat, mlon = T['proj'].inv(T['x'][mid], T['y'][mid])
    clim, miss_clim = fetch_climate(F, float(mlat), float(mlon))
    missing = miss_osm + miss_mid + miss_far + dem13.missing + dem11.missing + miss_clim
    if missing:
        if plan_path:
            n = F.save_plan(plan_path)
            return {'status': 'needs_data', 'requests': n, 'plan': plan_path}
        return {'status': 'error', 'message': f'{missing} downloads failed'}

    P = T['proj']

    def dem_xy(x, y):
        lat, lon = P.inv(np.asarray(x, float), np.asarray(y, float))
        z = dem13.sample_lonlat(lon, lat)
        bad = np.isnan(z)
        if bad.any(): z[bad] = dem11.sample_lonlat(lon[bad], lat[bad])
        return z

    finish_elevation(T, dem_xy)
    # GPS/barometer elevation can sit metres off the terrain: shift the ride corridor onto the terrain,
    # keeping the GPX's own ups and downs (that's what the rider feels)
    d_ground = dem_xy(T['x'], T['y'])
    diff = np.nan_to_num(d_ground - T['z'], nan=0.0)
    off = ndimage.median_filter(diff, size=max(3, int(1000 / STEP)), mode='nearest')
    off = ndimage.gaussian_filter1d(off, 1500 / STEP, mode='nearest')
    T['zc'] = T['z'] + off
    # On steep ground the GPX's own heights (often from much coarser data) can sit tens of metres off the
    # real slope: there the terrain is trusted, smoothed along the path so position jitter across the
    # slope doesn't turn into bumps. On gentle ground (roads, towns: where elevation data has bumps from
    # buildings and bridges) the GPX's profile is kept.
    ex, ey = 10.0, 10.0
    gx = (dem_xy(T['x'] + ex, T['y']) - dem_xy(T['x'] - ex, T['y'])) / (2 * ex)
    gy = (dem_xy(T['x'], T['y'] + ey) - dem_xy(T['x'], T['y'] - ey)) / (2 * ey)
    slope = np.nan_to_num(np.hypot(gx, gy), nan=0.0)
    w_ter = ndimage.gaussian_filter1d(np.clip((slope - 0.15) / 0.25, 0, 1), 50 / STEP, mode='nearest')
    z_ter = ndimage.gaussian_filter1d(np.nan_to_num(d_ground, nan=float(np.nanmean(d_ground))), 30 / STEP, mode='nearest')
    T['zc'] = T['zc'] * (1 - w_ter) + z_ter * w_ter
    # whatever mismatch is left beyond 6 m: ease onto the terrain over ~80 m (no trench or dam along the path)
    for _ in range(40):
        resid = np.nan_to_num(dem_xy(T['x'], T['y']) - T['zc'], nan=0.0)
        excess = resid - np.clip(resid, -6.0, 6.0)
        if np.abs(excess).max() < 0.5: break
        T['zc'] = T['zc'] + ndimage.gaussian_filter1d(excess, 80 / STEP, mode='nearest')
    # rideability: never more than 25 % steeper than the GPX says (a straight line drawn up a cliff would
    # otherwise become a wall); the rest of the mismatch becomes a cut/fill with sides as wide as it is deep
    corr = T['zc'] - (T['z'] + off); k = 0.25 * STEP
    def lip(p_):
        L = p_.copy()
        for i in range(1, len(L)): L[i] = min(L[i], L[i - 1] + k)
        for i in range(len(L) - 2, -1, -1): L[i] = min(L[i], L[i + 1] + k)
        return L
    T['zc'] = T['z'] + off + lip(np.maximum(corr, 0)) - lip(np.maximum(-corr, 0))
    log(f'steep-ground share trusting the terrain: {float(np.mean(w_ter > 0.5)) * 100:.0f}%')
    log(f"ride vs terrain after local easing: max {np.nanmax(np.abs(dem_xy(T['x'], T['y']) - T['zc'])):.1f} m")
    # the same spot ridden twice (loops, out-and-back, crossings) must have one height on both passes
    tree_ = cKDTree(np.stack([T['x'], T['y']], 1))
    dg_ = np.nan_to_num(d_ground, nan=0.0)
    pairs = np.array([(i, j) for i, j in tree_.query_pairs(4.0) if abs(i - j) * STEP > 60
                      and (abs(dg_[i] - dg_[j]) < 2.0 or math.hypot(T['x'][i] - T['x'][j], T['y'][i] - T['y'][j]) < 1.0)],
                     int).reshape(-1, 2)          # on a steep slope two paths a few metres apart are not at one height
    if len(pairs):
        # smooth correction c along the ride: pairs agree, c changes slowly, and stays small elsewhere
        import scipy.sparse as sp
        from scipy.sparse.linalg import spsolve
        n_ = len(T['s']); lam, mu = 400.0, 0.02
        D = sp.diags([np.ones(n_ - 1), -np.ones(n_ - 1)], [0, 1], shape=(n_ - 1, n_))
        Pm = sp.csr_matrix((np.concatenate([np.ones(len(pairs)), -np.ones(len(pairs))]),
                            (np.concatenate([np.arange(len(pairs))] * 2), np.concatenate([pairs[:, 0], pairs[:, 1]]))), shape=(len(pairs), n_))
        wp = 200.0                               # crossings must meet: near-hard constraint
        A = (wp * (Pm.T @ Pm) + lam * (D.T @ D) + mu * sp.identity(n_)).tocsc()
        rhs = -wp * (Pm.T @ (Pm @ T['zc']))
        T['zc'] = T['zc'] + spsolve(A, rhs)
        gap = np.abs(T['zc'][pairs[:, 0]] - T['zc'][pairs[:, 1]])
        log(f'{len(pairs)} spots ridden twice; height difference after matching: max {gap.max():.2f} m')
    log(f'elevation: gain {T["gain"]:.0f} m, GPX-to-terrain offset median {np.median(off):+.1f} m')

    T['mis'] = np.abs(np.nan_to_num(dem_xy(T['x'], T['y']) - T['zc'], nan=0.0))      # cut/fill depth along the ride
    feats = parse(raws, P) if source == 'overpass' else vtiles.to_feats(vt, P)
    W = TR.World(feats, T, dem_xy, sea_from_terrain=(source == 'overpass'))
    log(f'map: {len(feats)} features, {len(W.roads)} roads ({len(W.strokes)} strokes), {len(W.buildings)} buildings, '
        f'{len(W.bridges)} bridges, {len(W.trees)} trees, {len(W.coast)} coastline pieces')

    # ---------------- chunks pass A: classes + heights
    chunks = near_keys
    log(f'{len(chunks)} chunks; mid ring {len(LP["mids"])} chunks in {len(LP["pages"])} pages')
    ws = {}
    for (cx, cy) in chunks:                     # A1: each chunk's own estimate of the water surface
        G = TR.ChunkGrid(cx, cy)
        cls, water_pre, bg, sea = TR.raster_classes(W, G)
        ws[(cx, cy)] = TR.water_sample(G, TR.dem_smoothed(W, G), water_pre, sea) if water_pre.any() else None
    # water never stands above the path the rider is on (land routes): cap each chunk's level by the ride height
    if guess_activity(gpx, T) != 'water':
        kx = np.floor(T['x'] / TR.CHUNK).astype(int); ky = np.floor(T['y'] / TR.CHUNK).astype(int)
        for k_, v_ in list(ws.items()):
            if v_ is None or v_ == 0.0: continue
            m_ = (kx == k_[0]) & (ky == k_[1])
            if m_.any(): ws[k_] = min(v_, float(T['zc'][m_].min()) - 0.6)
    t1 = time.time()
    pages = LOD.build_mid(T, P, LP, mid_vt, dem_xy, mlat)
    del mid_vt
    for k_, v_ in LOD.level_samples(pages).items(): ws.setdefault(k_, v_)
    log(f'mid ring pass 1: {time.time() - t1:.0f} s')
    LF = TR.LevelField(ws)
    if guess_activity(gpx, T) != 'water' and LF.grid is not None:
        left = LF.cap(T['x'], T['y'], T['zc'] - 0.5)
        if left: log(f'water level still above the ride at {left} samples')
    C = {}
    for (cx, cy) in chunks:                     # A2: ground tags, water, roads, ride corridor (recomputed: keeps memory low)
        G = TR.ChunkGrid(cx, cy)
        cls, water_pre, bg, sea = TR.raster_classes(W, G)
        h, sd, roadmask, level, surf = TR.heights(W, G, cls, water_pre, sea, TR.dem_smoothed(W, G), LF)
        k = (cx, cy)
        if f'{cx},{cy}' in os.environ.get('RB_DEBUG_CHUNK', '').split(';'):
            np.savez(os.path.join(out_dir, f'debug_chunk_{cx}_{cy}.npz'), cls=cls, water_pre=water_pre, h=h, sd=sd, road=roadmask,
                     dem=TR.dem_smoothed(W, G), **getattr(TR, '_dbg', {}))
        C[k] = {'G': G, 'cls': TR.crop_c(G, cls).copy(), 'h': TR.crop_h(G, h).astype(np.float32), 'sd': TR.crop_h(G, sd).astype(np.float32),
                'road': TR.crop_h(G, roadmask).copy(), 'level': level, 'bg': bg}
        wcrop = TR.crop_c(G, cls) == ID['water']
        if surf is not None and wcrop.any():
            C[k]['wsurf'] = TR.crop_h(G, surf)[::8, ::8].astype(np.float32)        # 33 x 33, 8 m apart
            wm8 = np.pad(wcrop[::16, ::16], ((0, 1), (0, 1)), mode='edge')            # water cells on the 8 m grid
            C[k]['level'] = float(C[k]['wsurf'][wm8].min()) if wm8.any() else float(C[k]['wsurf'].min())
        else:
            C[k]['level'] = None

    def lookup(key, x, y, res, default=np.nan):
        x = np.asarray(x, float); y = np.asarray(y, float); out = np.full(x.shape, default, float)
        cxs = np.floor(x / TR.CHUNK).astype(int); cys = np.floor(y / TR.CHUNK).astype(int)
        for k in set(zip(cxs.ravel().tolist(), cys.ravel().tolist())):
            c = C.get(k)
            if c is None: continue
            m = (cxs == k[0]) & (cys == k[1]); a = c[key]
            j = np.clip(((x[m] - k[0] * TR.CHUNK) / res).astype(int), 0, a.shape[1] - 1)
            i = np.clip((((k[1] + 1) * TR.CHUNK - y[m]) / res).astype(int), 0, a.shape[0] - 1)
            out[m] = a[i, j]
        return out
    ground = lambda x, y: lookup('h', x, y, TR.HRES)

    # ---------------- bridges: one smooth deck from bank to bank, gentle arch over water
    bridges = []
    trk_tree = cKDTree(np.stack([T['x'], T['y']], 1))
    # the track at 1 m spacing: trees are kept off it (the rider and the camera pass there)
    _tx, _ty = np.asarray(T['x'], float), np.asarray(T['y'], float)
    _f = np.linspace(0, 1, 6)[:-1]
    trk_dense = cKDTree(np.stack([(_tx[:-1, None] * (1 - _f) + _tx[1:, None] * _f).ravel(),
                                  (_ty[:-1, None] * (1 - _f) + _ty[1:, None] * _f).ravel()], 1))
    TREE_CLEAR = 2.5
    for b in W.bridges:
        p = np.array(b['p'])
        if len(p) < 2: continue
        seg = np.hypot(*np.diff(p, axis=0).T); L = seg.sum()
        if L < 1: continue
        dd = np.concatenate([[0], np.cumsum(seg)]); n = max(2, int(L / 2) + 1); s = np.linspace(0, L, n)
        xs = np.interp(s, dd, p[:, 0]); ys = np.interp(s, dd, p[:, 1])
        if np.isnan(ground(xs, ys)).all(): continue
        # anchors: ground just beyond both ends (along the bridge direction)
        def beyond(i0, i1):
            dx, dy = xs[i0] - xs[i1], ys[i0] - ys[i1]; l = math.hypot(dx, dy) or 1
            return xs[i0] + dx / l * 2, ys[i0] + dy / l * 2
        za = ground(*beyond(0, 1)); zb = ground(*beyond(-1, -2))
        za = float(za) if np.isfinite(za) else float(np.nanmax(ground(xs, ys)))
        zb = float(zb) if np.isfinite(zb) else za
        # an end the route rides on/off: meet the rider's height there (ground beside water can be a quay or a dip)
        for end in (0, -1):
            dd_, ii_ = trk_tree.query([xs[end], ys[end]])
            if dd_ < 6.0:
                zr = float(T['zc'][ii_]); zg = za if end == 0 else zb
                if abs(zr - zg) < 3.0:
                    if end == 0: za = zr
                    else: zb = zr
        base = za + (zb - za) * s / L
        sdv = np.nan_to_num(lookup('sd', xs, ys, TR.HRES, 5.0), nan=5.0)
        u = np.clip(-sdv / 35.0, 0, 1)
        arch = ndimage.gaussian_filter1d(1.3 * u * u * (3 - 2 * u), 3, mode='nearest')
        pz = base + arch + 0.2
        bridges.append({'p': [[round(float(a), 2), round(float(c), 2)] for a, c in zip(xs, ys)],
                        'pz': [round(float(z), 2) for z in pz], 'w': round(b['w'], 1), 'tag': b['tag'],
                        'name': b['g'].get('name', '')})

    # ---------------- chunks pass C: abutments under bridge ends + deck surface on the ground there
    for k, c in C.items():
        G = c['G']; n = c['h'].shape[0]; ox = k[0] * TR.CHUNK; oy = (k[1] + 1) * TR.CHUNK
        zimg = np.full((n, n), -1e9); clsimg = Image.fromarray(c['cls']); dr = ImageDraw.Draw(clsimg)
        for b in bridges:
            p = np.array(b['p'])
            if p[:, 0].max() < ox - 20 or p[:, 0].min() > ox + TR.CHUNK + 20 or p[:, 1].max() < oy - TR.CHUNK - 20 or p[:, 1].min() > oy + 20:
                continue
            # fill 3 m past each end too, so the bank meets the deck instead of dipping at the quay edge
            def ext(i0, i1):
                dx, dy = p[i0] - p[i1]; l = math.hypot(dx, dy) or 1
                return p[i0] + np.array([dx, dy]) / l * 3.0
            pz_ = list(b['pz'])
            def zext(i0, i1):        # continue the deck's own slope past the end (flat stays flat, a descent keeps descending)
                L_ = math.hypot(*(p[i0] - p[i1])) or 1
                return pz_[i0] + (pz_[i0] - pz_[i1]) / L_ * 3.0
            pe = np.vstack([ext(0, 1), p, ext(-1, -2)]); ze = [zext(0, 1)] + pz_ + [zext(-1, -2)]
            for (x0, y0), (x1, y1), z0, z1 in zip(pe[:-1], pe[1:], ze[:-1], ze[1:]):
                L = math.hypot(x1 - x0, y1 - y0); m = max(1, int(L))
                for t in np.linspace(0, 1, m + 1):
                    x, y, z = x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, z0 + (z1 - z0) * t
                    r = b['w'] / 2 + 0.5
                    # cells whose centre lies within the deck footprint (same rule in every chunk, so edges agree)
                    j0, j1 = math.ceil((x - r - ox) / TR.HRES), math.floor((x + r - ox) / TR.HRES) + 1
                    i0, i1 = math.ceil((oy - y - r) / TR.HRES), math.floor((oy - y + r) / TR.HRES) + 1
                    j0, i0 = max(0, j0), max(0, i0); j1, i1 = min(n, j1), min(n, i1)
                    if j0 < j1 and i0 < i1: zimg[i0:i1, j0:j1] = np.maximum(zimg[i0:i1, j0:j1], z)
            q = [((x - ox) / TR.CRES, (oy - y) / TR.CRES) for x, y in b['p']]
            dr.line(q, fill=ID[b['tag']], width=max(1, int(b['w'] / TR.CRES)))
        has = zimg > -1e8
        if not has.any(): continue
        h, sd, road = c['h'], c['sd'], c['road']
        # keep real underpasses open (a road far below the deck), unless the rider rides there at deck height
        zr = np.full((n, n), -1e9)
        mt = (T['x'] > ox - 5) & (T['x'] < ox + TR.CHUNK + 5) & (T['y'] > oy - TR.CHUNK - 5) & (T['y'] < oy + 5)
        for tx_, ty_, tz_ in zip(T['x'][mt], T['y'][mt], T['zc'][mt]):
            jc, ic = int(round((tx_ - ox) / TR.HRES)), int(round((oy - ty_) / TR.HRES))
            zr[max(0, ic - 3):max(0, ic + 4), max(0, jc - 3):max(0, jc + 4)] = np.maximum(zr[max(0, ic - 3):max(0, ic + 4), max(0, jc - 3):max(0, jc + 4)], tz_)
        rider_on_top = (zr > zimg - 1.5) & (sd > -4.0)
        # fill only the bank ends (2 m into the water; 4 m where the rider comes off the deck onto a quay):
        # the water stays open under the bridge, whatever the river's width
        abut = has & (((sd > -2.0) & ~(road & (h < zimg - 2.0))) | rider_on_top)
        c['h'] = np.where(abut, np.maximum(h, zimg - 0.35), h)
        under_water = np.kron(~abut, np.ones((2, 2), bool))[:c['cls'].shape[0], :c['cls'].shape[1]]
        newcls = np.array(clsimg)
        c['cls'] = np.where(under_water, c['cls'], newcls)

    # ---------------- what's under the rider, towns, climbs, sprints
    tag_under = lookup('cls', T['x'], T['y'], TR.CRES, ID['rural']).astype(int)
    on_bridge = np.zeros(len(T['s']), bool)
    if bridges:
        bp = np.concatenate([np.array(b['p']) for b in bridges]); bw = np.concatenate([[b['w']] * len(b['p']) for b in bridges])
        tree = cKDTree(bp); dist, idx = tree.query(np.stack([T['x'], T['y']], 1))
        on_bridge = dist < bw[idx] / 2
        # a bridge split in two in OSM leaves a 5-10 m hole over the water: the rider is still on the bridge there
        on_bridge = ndimage.binary_closing(on_bridge, np.ones(5, bool)) | on_bridge
    water_frac = float(np.mean((tag_under == ID['water']) & ~on_bridge))
    # ferries: stretches of a land route that cross open water (e.g. a harbour ferry in the GPX)
    on_water = (tag_under == ID['water']) & ~on_bridge
    crossings = []
    if water_frac <= 0.6:
        i = 0; n_ = len(on_water)
        while i < n_:
            if on_water[i]:
                j = i
                while j + 1 < n_ and on_water[j + 1]: j += 1
                if (j - i + 1) * STEP >= 40:
                    crossings.append({'start_m': round(float(T['s'][i])), 'end_m': round(float(T['s'][j])), 'length_m': round((j - i + 1) * STEP)})
                i = j + 1
            else: i += 1
    # a real crossing reaches the other side; a GPX that heads out over the water and comes back the same way
    # (routing engines following ferry lines to nowhere, bad tracks) is not something you can ride or walk
    unusable = []
    for c_ in crossings:
        a, e = int(c_['start_m'] / STEP), int(c_['end_m'] / STEP)
        far = float(np.max(np.hypot(T['x'][a:e + 1] - T['x'][a], T['y'][a:e + 1] - T['y'][a])))
        back = float(np.hypot(T['x'][e] - T['x'][a], T['y'][e] - T['y'][a]))
        c_['dead_end'] = bool(far > 150 and back < max(60, 0.3 * far))
        if c_['dead_end']:
            unusable.append(f"goes {far:.0f} m out over the water at {c_['start_m'] / 1000:.1f} km and turns back")
    if water_frac <= 0.6 and water_frac > 0.2:
        unusable.append(f"{water_frac * 100:.0f}% of this land route is on water")
    for u in unusable: log('NOT USABLE: ' + u)
    ferry = np.zeros(len(T['s']), bool)
    for c_ in crossings: ferry[int(c_['start_m'] / STEP):int(c_['end_m'] / STEP) + 1] = True
    towns = []
    for pl in W.places:
        d = np.hypot(T['x'] - pl['x'], T['y'] - pl['y']); i = int(np.argmin(d))
        if d[i] < 500 and pl['name'] and all(abs(t['at_m'] - T['s'][i]) > 800 for t in towns):
            towns.append({'name': pl['name'], 'kind': pl['kind'], 'at_m': round(float(T['s'][i]))})
    towns.sort(key=lambda t: t['at_m'])
    climbs = find_climbs(T); sprints = find_sprints(T, towns)
    surf = {}
    for t in tag_under[~on_bridge & ~ferry]:
        name = RIDE_SURFACE.get(TAGS[t], 'off-road' if TAGS[t] != 'water' else 'water')
        surf[name] = surf.get(name, 0) + 1
    tot = max(1, sum(surf.values())); surf = {k: round(v * 100 / tot) for k, v in sorted(surf.items(), key=lambda kv: -kv[1])}
    activity = 'water' if water_frac > 0.6 else guess_activity(gpx, T)
    paved = surf.get('asphalt', 0) + surf.get('paved', 0)
    rough = surf.get('gravel', 0) + surf.get('dirt', 0) + surf.get('off-road', 0) + surf.get('rock', 0) + surf.get('grass', 0)
    bike = ('boat' if activity == 'water' else 'on_foot' if activity in ('run', 'walk') else
            'road' if paved >= 75 else 'mtb' if rough >= 35 else 'gravel' if rough >= 12 else 'road')

    # ---------------- objects per chunk
    # ---------------- near chunks: make shared edges identical (tiny rasterisation drift between chunk windows)
    raw_seam = 0.0; raw_at = None; acc_e = {}
    nn = int(round(TR.CHUNK / TR.HRES))
    for (cx, cy), c in C.items():
        hh = c['h']
        for side, vals in (('W', hh[:, 0]), ('E', hh[:, -1]), ('N', hh[0, :]), ('S', hh[-1, :])):
            for t, v in enumerate(vals):
                X = cx * nn + (0 if side == 'W' else nn if side == 'E' else t)
                Y = (cy + 1) * nn - (t if side in 'WE' else 0 if side == 'N' else nn)
                acc_e.setdefault((X, Y), []).append(float(v))
    for (cx, cy), c in C.items():
        hh = c['h']
        for side in 'WENS':
            for t in range(nn + 1):
                X = cx * nn + (0 if side == 'W' else nn if side == 'E' else t)
                Y = (cy + 1) * nn - (t if side in 'WE' else 0 if side == 'N' else nn)
                vs = acc_e[(X, Y)]
                if len(vs) > 1:
                    if max(vs) - min(vs) > raw_seam: raw_seam = max(vs) - min(vs); raw_at = (X * TR.HRES, Y * TR.HRES)
                    m_ = sum(vs) / len(vs)
                    i_, j_ = (t, 0) if side == 'W' else (t, nn) if side == 'E' else (0, t) if side == 'N' else (nn, t)
                    hh[i_, j_] = m_
    log(f'near chunk edges joined (largest raw difference {raw_seam:.2f} m at {raw_at})')

    # ---------------- mid and far rings: heights, shared edges
    t1 = time.time()
    LOD.mid_heights(pages, dem_xy, LF)
    LOD.stitch(pages, C)
    far = LOD.build_far(T, P, LP, far_vt, dem11, dem_xy); del far_vt
    nb_, ni_ = LOD.far_join(far, C, pages)
    log(f'mid ring pass 2 + far: {time.time() - t1:.0f} s (far {far["h"].shape[1]}x{far["h"].shape[0]}, {nb_} border vertices joined)')
    os.makedirs(os.path.join(out_dir, 'chunks'), exist_ok=True)

    def wgrid(a, fname, sub):
        """Water surface grid (8 m, north row first); draw it only where the ground tag is water."""
        lo, hi = float(a.min()), float(a.max()); sc = max(0.005, (hi - lo) / 65535.0)
        np.round((a - lo) / sc).clip(0, 65535).astype('<u2').tofile(os.path.join(out_dir, sub, fname))
        return {'file': fname, 'n': int(a.shape[0]), 'res': 8.0, 'base': round(lo, 3), 'scale': sc, 'rows': 'north_to_south'}
    rng_for = lambda k: np.random.default_rng(abs(hash(k)) % (2 ** 32))
    chunk_index = []
    tree_kind = lambda g: ('conifer' if g.get('leaf_type') == 'needleleaved' else 'palm' if g.get('genus', '').lower() in ('phoenix', 'washingtonia', 'cocos', 'trachycarpus', 'chamaerops') else 'broadleaf')
    for k, c in sorted(C.items()):
        G = c['G']; ox, oy = k[0] * TR.CHUNK, k[1] * TR.CHUNK
        inside = lambda x, y: ox <= x < ox + TR.CHUNK and oy <= y < oy + TR.CHUNK
        rng = rng_for(k)
        blds = []
        for b in W.buildings:
            p = b['p']; cx_ = sum(q[0] for q in p) / len(p); cy_ = sum(q[1] for q in p) / len(p)
            if not inside(cx_, cy_): continue
            pts = p[:-1] if p[0] == p[-1] else p
            area = 0.5 * abs(sum(pts[i][0] * pts[(i + 1) % len(pts)][1] - pts[(i + 1) % len(pts)][0] * pts[i][1] for i in range(len(pts))))
            if area < 6: continue
            g = b['g']
            try: ht = float(re.findall(r'[\d.]+', g['height'])[0])
            except Exception:
                try: ht = float(g['building:levels']) * 3.2 + 1.2
                except Exception:
                    kind = g.get('building')
                    ht = {'church': 22, 'cathedral': 30, 'garage': 3, 'garages': 3, 'shed': 3, 'kiosk': 3, 'hut': 3, 'cabin': 4,
                          'house': 7.5, 'detached': 7.5, 'farm_auxiliary': 6, 'barn': 8, 'industrial': 9, 'warehouse': 10,
                          'apartments': 16}.get(kind, 16 if c['bg'] == ID['urban'] else 7.5) + float(rng.integers(0, 3)) * 1.5
            zs = ground(np.array([q[0] for q in pts]), np.array([q[1] for q in pts]))
            base = float(np.nanmin(zs)) if np.isfinite(zs).any() else float(np.nanmean(c['h']))
            blds.append({'p': [[round(q[0], 2), round(q[1], 2)] for q in pts], 'h': round(ht, 1), 'base': round(base - 0.3, 2),
                         'kind': g.get('building', 'yes'), 'levels': g.get('building:levels'), 'roof': g.get('roof:shape'),
                         'roof_colour': g.get('roof:colour'), 'colour': g.get('building:colour'), 'v': int(rng.integers(0, 1000))})
        trees = []
        for t in W.trees:
            if inside(t['x'], t['y']): trees.append((t['x'], t['y'], tree_kind(t['g'])))
        for p in W.tree_rows:
            for a, b in zip(p, p[1:]):
                L = math.hypot(b[0] - a[0], b[1] - a[1])
                for i in range(int(L // 9) + 1):
                    f = i * 9 / max(L, 1e-6); x, y = a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f
                    if inside(x, y): trees.append((x, y, 'broadleaf'))
        cls = c['cls']
        dens = {ID['forest_floor']: 1 / 55, ID['scrub']: 1 / 140, ID['grass']: 1 / 650, ID['orchard']: 1 / 40,
                ID['wetland']: 1 / 300, ID['meadow']: 1 / 2500, ID['rural']: 1 / 3000, ID['dry_grass']: 1 / 1500}
        forest_conifer = abs(float(mlat)) > 50
        for tid, dn in dens.items():
            frac = float(np.mean(cls == tid))
            if frac == 0: continue
            nt = rng.poisson(TR.CHUNK * TR.CHUNK * frac * dn)
            xs = rng.uniform(0, TR.CHUNK, nt * 2); ys = rng.uniform(0, TR.CHUNK, nt * 2)
            ii = (ys / TR.CRES).astype(int).clip(0, cls.shape[0] - 1); jj = (xs / TR.CRES).astype(int).clip(0, cls.shape[1] - 1)
            ok = cls[ii, jj] == tid
            for x, y in list(zip(xs[ok], ys[ok]))[:nt]:
                kind = 'shrub' if tid in (ID['scrub'], ID['dry_grass']) else 'orchard' if tid == ID['orchard'] else \
                       ('conifer' if (forest_conifer or rng.random() < 0.35) and tid == ID['forest_floor'] else 'broadleaf')
                trees.append((ox + x, oy + TR.CHUNK - y, kind))
        if c['bg'] == ID['urban'] or len(blds) > 20:
            trees += [(x_, y_, 'broadleaf') for x_, y_ in street_trees(W, k, c['cls'], ox, oy, TR.CHUNK, TR.CRES, blds)]
        if trees:
            dtr, _ = trk_dense.query(np.array([(t[0], t[1]) for t in trees]))
            road_ids = {ID[n] for n in ('asphalt', 'cycleway', 'rail', 'parking') if n in ID}
            def on_road(x_, y_):
                ii_ = int(min(cls.shape[0] - 1, max(0, (oy + TR.CHUNK - y_) / TR.CRES)))
                jj_ = int(min(cls.shape[1] - 1, max(0, (x_ - ox) / TR.CRES)))
                return int(cls[ii_, jj_]) in road_ids
            trees = [t for t, d_ in zip(trees, dtr) if d_ >= TREE_CLEAR and not on_road(t[0], t[1])]
        tz = ground(np.array([t[0] for t in trees]), np.array([t[1] for t in trees])) if trees else []
        tree_out = [{'x': round(t[0], 1), 'y': round(t[1], 1), 'z': round(float(z), 2), 'kind': t[2], 'v': int(rng.integers(0, 1000)),
                     's': round(float(rng.uniform(0.8, 1.2)), 2)} for t, z in zip(trees, tz) if np.isfinite(z)]
        h = c['h']; lo, hi = float(np.min(h)), float(np.max(h))
        scale = max(0.01, (hi - lo) / 65535.0)
        q = np.round((h - lo) / scale).clip(0, 65535).astype('<u2')
        name = f'c_{k[0]}_{k[1]}'
        q.tofile(os.path.join(out_dir, 'chunks', name + '_h.bin'))
        Image.fromarray(c['cls'].astype(np.uint8)).save(os.path.join(out_dir, 'chunks', name + '_cls.png'), optimize=True)
        meta = {'cx': k[0], 'cy': k[1], 'x0': ox, 'y0': oy, 'size': TR.CHUNK,
                'height': {'file': name + '_h.bin', 'n': int(h.shape[0]), 'res': TR.HRES, 'base': round(lo, 3), 'scale': scale,
                           'rows': 'north_to_south'},
                'ground': {'file': name + '_cls.png', 'n': int(c['cls'].shape[0]), 'res': TR.CRES, 'rows': 'north_to_south'},
                'water_level': None if c['level'] is None else round(c['level'], 2),
                'water': None if c.get('wsurf') is None else dict(wgrid(c['wsurf'], name + '_w.bin', 'chunks'),
                                                                  flow=TR.flow_dir(W, ox, oy, ox + TR.CHUNK, oy + TR.CHUNK)),
                'buildings': blds, 'trees': tree_out}
        json.dump(meta, open(os.path.join(out_dir, 'chunks', name + '.json'), 'w'), separators=(',', ':'))
        chunk_index.append({'cx': k[0], 'cy': k[1], 'file': name + '.json'})

    # ---------------- mid pages
    os.makedirs(os.path.join(out_dir, 'mid'), exist_ok=True)
    page_index = []
    for pk, pg in sorted(pages.items()):
        name = f'p_{pk[0]}_{pk[1]}'; h = pg['h']; lo, hi = float(h.min()), float(h.max()); sc = max(0.01, (hi - lo) / 65535.0)
        np.round((h - lo) / sc).clip(0, 65535).astype('<u2').tofile(os.path.join(out_dir, 'mid', name + '_h.bin'))
        Image.fromarray(pg['cls'].astype(np.uint8)).save(os.path.join(out_dir, 'mid', name + '_cls.png'), optimize=True)
        hz = lambda x, y: LOD.page_h_at(pg, pk, x, y)
        blds = []
        for (bx, by, L1, L2, ang, ht) in pg['boxes']:
            a_ = math.radians(ang); ux, uy = math.cos(a_) * L1 / 2, math.sin(a_) * L1 / 2; vx, vy = -math.sin(a_) * L2 / 2, math.cos(a_) * L2 / 2
            base = min(hz(bx + sx * ux + sy * vx, by + sx * uy + sy * vy) for sx in (-1, 1) for sy in (-1, 1))
            blds.append([round(bx, 1), round(by, 1), round(L1, 1), round(L2, 1), round(ang, 1), round(ht, 1), round(base - 0.3, 2)])
        trees = [[round(t[0], 1), round(t[1], 1), round(hz(t[0], t[1]), 2), t[2], t[3]] for t in pg['trees']]
        meta = {'px': pk[0], 'py': pk[1], 'x0': pk[0] * LOD.PAGE, 'y0': pk[1] * LOD.PAGE, 'size': LOD.PAGE,
                'height': {'file': name + '_h.bin', 'n': int(h.shape[0]), 'res': LOD.MID_HRES, 'base': round(lo, 3), 'scale': sc, 'rows': 'north_to_south'},
                'ground': {'file': name + '_cls.png', 'n': int(pg['cls'].shape[0]), 'res': LOD.MID_CRES, 'rows': 'north_to_south'},
                'present': sorted([list(c) for c in pg['present']]),
                'water': None if pg['wsurf'] is None else wgrid(pg['wsurf'], name + '_w.bin', 'mid'),
                'water_chunks': pg['water_chunks'], 'water_flow': pg['water_flow'],
                'buildings_fields': ['x', 'y', 'length', 'width', 'angle_deg', 'height', 'base'], 'buildings': blds,
                'trees_fields': ['x', 'y', 'z', 'kind', 'v'], 'trees': trees}
        json.dump(meta, open(os.path.join(out_dir, 'mid', name + '.json'), 'w'), separators=(',', ':'))
        page_index.append({'px': pk[0], 'py': pk[1], 'file': name + '.json', 'n': len(pg['present'])})

    # ---------------- far terrain (whole area, 32 m heights + 16 m ground tags)
    fh = far['h']; fG = far['G']
    flo, fhi = float(fh.min()), float(fh.max()); fsc = max(0.05, (fhi - flo) / 65535.0)
    np.round((fh - flo) / fsc).clip(0, 65535).astype('<u2').tofile(os.path.join(out_dir, 'far_h.bin'))
    Image.fromarray(far['cls'].astype(np.uint8)).save(os.path.join(out_dir, 'far_cls.png'), optimize=True)
    nx, ny, fres, fx0, fy1 = int(fh.shape[1]), int(fh.shape[0]), LOD.FAR_HRES, float(fG.x0), float(fG.y1)

    # ---------------- overview map for the route picker
    mx0, mx1 = T['x'].min() - 400, T['x'].max() + 400; my0, my1 = T['y'].min() - 400, T['y'].max() + 400
    mres = max(4.0, max(mx1 - mx0, my1 - my0) / 1024)
    mw, mh = int((mx1 - mx0) / mres) + 1, int((my1 - my0) / mres) + 1
    gxm, gym = np.meshgrid(mx0 + (np.arange(mw) + .5) * mres, my1 - (np.arange(mh) + .5) * mres)
    tags_img = lookup('cls', gxm.ravel(), gym.ravel(), TR.CRES, 255).reshape(gxm.shape).astype(int)
    pal = np.array(MAP_COLOURS + [[236, 232, 222]] * (256 - len(MAP_COLOURS)), np.uint8)
    mapimg = Image.fromarray(pal[np.clip(tags_img, 0, 255)])
    d = ImageDraw.Draw(mapimg)
    d.line([((x - mx0) / mres, (my1 - y) / mres) for x, y in zip(T['x'][::4], T['y'][::4])], fill=(220, 60, 40), width=max(2, int(6 / mres * 2)))
    sx, sy = (T['x'][0] - mx0) / mres, (my1 - T['y'][0]) / mres
    d.ellipse([sx - 5, sy - 5, sx + 5, sy + 5], fill=(40, 160, 60), outline=(255, 255, 255))
    mapimg.save(os.path.join(out_dir, 'map.png'), optimize=True)

    # ---------------- on the water (water routes, ferries): the rider floats on the surface, not at the GPX height
    afloat = ((tag_under == ID['water']) & ~on_bridge & (np.full(len(T['s']), activity == 'water') | ferry))
    if afloat.any():
        zs = T['zc'].copy()
        for i_ in np.nonzero(afloat)[0]:
            k_ = (int(math.floor(T['x'][i_] / TR.CHUNK)), int(math.floor(T['y'][i_] / TR.CHUNK))); c_ = C.get(k_)
            if c_ is None or c_.get('wsurf') is None: continue
            Wg = c_['wsurf']; n_ = Wg.shape[0]
            fj = (T['x'][i_] - k_[0] * TR.CHUNK) / 8.0; fi = ((k_[1] + 1) * TR.CHUNK - T['y'][i_]) / 8.0
            j0, i0 = min(n_ - 2, int(fj)), min(n_ - 2, int(fi)); u, v = fj - j0, fi - i0
            zs[i_] = Wg[i0, j0] * (1 - u) * (1 - v) + Wg[i0, j0 + 1] * u * (1 - v) + Wg[i0 + 1, j0] * (1 - u) * v + Wg[i0 + 1, j0 + 1] * u * v
        # ease in and out over a few samples where the rider goes from shore to water, never below the ground
        w_ = ndimage.gaussian_filter1d(afloat.astype(float), 2.0, mode='nearest')
        gz = np.nan_to_num(ground(T['x'], T['y']), nan=-1e9)
        T['zc'] = np.maximum(T['zc'] * (1 - w_) + zs * w_, np.where(on_bridge, -1e9, gz))

    # ---------------- track + route meta
    idx = np.arange(len(T['s']))
    track = {'step': STEP, 'n': len(idx), 's': _r(T['s'], 1), 'x': _r(T['x'], 2), 'y': _r(T['y'], 2),
             'z': _r(T['zc'], 2), 'z_gpx': _r(T['z'], 2), 'grade': _r(T['grade'] * 100, 1),
             'ground': tag_under.tolist(), 'bridge': [int(v) for v in on_bridge], 'ferry': [int(v) for v in ferry]}
    json.dump(track, open(os.path.join(out_dir, 'track.json'), 'w'), separators=(',', ':'))
    json.dump(bridges, open(os.path.join(out_dir, 'bridges.json'), 'w'), separators=(',', ':'))
    prof_i = np.linspace(0, len(T['s']) - 1, 240).astype(int)
    route = {
        'format': FORMAT_VERSION, 'builder': BUILDER_VERSION, 'built': time.strftime('%Y-%m-%d'),
        'id': slug(gpx['name']), 'name': gpx['name'], 'description': _clean(gpx['desc']), 'source_file': os.path.basename(gpx_path),
        'activity': activity, 'recommended': bike,
        'origin': {'lat': round(P.lat0, 7), 'lon': round(P.lon0, 7), 'projection': 'equirectangular, x east / y north in metres'},
        'distance_m': round(T['length']), 'gain_m': round(T['gain']), 'loss_m': round(T['loss']),
        'ele_min_m': round(float(T['zc'].min())), 'ele_max_m': round(float(T['zc'].max())),
        'loop': bool(math.hypot(T['x'][-1] - T['x'][0], T['y'][-1] - T['y'][0]) < 300),
        'surfaces_pct': surf, 'water_pct': round(water_frac * 100),
        'climbs': climbs, 'sprints': sprints, 'towns': towns, 'water_crossings': crossings, 'usable': not unusable, 'unusable_reasons': unusable,
        'profile': {'s': _r(T['s'][prof_i], 0), 'z': _r(T['zc'][prof_i], 1)},
        'climate': clim,
        'ground_tags': TAGS,
        'chunk_size': TR.CHUNK, 'chunks': chunk_index,
        'mid': {'page_size': LOD.PAGE, 'chunk_size': TR.CHUNK, 'pages': page_index},
        'far': {'ground': {'file': 'far_cls.png', 'nx': int(far['cls'].shape[1]), 'ny': int(far['cls'].shape[0]), 'res': LOD.FAR_CRES},
                'covered_drop_m': 25.0, 'file': 'far_h.bin', 'nx': nx, 'ny': ny, 'res': fres, 'x0': fx0, 'y1': fy1, 'base': round(flo, 2), 'scale': fsc,
                'rows': 'north_to_south'},
        'files': {'track': 'track.json', 'bridges': 'bridges.json', 'map': 'map.png'},
        'notes': T['notes'],
        'attribution': ['Map data © OpenStreetMap contributors (ODbL), tiles by OpenFreeMap / OpenMapTiles', 'Elevation: Terrain Tiles (Mapzen/AWS Open Data; SRTM, ETOPO1 and others)',
                        'Weather: Open-Meteo.com (CC BY 4.0), ERA5'],
    }
    json.dump(route, open(os.path.join(out_dir, 'route.json'), 'w'), indent=1)
    log(f'done in {time.time() - t0:.0f} s -> {out_dir}')
    return {'status': 'ok', 'route': route}


MAP_COLOURS = [[200, 190, 178], [132, 186, 92], [96, 140, 80], [92, 150, 200], [120, 120, 124], [210, 204, 192],
               [170, 150, 130], [190, 178, 150], [232, 216, 168], [190, 110, 100], [160, 125, 90], [140, 130, 120],
               [150, 196, 110], [205, 190, 120], [78, 120, 64], [168, 200, 112], [160, 155, 150], [246, 248, 252],
               [120, 160, 140], [150, 175, 90], [196, 206, 150], [150, 150, 154], [196, 190, 120]]


def _r(a, n):
    return [round(float(v), n) for v in a]


def _clean(s):
    return re.sub(r'\s+', ' ', s or '').strip()[:500]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('gpx'); ap.add_argument('--out', required=True); ap.add_argument('--cache', default='cache')
    ap.add_argument('--plan'); ap.add_argument('--max-km', type=float); ap.add_argument('--dem-zoom', type=int, default=13)
    ap.add_argument('--source', choices=['tiles', 'overpass'], default='tiles')
    a = ap.parse_args()
    r = build(a.gpx, a.out, a.cache, a.plan, a.max_km, a.dem_zoom, a.source)
    print(json.dumps({k: v for k, v in r.items() if k != 'route'}))
    sys.exit(0 if r['status'] in ('ok', 'needs_data') else 1)


if __name__ == '__main__':
    main()
