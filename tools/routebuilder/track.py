"""Turn GPX segments into one evenly spaced track in local metres, with elevation, grade and ride features."""
import math
import numpy as np
from scipy import ndimage

STEP = 5.0  # metres between track samples


class Proj:
    """Local equirectangular projection around the route origin (x east, y north, metres)."""
    def __init__(self, lat0, lon0):
        self.lat0, self.lon0 = lat0, lon0
        self.kx = math.cos(math.radians(lat0)) * 111320.0; self.ky = 110540.0

    def fwd(self, lat, lon):
        return (np.asarray(lon) - self.lon0) * self.kx, (np.asarray(lat) - self.lat0) * self.ky

    def inv(self, x, y):
        return self.lat0 + np.asarray(y) / self.ky, self.lon0 + np.asarray(x) / self.kx


def build_track(gpx, max_km=None):
    segs = gpx['segments']
    lat0, lon0 = segs[0][0][0], segs[0][0][1]
    P = Proj(lat0, lon0)
    notes = []
    pts = []
    for si, s in enumerate(segs):
        if si and pts:
            a, b = pts[-1], s[0]
            gx, gy = P.fwd([a[0], b[0]], [a[1], b[1]])
            gap = math.hypot(gx[1] - gx[0], gy[1] - gy[0])
            notes.append(f'segment {si + 1} starts {gap:.0f} m from the end of segment {si}; joined with a straight line')
        pts.extend(s)
    lat = np.array([p[0] for p in pts]); lon = np.array([p[1] for p in pts])
    ele = np.array([np.nan if p[2] is None else p[2] for p in pts], float)
    x, y = P.fwd(lat, lon)
    d = np.concatenate([[0], np.cumsum(np.hypot(np.diff(x), np.diff(y)))])
    keep = np.concatenate([[True], np.diff(d) > 0.05])          # drop repeated points
    x, y, ele, d = x[keep], y[keep], ele[keep], d[keep]
    if max_km:
        m = d <= max_km * 1000 + STEP
        x, y, ele, d = x[m], y[m], ele[m], d[m]
    L = d[-1]
    s = np.arange(0, L + 1e-6, STEP)
    xs = np.interp(s, d, x); ys = np.interp(s, d, y)
    good = ~np.isnan(ele)
    has_ele = good.mean() > 0.8 and np.nanmax(ele) - np.nanmin(ele) > 0.5 if good.any() else False
    if good.sum() >= 2:
        es = np.interp(s, d[good], ele[good])
    else:
        es = np.full_like(s, np.nan)
    return {'proj': P, 's': s, 'x': xs, 'y': ys, 'ele_raw': es, 'has_ele': bool(has_ele), 'length': float(L), 'notes': notes}


def finish_elevation(T, dem_sample):
    """Fill elevation from the DEM when the GPX has none, smooth it and compute grade."""
    if not T['has_ele']:
        T['ele_raw'] = dem_sample(T['x'], T['y'])
        T['notes'].append('the GPX has no usable elevation; using terrain elevation along the route')
    z = ndimage.gaussian_filter1d(T['ele_raw'], 15.0 / STEP, mode='nearest')
    zs = ndimage.gaussian_filter1d(T['ele_raw'], 40.0 / STEP, mode='nearest')
    g = np.gradient(zs, STEP)
    T['z'] = z; T['grade'] = np.clip(g, -0.35, 0.35)
    dz = np.diff(z)
    T['gain'] = float(dz[dz > 0].sum()); T['loss'] = float(-dz[dz < 0].sum())
    return T


def find_climbs(T):
    """Climbs = rises of >= 25 m at >= 3 % average, merged across short dips. Category like the big tours."""
    z = ndimage.gaussian_filter1d(T['z'], 60.0 / STEP, mode='nearest'); s = T['s']
    # turning points with 8 m hysteresis
    turns = [0]; direction = 0; ext = 0
    for i in range(1, len(z)):
        if direction >= 0:
            if z[i] > z[ext]: ext = i
            elif z[ext] - z[i] > 8: turns.append(ext); direction = -1; ext = i
        if direction < 0:
            if z[i] < z[ext]: ext = i
            elif z[i] - z[ext] > 8: turns.append(ext); direction = 1; ext = i
    turns.append(len(z) - 1)
    rises = []
    for a, b in zip(turns, turns[1:]):
        if z[b] > z[a]: rises.append([a, b])
    merged = []
    for r in rises:  # merge rises separated by a dip of < 15 m
        if merged and z[r[0]] > z[merged[-1][1]] - 15 and s[r[0]] - s[merged[-1][1]] < 1500:
            merged[-1][1] = r[1]
        else:
            merged.append(r)
    climbs = []
    for a, b in merged:
        gain = z[b] - z[a]; length = s[b] - s[a]
        if length < 200 or gain < 25: continue
        avg = gain / length
        if avg < 0.03: continue
        score = length * avg * 100
        cat = 'HC' if score >= 80000 else '1' if score >= 64000 else '2' if score >= 32000 else '3' if score >= 16000 else '4' if score >= 8000 else 'uncat'
        steep = np.max(np.gradient(z[a:b + 1], STEP)) if b > a + 2 else avg
        climbs.append({'start_m': round(float(s[a])), 'end_m': round(float(s[b])), 'length_m': round(float(length)),
                       'gain_m': round(float(gain)), 'avg_grade': round(float(avg) * 100, 1),
                       'max_grade': round(float(steep) * 100, 1), 'category': cat})
    return climbs


def find_sprints(T, towns):
    """One sprint roughly every 15 km: the flattest, straightest 400 m stretch, preferring ones that end at a town sign."""
    s, x, y, g = T['s'], T['x'], T['y'], T['grade']
    n = int(400 / STEP); L = T['length']
    if L < 3000: return []
    out = []
    for k in range(max(1, int(L // 15000))):
        lo = int(len(s) * (k + 0.25) / max(1, int(L // 15000))); hi = int(len(s) * (k + 0.9) / max(1, int(L // 15000)))
        best = None
        for i in range(lo, min(hi, len(s) - n), 4):
            j = i + n
            straight = math.hypot(x[j] - x[i], y[j] - y[i]) / 400.0
            flat = float(np.mean(np.abs(g[i:j])))
            score = straight * 2 - flat * 20
            near_town = any(abs(t['at_m'] - s[j]) < 150 for t in towns)
            if near_town: score += 0.5
            if best is None or score > best[0]: best = (score, i, j, straight, flat)
        if best and best[3] > 0.85 and best[4] < 0.03:
            out.append({'start_m': round(float(s[best[1]])), 'end_m': round(float(s[best[2]])), 'length_m': 400})
    return out
