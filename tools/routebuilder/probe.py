"""Print ride/ground/GPX heights around a distance on a built route. usage: python -m routebuilder.probe routes/ID METRES"""
import json, math, sys
import numpy as np
from .check import load_chunks
d, at = sys.argv[1], float(sys.argv[2])
R = json.load(open(d + '/route.json')); T = json.load(open(d + '/track.json')); C = load_chunks(d, R); cs = R['chunk_size']
def ground(px, py):
    c = C.get((int(math.floor(px / cs)), int(math.floor(py / cs))))
    if c is None: return float('nan')
    n = c['height']['n']; j = px - c['x0']; i = c['y0'] + cs - py; j0 = min(n - 2, int(j)); i0 = min(n - 2, int(i)); fx, fy = j - j0, i - i0; H = c['H']
    return H[i0, j0] * (1 - fx) * (1 - fy) + H[i0, j0 + 1] * fx * (1 - fy) + H[i0 + 1, j0] * (1 - fx) * fy + H[i0 + 1, j0 + 1] * fx * fy
k0 = int(at / 5)
for k in range(max(0, k0 - 6), min(T['n'], k0 + 7)):
    x, y = T['x'][k], T['y'][k]; c = (int(math.floor(x / cs)), int(math.floor(y / cs)))
    print(int(T['s'][k]), f"x {x:8.1f} y {y:8.1f} chunk {c}  ground {ground(x, y):8.2f}  ride {T['z'][k]:8.2f}  gpx {T['z_gpx'][k]:8.2f}  {R['ground_tags'][T['ground'][k]]}{' BRIDGE' if T['bridge'][k] else ''}{' FERRY' if T.get('ferry', [0]*T['n'])[k] else ''}")
