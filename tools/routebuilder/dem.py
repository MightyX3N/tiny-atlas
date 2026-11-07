"""Elevation from the free Terrain Tiles (Terrarium PNGs on AWS Open Data), incl. sea-floor depth."""
import io, math
import numpy as np
from PIL import Image
from .fetch import Fetcher

URL = 'https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png'


def lonlat_to_tile(lon, lat, z):
    n = 2 ** z
    x = (np.asarray(lon) + 180.0) / 360.0 * n
    y = (1.0 - np.arcsinh(np.tan(np.radians(lat))) / math.pi) / 2.0 * n
    return x, y


def tiles_for(T, z, buffer_m, step_m):
    """Tiles covering every point within buffer_m of the track."""
    P = T['proj']; tiles = set()
    idx = np.arange(0, len(T['s']), max(1, int(step_m / 5)))
    for ang in np.linspace(0, 2 * math.pi, 9)[:-1]:
        for r in (0, buffer_m / 2, buffer_m):
            lat, lon = P.inv(T['x'][idx] + r * math.cos(ang), T['y'][idx] + r * math.sin(ang))
            tx, ty = lonlat_to_tile(lon, lat, z)
            tiles.update(zip(tx.astype(int).tolist(), ty.astype(int).tolist()))
    return sorted(tiles)


class DEM:
    def __init__(self, F: Fetcher, z):
        self.F, self.z, self.tiles, self.missing = F, z, {}, 0

    def load(self, tiles):
        for (x, y) in tiles:
            url = URL.format(z=self.z, x=x, y=y)
            try:
                b = self.F.get(self.F.key(f'dem{self.z}', url), url)
            except Exception as e:
                if e.__class__.__name__ == 'Missing': self.missing += 1; continue
                raise
            a = np.asarray(Image.open(io.BytesIO(b)).convert('RGB')).astype(np.float32)
            self.tiles[(x, y)] = a[..., 0] * 256 + a[..., 1] + a[..., 2] / 256 - 32768
        return self

    def sample_lonlat(self, lon, lat):
        lon = np.asarray(lon, float); lat = np.asarray(lat, float)
        tx, ty = lonlat_to_tile(lon, lat, self.z)
        px = tx * 256 - 0.5; py = ty * 256 - 0.5
        out = np.full(lon.shape, np.nan, np.float32)
        x0 = np.floor(px).astype(int); y0 = np.floor(py).astype(int); fx = px - x0; fy = py - y0
        acc = np.zeros(lon.shape, np.float32)
        ok = np.ones(lon.shape, bool)
        for dx, dy, w in ((0, 0, (1 - fx) * (1 - fy)), (1, 0, fx * (1 - fy)), (0, 1, (1 - fx) * fy), (1, 1, fx * fy)):
            gx = x0 + dx; gy = y0 + dy
            kx = gx // 256; ky = gy // 256
            v = np.full(lon.shape, np.nan, np.float32)
            for key in set(zip(kx.ravel().tolist(), ky.ravel().tolist())):
                t = self.tiles.get(key)
                if t is None: continue
                m = (kx == key[0]) & (ky == key[1])
                v[m] = t[gy[m] - key[1] * 256, gx[m] - key[0] * 256]
            acc += np.nan_to_num(v) * w; ok &= ~np.isnan(v)
        out[ok] = acc[ok]
        return out
