"""Automatic checks on a built route package. usage: python -m routebuilder.check routes/ID [...]"""
import json, math, os, sys
import numpy as np
from PIL import Image


WATER_ID = 3


def load_chunks(d, R):
    C = {}
    for c in R['chunks']:
        m = json.load(open(os.path.join(d, 'chunks', c['file'])))
        h = np.fromfile(os.path.join(d, 'chunks', m['height']['file']), '<u2').reshape(m['height']['n'], m['height']['n'])
        m['H'] = m['height']['base'] + h * m['height']['scale']
        m['G'] = np.array(Image.open(os.path.join(d, 'chunks', m['ground']['file'])))
        m['W'] = None
        if m.get('water'):
            w = np.fromfile(os.path.join(d, 'chunks', m['water']['file']), '<u2').reshape(m['water']['n'], m['water']['n'])
            m['W'] = m['water']['base'] + w * m['water']['scale']
        C[(c['cx'], c['cy'])] = m
    return C


def check_rings(d, R, C):
    """Mid pages and the far grid: shared vertices identical, no gaps in coverage."""
    if 'mid' not in R: return {}
    cs = R['chunk_size']; P = {}
    for e in R['mid']['pages']:
        m = json.load(open(os.path.join(d, 'mid', e['file'])))
        h = np.fromfile(os.path.join(d, 'mid', m['height']['file']), '<u2').reshape(m['height']['n'], m['height']['n'])
        m['H'] = m['height']['base'] + h * m['height']['scale']; P[(m['px'], m['py'])] = m
    def vmid(x, y):
        out = []
        for (px, py), m in P.items():
            j = (x - m['x0']) / m['height']['res']; i = (m['y0'] + m['size'] - y) / m['height']['res']; n = m['height']['n']
            if 0 <= j <= n - 1 and 0 <= i <= n - 1 and abs(j - round(j)) < 1e-6 and abs(i - round(i)) < 1e-6: out.append(m['H'][int(round(i)), int(round(j))])
        return out
    present = {tuple(c) for m in P.values() for c in m['present']}
    worst = 0.0
    # near chunk borders against mid vertices
    for (cx, cy), c in C.items():
        for k in range(0, 257, 4):
            for (i, j) in ((0, k), (256, k), (k, 0), (k, 256)):
                x = cx * cs + j; y = (cy + 1) * cs - i
                for v in vmid(x, y): worst = max(worst, abs(v - c['H'][i, j]))
    # page edges against each other
    for (px, py), m in P.items():
        e = P.get((px + 1, py))
        if e is not None: worst = max(worst, float(np.max(np.abs(m['H'][:, -1] - e['H'][:, 0]))))
        e = P.get((px, py + 1))
        if e is not None: worst = max(worst, float(np.max(np.abs(m['H'][0, :] - e['H'][-1, :]))))
    # coverage: near + mid must have no holes inside
    cov = set(C) | present
    xs = [k[0] for k in cov]; ys = [k[1] for k in cov]
    from scipy import ndimage
    g = np.zeros((max(ys) - min(ys) + 3, max(xs) - min(xs) + 3), bool)
    for k in cov: g[k[1] - min(ys) + 1, k[0] - min(xs) + 1] = True
    holes = int((ndimage.binary_fill_holes(g) & ~g).sum())
    overlap = len(set(C) & present)
    sizes = sum(os.path.getsize(os.path.join(d, 'mid', f)) for f in os.listdir(os.path.join(d, 'mid')))
    return {'mid_pages': len(P), 'mid_chunks': len(present), 'ring_seam_max_m': round(worst, 3), 'ring_holes': holes, 'ring_overlap': overlap,
            'mid_mb': round(sizes / 1e6, 1)}


def check(d):
    R = json.load(open(os.path.join(d, 'route.json'))); T = json.load(open(os.path.join(d, 'track.json')))
    C = load_chunks(d, R); cs = R['chunk_size']; out = {'route': R['name'], 'km': round(R['distance_m'] / 1000, 1), 'chunks': len(C)}
    x, y, z = np.array(T['x']), np.array(T['y']), np.array(T['z']); br = np.array(T['bridge'], bool)

    def ground(px, py):
        k = (int(math.floor(px / cs)), int(math.floor(py / cs))); c = C.get(k)
        if c is None: return None
        n = c['height']['n']; j = (px - c['x0']); i = (c['y0'] + cs - py)
        j0 = min(n - 2, int(j)); i0 = min(n - 2, int(i)); fx, fy = j - j0, i - i0; H = c['H']
        return H[i0, j0] * (1 - fx) * (1 - fy) + H[i0, j0 + 1] * fx * (1 - fy) + H[i0 + 1, j0] * (1 - fx) * fy + H[i0 + 1, j0 + 1] * fx * fy

    g = np.array([np.nan if (v := ground(a, b)) is None else v for a, b in zip(x, y)])
    out['missing_chunk_samples'] = int(np.isnan(g).sum())
    water = R['activity'] == 'water'
    fe = np.array(T.get('ferry', [0] * len(x)), bool)
    boat = fe | water
    ride = np.where(br | np.isnan(g) | boat, z, g)           # what the rider stands on
    if boat.any(): ride[boat] = np.nan                       # on a boat: no ground to check
    s = np.array(T['s']); w = 2                              # 10 m windows (5 m samples)
    gr = np.abs(ride[w:] - ride[:-w]) / (s[w:] - s[:-w])
    ok_ = len(gr) and np.isfinite(gr).any()          # a water route has no ground to measure
    i = int(np.nanargmax(gr)) if ok_ else 0
    out['steepest_10m_pct'] = round(float(gr[i]) * 100, 1) if ok_ else 0; out['steepest_at_m'] = int(s[i]) if ok_ else 0
    gpx_gr = np.abs(np.array(T['z_gpx'])[w:] - np.array(T['z_gpx'])[:-w]) / (s[w:] - s[:-w])
    out['gpx_steepest_10m_pct'] = round(float(np.nanmax(gpx_gr)) * 100, 1) if len(gpx_gr) else 0
    land = ~br & ~np.isnan(g) & ~boat
    dz = np.abs(g[land] - z[land]) if land.any() else np.array([0.0])
    # water surface above the rider (land routes, not on bridges or boats)
    wab = 0
    if not water:
        for k_, (a, b_, zr) in enumerate(zip(x, y, ride)):
            if br[k_] or boat[k_] or not np.isfinite(zr): continue
            c = C.get((int(math.floor(a / cs)), int(math.floor(b_ / cs))))
            if c is None or c.get('W') is None: continue
            gi = int((c['y0'] + cs - b_) / 2); gj = int((a - c['x0']) / 2)       # only where the ground is water (2 m)
            if not (c['G'][max(0, gi * 4 - 4):gi * 4 + 5, max(0, gj * 4 - 4):gj * 4 + 5] == WATER_ID).any(): continue
            Wg = c['W']; n_ = Wg.shape[0]; fj = (a - c['x0']) / c['water']['res']; fi = (c['y0'] + cs - b_) / c['water']['res']
            j0 = min(n_ - 2, int(fj)); i0 = min(n_ - 2, int(fi)); u = fj - j0; v = fi - i0
            lv = Wg[i0, j0] * (1 - u) * (1 - v) + Wg[i0, j0 + 1] * u * (1 - v) + Wg[i0 + 1, j0] * (1 - u) * v + Wg[i0 + 1, j0 + 1] * u * v
            if lv > zr + 0.2: wab += 1          # up to 20 cm: a ford
    out['water_above_ride_samples'] = wab
    out['ground_vs_track_max_m'] = round(float(dz.max()), 2); out['ground_vs_track_p95_m'] = round(float(np.percentile(dz, 95)), 2)
    # seams: neighbouring chunks share their edge row/column of heights
    worst = 0.0
    for (cx, cy), c in C.items():
        e = C.get((cx + 1, cy))
        if e is not None: worst = max(worst, float(np.max(np.abs(c['H'][:, -1] - e['H'][:, 0]))))
        e = C.get((cx, cy + 1))
        if e is not None: worst = max(worst, float(np.max(np.abs(c['H'][0, :] - e['H'][-1, :]))))
    out['chunk_seam_max_m'] = round(worst, 3)
    out.update(check_rings(d, R, C))
    out['buildings'] = sum(len(c['buildings']) for c in C.values()); out['trees'] = sum(len(c['trees']) for c in C.values())
    out['water_chunks'] = sum(1 for c in C.values() if c['water_level'] is not None)
    out['surfaces'] = R['surfaces_pct']; out['climbs'] = len(R['climbs']); out['towns'] = [t['name'] for t in R['towns']][:6]
    out['recommended'] = R['recommended']; out['activity'] = R['activity']; out['water_crossings'] = R.get('water_crossings', [])
    probs = [f'not usable: {r}' for r in R.get('unusable_reasons', [])]
    if out['missing_chunk_samples']: probs.append('route leaves the built chunks')
    if out['steepest_10m_pct'] > max(18, out['gpx_steepest_10m_pct'] + 6): probs.append('ride is much steeper than the GPX somewhere')
    if out['water_above_ride_samples']: probs.append('water surface above the rider')
    if out['ground_vs_track_p95_m'] > 1.0: probs.append('ground often differs from the ride height')
    if out['chunk_seam_max_m'] > 0.10: probs.append('height seams between chunks')
    if out.get('ring_seam_max_m', 0) > 0.10: probs.append('height seams between detail levels')
    if out.get('ring_holes'): probs.append('holes between detail levels')
    out['problems'] = probs
    return out


if __name__ == '__main__':
    for d in sys.argv[1:]:
        if not os.path.exists(os.path.join(d, 'route.json')): print(d, 'no route.json'); continue
        print(json.dumps(check(d)))
