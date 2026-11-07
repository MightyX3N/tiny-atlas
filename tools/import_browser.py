"""Put results gathered by browser_fetch.js into the route builder's cache under the builder's own keys.
usage: import_browser.py CACHE_DIR PACKED.json"""
import base64, json, os, sys
sys.path.insert(0, os.path.dirname(__file__))
from routebuilder.fetch import Fetcher
from routebuilder.gpx import read_gpx
from routebuilder.track import build_track
from routebuilder.osm import corridor_queries
from routebuilder.dem import URL as DEM_URL
from routebuilder.climate import URL as CLIMATE_URL
from routebuilder import vtiles

SAMPLES = os.path.join(os.path.dirname(__file__), '..', 'samples')
MAXKM = {'big-file-perf.gpx': 25}

cache, packed = sys.argv[1], sys.argv[2]
F = Fetcher(cache, 'plan')
res = json.load(open(packed))
queries = {}
n = 0
for k, v in res.items():
    kind = k.split('|')[0]
    if kind == 'osmb':
        _, f, i = k.split('|')
        if f not in queries:
            queries[f] = corridor_queries(build_track(read_gpx(open(os.path.join(SAMPLES, f), 'rb').read()), MAXKM.get(f)))
        key = F.key('osm', queries[f][int(i)]); data = v.encode()
    elif kind == 'vt':
        x, y = k.split('|')[1].split('/')
        url = json.loads(open(os.path.join(cache, F.key('tilejson', vtiles.TILEJSON))).read())['tiles'][0].format(z=14, x=x, y=y)
        key = F.key('vt14', url); data = base64.b64decode(v[4:])
    elif kind == 'dem':
        z, x, y = k.split('|')[1][:-4].split('/')
        url = DEM_URL.format(z=z, x=x, y=y); key = F.key(f'dem{z}', url); data = base64.b64decode(v[4:])
    elif kind == 'climate':
        _, lat, lon = k.split('|')
        url = CLIMATE_URL.format(lat=float(lat), lon=float(lon)); key = F.key('climate', url); data = base64.b64decode(v[4:])
    else:
        continue
    open(os.path.join(cache, key), 'wb').write(data); n += 1
print('imported', n)
