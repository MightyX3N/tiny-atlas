"""Re-encode the stripped tiles (layers needed by the builder, delta-coded integer geometry) as normal MVT tiles
in the builder cache, under the same keys the builder uses for the real tile URLs."""
import json, os, sys, glob
import mapbox_vector_tile
sys.path.insert(0, os.path.dirname(__file__))
from unpack_bin import load
from routebuilder.fetch import Fetcher
from routebuilder import vtiles
cache = sys.argv[1]; args = sys.argv[2:]
split = args.index('--buildings') if '--buildings' in args else len(args)
files, bfiles = args[:split], args[split + 1:]
F = Fetcher(cache, 'plan')
tmpl = json.loads(open(F.path(F.key('tilejson', vtiles.TILEJSON))).read())['tiles'][0]
data = load(files); n = 0
bdata = {k.split('|', 1)[1]: json.loads(v) for k, v in load(bfiles).items()} if bfiles else {}
GT = {1: 'Point', 2: 'LineString', 3: 'Polygon'}
for name, blob in data.items():
    if not name.startswith('vt|'): continue
    zxy = name.split('|')[1].split('/')
    z, x, y = (zxy if len(zxy) == 3 else ['14'] + zxy)
    o = json.loads(blob)
    bo = bdata.get(name.split('|', 1)[1])
    if bo is not None:
        o.pop('building', None)
        if 'building' in bo: o['building'] = bo['building']
    layers = []
    for ln, L in o.items():
        feats = []
        for typ, props, rings in L['f']:
            abs_r = []
            for r in rings:
                px = py = 0; pts = []
                for i in range(0, len(r), 2): px += r[i]; py += r[i + 1]; pts.append((px, py))
                abs_r.append(pts)
            if typ == 1: geom = {'type': 'MultiPoint' if len(abs_r[0]) > 1 else 'Point', 'coordinates': abs_r[0] if len(abs_r[0]) > 1 else abs_r[0][0]}
            elif typ == 2: geom = {'type': 'MultiLineString', 'coordinates': abs_r} if len(abs_r) > 1 else {'type': 'LineString', 'coordinates': abs_r[0]}
            else:
                # vector-tile rings: outer rings followed by their holes (holes wind the other way)
                polys = []
                for r in abs_r:
                    a = sum(r[i][0] * r[(i + 1) % len(r)][1] - r[(i + 1) % len(r)][0] * r[i][1] for i in range(len(r)))
                    if a > 0 or not polys: polys.append([r])          # y-down tiles: outer ring has positive area
                    else: polys[-1].append(r)
                geom = {'type': 'MultiPolygon', 'coordinates': polys} if len(polys) > 1 else {'type': 'Polygon', 'coordinates': polys[0]}
            feats.append({'geometry': geom, 'properties': props})
        layers.append({'name': ln, 'features': feats, 'extent': L['e']})
    mvt = mapbox_vector_tile.encode(layers, default_options={'y_coord_down': True, 'quantize_bounds': None})
    url = tmpl.format(z=int(z), x=x, y=y)
    open(F.path(F.key(f'vt{z}', url)), 'wb').write(mvt); n += 1
print('tiles written', n)
