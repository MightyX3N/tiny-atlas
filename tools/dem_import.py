"""Rebuild Terrarium PNGs (and climate JSON) from a delta-coded browser transfer into the builder cache."""
import io, os, sys, numpy as np
from PIL import Image
sys.path.insert(0, os.path.dirname(__file__))
from unpack_bin import load
from routebuilder.fetch import Fetcher
from routebuilder.dem import URL as DEM_URL
from routebuilder.climate import URL as CLIMATE_URL
cache = sys.argv[1]; F = Fetcher(cache, 'plan'); n = 0
for name, blob in load(sys.argv[2:]).items():
    if not name.startswith(('dem|', 'climate|')): continue
    k = name.split('|', 1)[1]
    if k.startswith('climate'):
        _, lat, lon = k.split('|'); url = CLIMATE_URL.format(lat=float(lat), lon=float(lon))
        open(F.path(F.key('climate', url)), 'wb').write(blob); n += 1; continue
    z, x, y = k[:-4].split('/')
    h = np.cumsum(np.frombuffer(blob, '<i2').astype(np.int64)).reshape(256, 256) / 2.0
    v = h + 32768.0
    r = np.floor(v / 256); g = np.floor(v) - r * 256; b = np.round((v - np.floor(v)) * 256).clip(0, 255)
    im = Image.fromarray(np.stack([r, g, b], -1).astype(np.uint8))
    bio = io.BytesIO(); im.save(bio, 'PNG')
    url = DEM_URL.format(z=z, x=x, y=y); open(F.path(F.key(f'dem{z}', url)), 'wb').write(bio.getvalue()); n += 1
print('written', n)
