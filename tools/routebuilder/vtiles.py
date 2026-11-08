"""Map data from OpenStreetMap vector tiles (OpenFreeMap, OpenMapTiles schema, zoom 14).
Fast CDN tiles with no rate limit; converted into the same OSM-style features the builder uses."""
import json, math
import numpy as np
import mapbox_vector_tile
from shapely import make_valid
from shapely.geometry import shape, box, LineString, Polygon, MultiPolygon, MultiLineString, Point, GeometryCollection
from .fetch import Fetcher

TILEJSON = 'https://tiles.openfreemap.org/planet'
Z = 14
RADIUS = 600       # metres around the route that need map data


def tile_url(F: Fetcher):
    """The current planet tile URL template (versioned). Cached so a build is reproducible."""
    j = json.loads(F.get(F.key('tilejson', TILEJSON), TILEJSON))
    return j['tiles'][0]


def tiles_for(T):
    n = 2 ** Z; P = T['proj']; tiles = set()
    idx = np.arange(0, len(T['s']), 20)
    for ang in np.linspace(0, 2 * math.pi, 13)[:-1]:
        for r in (0, RADIUS * 0.5, RADIUS):
            lat, lon = P.inv(T['x'][idx] + r * math.cos(ang), T['y'][idx] + r * math.sin(ang))
            tx = ((lon + 180) / 360 * n).astype(int)
            ty = ((1 - np.arcsinh(np.tan(np.radians(lat))) / math.pi) / 2 * n).astype(int)
            tiles.update(zip(tx.tolist(), ty.tolist()))
    return sorted(tiles)


def fetch(F: Fetcher, T):
    try:
        tmpl = tile_url(F)
    except Exception as e:
        if e.__class__.__name__ == 'Missing': return {}, 1 + len(tiles_for(T))
        raise
    out, missing = {}, 0
    for (x, y) in tiles_for(T):
        url = tmpl.format(z=Z, x=x, y=y)
        try: out[(x, y)] = F.get(F.key('vt14', url), url)
        except Exception as e:
            if e.__class__.__name__ == 'Missing': missing += 1
            else: raise
    return out, missing


def fetch_tiles(F: Fetcher, z, tiles):
    """Any zoom level, explicit tile list (used for the low-detail rings around the route)."""
    try:
        tmpl = tile_url(F)
    except Exception as e:
        if e.__class__.__name__ == 'Missing': return {}, 1 + len(tiles)
        raise
    out, missing = {}, 0
    for (x, y) in tiles:
        url = tmpl.format(z=z, x=x, y=y)
        try: out[(x, y)] = F.get(F.key(f'vt{z}', url), url)
        except Exception as e:
            if e.__class__.__name__ == 'Missing': missing += 1
            else: raise
    return out, missing


def tile_of(lat, lon, z):
    n = 2 ** z
    return (((np.asarray(lon) + 180) / 360 * n).astype(int), ((1 - np.arcsinh(np.tan(np.radians(lat))) / math.pi) / 2 * n).astype(int))


ROAD_CLASS = {'motorway': 'motorway', 'trunk': 'trunk', 'primary': 'primary', 'secondary': 'secondary', 'tertiary': 'tertiary',
              'minor': 'residential', 'service': 'service', 'track': 'track', 'raceway': 'service', 'busway': 'service'}
PATH_SUB = {'footway': 'footway', 'cycleway': 'cycleway', 'steps': 'steps', 'path': 'path', 'pedestrian': 'pedestrian',
            'bridleway': 'bridleway', 'corridor': 'footway', 'platform': 'footway'}
NATURAL_SUB = {'wood', 'scrub', 'heath', 'grassland', 'sand', 'beach', 'dune', 'bare_rock', 'scree', 'shingle', 'glacier',
               'wetland', 'marsh', 'swamp', 'bog', 'mud', 'cliff', 'rock'}


def to_feats(tiles, P, z=Z):
    """Decode tiles into features {'t','g','p'|'m'} in local metres, geometry clipped exactly to each tile so
    neighbouring tiles join without overlaps."""
    n = 2 ** z; feats = []; fid = 0
    for (tx, ty), data in tiles.items():
        try:
            layers = mapbox_vector_tile.decode(data, default_options={'y_coord_down': True})
        except Exception:
            continue
        def conv(coords, ext):
            a = np.asarray(coords, float)
            lon = (tx + a[:, 0] / ext) / n * 360 - 180
            lat = np.degrees(np.arctan(np.sinh(math.pi * (1 - 2 * (ty + a[:, 1] / ext) / n))))
            x, y = P.fwd(lat, lon)
            return np.stack([x, y], 1)
        for lname, layer in layers.items():
            ext = layer.get('extent', 4096); clip = box(0, 0, ext, ext)
            for f in layer['features']:
                pr = f.get('properties', {}); g = f['geometry']
                tags = _tags(lname, pr)
                if tags is None: continue
                try:
                    geom = shape(g)
                    if g['type'] != 'Point':
                        if not geom.is_valid: geom = make_valid(geom)     # merged building blocks are often self-touching
                        geom = geom.intersection(clip)
                except Exception:
                    continue
                if geom.is_empty: continue
                for part in _parts(geom):
                    fid += 1
                    if isinstance(part, Point):
                        xy = conv([part.coords[0]], ext)[0]; feats.append({'t': 'n', 'id': fid, 'g': tags, 'p': [float(xy[0]), float(xy[1])]})
                    elif isinstance(part, LineString):
                        if len(part.coords) < 2: continue
                        feats.append({'t': 'w', 'id': fid, 'g': tags, 'p': conv(part.coords, ext).tolist()})
                    elif isinstance(part, Polygon):
                        ring = conv(part.exterior.coords, ext).tolist()
                        holes = [conv(h.coords, ext).tolist() for h in part.interiors]
                        feats.append({'t': 'r', 'id': fid, 'g': tags, 'm': [{'r': 'outer', 'p': ring}] + [{'r': 'inner', 'p': h} for h in holes]})
    return feats


def _parts(g):
    if isinstance(g, (MultiPolygon, MultiLineString, GeometryCollection)):
        for p in g.geoms: yield from _parts(p)
    else:
        yield g


def _tags(layer, p):
    c, sc = p.get('class'), p.get('subclass')
    if layer == 'transportation':
        if c == 'bridge': return {'man_made': 'bridge'}          # the outline of a whole bridge (all its lanes)
        t = {}
        if c in ROAD_CLASS: t['highway'] = ROAD_CLASS[c]
        elif c == 'path': t['highway'] = PATH_SUB.get(sc, 'path')
        elif c in ('rail', 'transit'): t['railway'] = 'tram' if sc == 'tram' else 'rail'
        else: return None
        if c == 'minor' and sc in ('living_street', 'unclassified'): t['highway'] = sc
        if p.get('brunnel') == 'bridge': t['bridge'] = 'yes'
        if p.get('brunnel') == 'tunnel': t['tunnel'] = 'yes'
        if p.get('surface') == 'unpaved': t['surface'] = 'unpaved' if t.get('highway') != 'track' else 'gravel'
        if p.get('layer') is not None: t['layer'] = str(p['layer'])
        if p.get('ramp'): t['ramp'] = 'yes'
        return t
    if layer == 'building':
        if p.get('hide_3d'): return None
        t = {'building': 'yes'}
        if p.get('render_height') is not None: t['height'] = str(max(2.5, p['render_height'] - (p.get('render_min_height') or 0)))
        if p.get('colour'): t['building:colour'] = p['colour']
        return t
    if layer == 'landcover':
        s = sc or c
        if s in NATURAL_SUB: return {'natural': {'marsh': 'wetland', 'swamp': 'wetland', 'bog': 'wetland', 'mud': 'wetland'}.get(s, s)}
        if c == 'ice': return {'natural': 'glacier'}
        if c == 'rock': return {'natural': 'bare_rock'}
        if c == 'wood': return {'landuse': 'forest'}
        if c == 'grass' and s in ('park', 'garden', 'golf_course'): return {'leisure': s}
        if c == 'farmland' and s in ('orchard', 'vineyard', 'plant_nursery', 'allotments'): return {'landuse': s}
        return {'landuse': {'grass': 'grass', 'farmland': 'farmland', 'wetland': 'wetland', 'sand': 'sand'}.get(c, s or c)}
    if layer == 'landuse':
        if c in ('pitch', 'playground', 'stadium', 'track', 'garden'): return {'leisure': c}
        if c in ('neighbourhood', 'suburb', 'quarter', 'city', 'town', 'village', 'hamlet', 'isolated_dwelling'):
            return {'landuse': 'residential'}          # low zooms give built-up areas as place polygons
        return {'landuse': c}
    if layer == 'park':
        return {'leisure': 'park'} if c in ('park', 'garden', 'dog_park') else None
    if layer == 'water':
        if p.get('brunnel') == 'tunnel': return None
        return {'natural': 'water', 'water': c or 'lake'}
    if layer == 'waterway':
        if p.get('brunnel') == 'tunnel': return None
        return {'waterway': c} if c in ('river', 'canal', 'stream') else None
    if layer == 'place':
        if c in ('city', 'town', 'village', 'hamlet', 'suburb', 'neighbourhood', 'quarter'):
            return {'place': c, 'name': p.get('name:latin') or p.get('name') or ''}
    return None
