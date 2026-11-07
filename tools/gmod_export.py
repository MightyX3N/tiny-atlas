"""Route package -> the GMod/LÖVE runtime format (files GMod's Lua can read fast: no PNG decoding).

    python3 tools/gmod_export.py routes/city-run-10km out/tinyatlas/routes

Writes <out>/<route id>/:
  route.txt          JSON: name, distance, ground tag names, the track (s x y z grade ground bridge),
                     chunk and page lists, far grid info, bridges
  c_X_Y.dat          near chunk (256 m): header line (JSON) + heights 257x257 u16 (1 m, rows south->north)
                     + ground tags 256x256 per 1 m cell (RLE: count u8, tag u8) + water surface 33x33 u16 (8 m)
  c_X_Y.txt          near chunk objects: buildings [style, height, base, x1, y1, x2, y2, ...],
                     trees [x, y, z, kind, v, scale, distance to the track] (none on roads)
  p_X_Y.dat / .txt   mid page (1024 m): heights 257x257 (4 m), tags 256x256 per 4 m cell, water 129x129 (8 m);
                     objects: boxes [x, y, length, width, angle, height, base], trees [x, y, z, kind, v]
  l_X_Y.dat          every page the route touches at 16 m: heights 65x65 + tags 64x64 (from near data where
                     there is some, else mid) - the cheap level drawn far ahead
  far.dat            the far grid: heights at 32 m + tags per 32 m cell
All heights: value = base + scale * u16. All grids: index = row * n + col, row 0 = south edge.
"""
import json, os, sys
import numpy as np
from PIL import Image

ROAD_FIRST = ['cycleway', 'asphalt', 'parking', 'rail', 'paving', 'cobble', 'gravel', 'dirt', 'sand', 'water']


def rle(a):
    a = a.astype(np.uint8).ravel()
    out = bytearray()
    i, n = 0, len(a)
    # run boundaries with numpy, then split runs longer than 255
    edges = np.flatnonzero(np.diff(a)) + 1
    starts = np.concatenate([[0], edges]); ends = np.concatenate([edges, [n]])
    for s, e in zip(starts, ends):
        v = int(a[s]); L = int(e - s)
        while L > 0:
            k = min(255, L); out += bytes((k, v)); L -= k
    return bytes(out)


def mode_down(cls, f, pref):
    """Downsample a tag image by f with the most common tag per block; ties go to roads (pref order)."""
    H, W = cls.shape
    b = cls.reshape(H // f, f, W // f, f).transpose(0, 2, 1, 3).reshape(H // f, W // f, f * f)
    rank = np.full(256, 100, np.int32)
    for i, t in enumerate(pref): rank[t] = i
    best = b[..., 0].copy(); bestc = np.zeros(best.shape, np.int32)
    for k in range(f * f):
        v = b[..., k]
        cnt = (b == v[..., None]).sum(-1)
        better = (cnt > bestc) | ((cnt == bestc) & (rank[v] < rank[best]))
        best = np.where(better, v, best); bestc = np.where(better, cnt, bestc)
    return best


def u16(a, base, scale):
    return np.round((a - base) / scale).clip(0, 65535).astype('<u2').tobytes()


def read_h(path, n, base, scale, rows='north_to_south'):
    a = np.fromfile(path, '<u2').astype(np.float64).reshape(n, -1) * scale + base
    return a[::-1] if rows == 'north_to_south' else a


def header(d):
    return (json.dumps(d, separators=(',', ':')) + '\n').encode()


def main(src, out_root):
    R = json.load(open(os.path.join(src, 'route.json')))
    T = json.load(open(os.path.join(src, 'track.json')))
    tags = R['ground_tags']; TID = {t: i for i, t in enumerate(tags)}
    pref = [TID[t] for t in ROAD_FIRST if t in TID]
    out = os.path.join(out_root, R['id']); os.makedirs(out, exist_ok=True)
    CS = R['chunk_size']; PS = R['mid']['page_size']
    kinds = []

    def kind_id(k):
        if k not in kinds: kinds.append(k)
        return kinds.index(k)

    # the track at 1 m: each tree gets its distance to it (the renderer keeps crowns off the track)
    from scipy.spatial import cKDTree
    tx, ty = np.asarray(T['x'], float), np.asarray(T['y'], float)
    fr = np.linspace(0, 1, 6)[:-1]
    track_kd = cKDTree(np.stack([(tx[:-1, None] * (1 - fr) + tx[1:, None] * fr).ravel(),
                                 (ty[:-1, None] * (1 - fr) + ty[1:, None] * fr).ravel()], 1))
    no_trees = {TID[t] for t in ('asphalt', 'cycleway', 'rail', 'parking') if t in TID}   # no trees in roads
    near = {}
    for c in R['chunks']:
        C = json.load(open(os.path.join(src, 'chunks', c['file'])))
        hm = C['height']; h = read_h(os.path.join(src, 'chunks', hm['file']), hm['n'], hm['base'], hm['scale'], hm['rows'])
        cls = np.array(Image.open(os.path.join(src, 'chunks', C['ground']['file'])))[::-1]
        t1 = mode_down(cls, 2, pref)
        near[(c['cx'], c['cy'])] = (h, t1)
        hd = {'v': 1, 'cx': c['cx'], 'cy': c['cy'], 'x0': C['x0'], 'y0': C['y0'], 'size': CS, 'n': hm['n'],
              'base': hm['base'], 'scale': hm['scale'], 'water_level': C.get('water_level')}
        body = u16(h, hm['base'], hm['scale'])
        tr = rle(t1); hd['tags_bytes'] = len(tr); body += tr
        W = C.get('water')
        if W:
            w = read_h(os.path.join(src, 'chunks', W['file']), W['n'], W['base'], W['scale'], W['rows'])
            hd['water'] = {'n': W['n'], 'res': W['res'], 'base': W['base'], 'scale': W['scale'], 'flow': W.get('flow')}
            body += u16(w, W['base'], W['scale'])
        open(os.path.join(out, f"c_{c['cx']}_{c['cy']}.dat"), 'wb').write(header(hd) + body)
        objs = {'buildings': [], 'trees': []}
        for b in C.get('buildings', []):
            ring = [round(v, 2) for p in b['p'] for v in p]
            objs['buildings'].append([b.get('v', 0) % 6, round(b['h'], 1), round(b['base'], 2)] + ring)
        trees = C.get('trees', [])
        if trees:
            dist, _ = track_kd.query(np.array([(t['x'], t['y']) for t in trees]))
            res = C['ground']['res']; nG = cls.shape[0]
            for t, d in zip(trees, dist):
                gi = min(nG - 1, max(0, int((t['x'] - C['x0']) / res))); gj = min(nG - 1, max(0, int((t['y'] - C['y0']) / res)))
                if int(cls[gj, gi]) in no_trees: continue
                objs['trees'].append([round(t['x'], 1), round(t['y'], 1), round(t['z'], 2), kind_id(t['kind']), t.get('v', 0),
                                      round(t.get('s', 1.0), 2), round(float(d), 1)])
        json.dump(objs, open(os.path.join(out, f"c_{c['cx']}_{c['cy']}.txt"), 'w'), separators=(',', ':'))

    mid = {}
    for p in R['mid']['pages']:
        P = json.load(open(os.path.join(src, 'mid', p['file'])))
        hm = P['height']; h = read_h(os.path.join(src, 'mid', hm['file']), hm['n'], hm['base'], hm['scale'], hm['rows'])
        cls = np.array(Image.open(os.path.join(src, 'mid', P['ground']['file'])))[::-1]
        t4 = mode_down(cls, 2, pref)
        mid[(p['px'], p['py'])] = (h, t4, P)
        hd = {'v': 1, 'px': p['px'], 'py': p['py'], 'x0': P['x0'], 'y0': P['y0'], 'size': PS, 'n': hm['n'], 'res': hm['res'],
              'base': hm['base'], 'scale': hm['scale'], 'present': P['present'], 'water_chunks': P.get('water_chunks', []),
              'water_flow': P.get('water_flow', {})}
        body = u16(h, hm['base'], hm['scale'])
        tr = rle(t4); hd['tags_bytes'] = len(tr); body += tr
        W = P.get('water')
        if W:
            w = read_h(os.path.join(src, 'mid', W['file']), W['n'], W['base'], W['scale'], W['rows'])
            hd['water'] = {'n': W['n'], 'res': W['res'], 'base': W['base'], 'scale': W['scale']}
            body += u16(w, W['base'], W['scale'])
        open(os.path.join(out, f"p_{p['px']}_{p['py']}.dat"), 'wb').write(header(hd) + body)
        objs = {'boxes': [[round(v, 2) for v in b] for b in P.get('buildings', [])],
                'trees': [[t[0], t[1], t[2], kind_id(t[3]), t[4]] for t in P.get('trees', [])]}
        json.dump(objs, open(os.path.join(out, f"p_{p['px']}_{p['py']}.txt"), 'w'), separators=(',', ':'))

    # 16 m level for every page with near or mid cells
    per = int(PS // CS)
    pages = set(mid)
    for (cx, cy) in near: pages.add((cx // per, cy // per))
    l16 = []
    for (px, py) in sorted(pages):
        H = np.full((65, 65), np.nan); G = np.zeros((64, 64), np.uint8); cells = []
        x0, y0 = px * PS, py * PS
        if (px, py) in mid:
            mh, mt, _ = mid[(px, py)]
            H[:] = mh[::4, ::4]; G[:] = mt[::4, ::4]
        for i in range(per):
            for j in range(per):
                k = (px * per + i, py * per + j)
                if k in near:
                    h, t1 = near[k]
                    H[j * 16:(j + 1) * 16 + 1, i * 16:(i + 1) * 16 + 1] = h[::16, ::16]
                    G[j * 16:(j + 1) * 16, i * 16:(i + 1) * 16] = mode_down(t1, 16, pref)
                    cells.append([k[0], k[1]])
        if (px, py) in mid:
            cells += mid[(px, py)][2]['present']
        if np.isnan(H).any():   # cells without data stay at their neighbours' height (they are not drawn)
            H = np.where(np.isnan(H), np.nanmean(H) if not np.isnan(H).all() else 0, H)
        lo = float(H.min()); sc = 0.02
        hd = {'v': 1, 'px': px, 'py': py, 'x0': x0, 'y0': y0, 'size': PS, 'n': 65, 'res': 16.0, 'base': lo, 'scale': sc,
              'cells': cells}
        tr = rle(G); hd['tags_bytes'] = len(tr)
        open(os.path.join(out, f"l_{px}_{py}.dat"), 'wb').write(header(hd) + u16(H, lo, sc) + tr)
        l16.append([px, py])

    F = R['far']
    fh = read_h(os.path.join(src, F['file']), F['ny'], F['base'], F['scale'], F['rows'])
    fc = np.array(Image.open(os.path.join(src, F['ground']['file'])))[::-1]
    ft = mode_down(fc[:(fc.shape[0] // 2) * 2, :(fc.shape[1] // 2) * 2], 2, pref)
    hd = {'v': 1, 'nx': F['nx'], 'ny': F['ny'], 'res': F['res'], 'x0': F['x0'], 'y0': F['y1'] - (F['ny'] - 1) * F['res'],
          'base': F['base'], 'scale': F['scale'], 'tnx': ft.shape[1], 'tny': ft.shape[0]}
    tr = rle(ft); hd['tags_bytes'] = len(tr)
    open(os.path.join(out, 'far.dat'), 'wb').write(header(hd) + u16(fh, F['base'], F['scale']) + tr)

    bridges = json.load(open(os.path.join(src, 'bridges.json')))
    route = {'v': 1, 'id': R['id'], 'name': R['name'], 'activity': R.get('activity'), 'distance_m': R['distance_m'],
             'loop': R.get('loop', False), 'origin': R['origin'], 'tags': tags, 'tree_kinds': kinds,
             'chunk_size': CS, 'page_size': PS,
             'chunks': [[c['cx'], c['cy']] for c in R['chunks']], 'pages': [[p['px'], p['py']] for p in R['mid']['pages']],
             'l16': l16, 'track': {k: T[k] for k in ('step', 'n', 's', 'x', 'y', 'z', 'grade', 'ground', 'bridge')},
             'bridges': [{'p': [v for q in b['p'] for v in q], 'pz': b['pz'], 'w': b['w'], 'tag': b.get('tag', 'asphalt')} for b in bridges],
             'climate': R.get('climate')}
    json.dump(route, open(os.path.join(out, 'route.txt'), 'w'), separators=(',', ':'))
    tot = sum(os.path.getsize(os.path.join(out, f)) for f in os.listdir(out))
    print(f"{R['id']}: {len(near)} chunks, {len(mid)} mid pages, {len(l16)} 16 m pages, far {F['nx']}x{F['ny']} -> {out} ({tot / 1e6:.1f} MB)")


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
