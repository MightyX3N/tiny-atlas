"""OpenStreetMap data along the route corridor (Overpass), converted to local metres."""
import json, math
import numpy as np
from .fetch import Fetcher, OVERPASS

SEG_LEN = 1500.0      # metres of route per Overpass query
RADIUS = 450          # metres either side of the route

FILTERS = [
    'way[~"^(highway|building|landuse|natural|leisure|waterway|railway|amenity|man_made|place)$"~"."]',
    'relation[~"^(natural|landuse|leisure|building|water|waterway)$"~"."]',
    'node[~"^(natural|place)$"~"^(tree|city|town|village|hamlet|suburb|neighbourhood|quarter)$"]',
]
KEEP = ['highway', 'building', 'landuse', 'natural', 'leisure', 'waterway', 'railway', 'amenity', 'surface',
        'bridge', 'tunnel', 'layer', 'building:levels', 'height', 'name', 'water', 'man_made', 'area', 'lanes',
        'width', 'cycleway', 'service', 'roof:shape', 'roof:colour', 'building:colour', 'leaf_type', 'genus',
        'place', 'sport', 'crop', 'wetland', 'tracktype', 'smoothness', 'covered', 'population']


def corridor_queries(T):
    """One bounding-box query per 1.5 km of route (box of that piece + RADIUS). Box queries are fast on
    every Overpass server; relations come back whole so multipolygons can be joined."""
    P = T['proj']; s = T['s']; out = []
    n = max(1, int(math.ceil(T['length'] / SEG_LEN)))
    for k in range(n):
        m = (s >= k * SEG_LEN) & (s <= (k + 1) * SEG_LEN)
        x, y = T['x'][m], T['y'][m]
        la0, lo0 = P.inv(x.min() - RADIUS, y.min() - RADIUS); la1, lo1 = P.inv(x.max() + RADIUS, y.max() + RADIUS)
        bb = f'{la0:.5f},{lo0:.5f},{la1:.5f},{lo1:.5f}'
        parts = ''.join(f'{f}({bb});' for f in FILTERS)
        out.append(f'[out:json][timeout:180];({parts});out geom;')
    return out


def fetch_osm(F: Fetcher, T):
    raws, missing = [], 0
    for q in corridor_queries(T):
        key = F.key('osm', q)
        try:
            raws.append(json.loads(F.get(key, OVERPASS, body='data=' + _urlenc(q))))
        except Exception as e:
            if e.__class__.__name__ == 'Missing': missing += 1
            else: raise
    return raws, missing


def _urlenc(s):
    from urllib.parse import quote
    return quote(s, safe='')


def parse(raws, P):
    """Merge Overpass results into a list of features: {'t': 'n'|'w'|'r', 'id', 'g': tags, 'p': [[x,y],..] | 'm': [{'r','p'}]}."""
    seen = set(); feats = []
    kx, ky, lat0, lon0 = P.kx, P.ky, P.lat0, P.lon0
    conv = lambda g: [[(q['lon'] - lon0) * kx, (q['lat'] - lat0) * ky] for q in g if q]
    for raw in raws:
        for e in raw.get('elements', []):
            k = (e['type'], e['id'])
            if k in seen: continue
            seen.add(k)
            tags = {t: v for t, v in (e.get('tags') or {}).items() if t in KEEP}
            if e['type'] == 'node':
                feats.append({'t': 'n', 'id': e['id'], 'g': tags, 'p': conv([e])[0]})
            elif e['type'] == 'way' and e.get('geometry'):
                feats.append({'t': 'w', 'id': e['id'], 'g': tags, 'p': conv(e['geometry'])})
            elif e['type'] == 'relation' and e.get('members'):
                ms = [{'r': m.get('role', ''), 'p': conv(m['geometry'])} for m in e['members'] if m.get('geometry')]
                if ms: feats.append({'t': 'r', 'id': e['id'], 'g': tags, 'm': ms})
    return feats


def join_rings(members):
    """Join multipolygon member ways into closed rings (outer and inner separately)."""
    out = {'outer': [], 'inner': []}
    for role in ('outer', 'inner'):
        segs = [m['p'][:] for m in members if (m['r'] or 'outer') == role and len(m['p']) >= 2]
        rings = []
        while segs:
            cur = segs.pop(0)
            changed = True
            while changed and cur[0] != cur[-1]:
                changed = False
                for i, sg in enumerate(segs):
                    if _close(sg[0], cur[-1]): cur += sg[1:]
                    elif _close(sg[-1], cur[-1]): cur += sg[::-1][1:]
                    elif _close(sg[-1], cur[0]): cur = sg[:-1] + cur
                    elif _close(sg[0], cur[0]): cur = sg[::-1][:-1] + cur
                    else: continue
                    segs.pop(i); changed = True; break
            if len(cur) >= 4: rings.append(cur)
        out[role] = rings
    return out


def _close(a, b):
    return abs(a[0] - b[0]) < 0.05 and abs(a[1] - b[1]) < 0.05
