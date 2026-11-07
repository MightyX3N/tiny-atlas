"""GPX reading: tracks, routes, segments, missing elevation, and polite errors."""
import re
import xml.etree.ElementTree as ET


class GPXError(Exception):
    pass


def _strip(tag):
    return tag.rsplit('}', 1)[-1]


def read_gpx(text):
    """Returns dict(name, desc, segments=[[(lat, lon, ele|None, time|None), ...], ...], kind='trk'|'rte', waypoints=[...])."""
    try:
        root = ET.fromstring(text.encode('utf-8') if isinstance(text, str) else text)
    except ET.ParseError as e:
        raise GPXError(f'not a valid GPX/XML file ({e})')
    if _strip(root.tag) != 'gpx':
        raise GPXError('not a GPX file (root element is <%s>)' % _strip(root.tag))

    def find_text(el, name):
        for c in el:
            if _strip(c.tag) == name:
                return (c.text or '').strip()
        return None

    meta = next((c for c in root if _strip(c.tag) == 'metadata'), None)
    name = (find_text(meta, 'name') if meta is not None else None) or None
    desc = (find_text(meta, 'desc') if meta is not None else None) or ''

    def pt(el):
        try:
            lat = float(el.get('lat')); lon = float(el.get('lon'))
        except (TypeError, ValueError):
            return None
        if not (-90 <= lat <= 90 and -180 <= lon <= 180):
            return None
        ele = find_text(el, 'ele'); tm = find_text(el, 'time')
        try:
            ele = float(ele) if ele not in (None, '') else None
        except ValueError:
            ele = None
        return (lat, lon, ele, tm)

    segments, kind = [], None
    for trk in (c for c in root if _strip(c.tag) == 'trk'):
        name = name or find_text(trk, 'name')
        for seg in (c for c in trk if _strip(c.tag) == 'trkseg'):
            pts = [p for p in (pt(e) for e in seg if _strip(e.tag) == 'trkpt') if p]
            if len(pts) >= 2:
                segments.append(pts)
    if segments:
        kind = 'trk'
    else:
        for rte in (c for c in root if _strip(c.tag) == 'rte'):
            name = name or find_text(rte, 'name')
            pts = [p for p in (pt(e) for e in rte if _strip(e.tag) == 'rtept') if p]
            if len(pts) >= 2:
                segments.append(pts)
        if segments:
            kind = 'rte'
    wpts = [p for p in (pt(e) for e in root if _strip(e.tag) == 'wpt') if p]
    if not segments:
        if wpts:
            raise GPXError(f'this file only has {len(wpts)} waypoints and no track or route to ride. '
                           'Export it as a track (or a planned route) and try again.')
        raise GPXError('this file has no track or route points.')
    return {'name': name or 'Unnamed route', 'desc': desc, 'segments': segments, 'kind': kind, 'waypoints': wpts}
