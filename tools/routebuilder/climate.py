"""Typical weather per month at the route, from Open-Meteo's free historical archive (ERA5, 10 years)."""
import json, math
import numpy as np
from .fetch import Fetcher

URL = ('https://archive-api.open-meteo.com/v1/archive?latitude={lat:.3f}&longitude={lon:.3f}'
       '&start_date=2015-01-01&end_date=2024-12-31&timezone=auto'
       '&daily=temperature_2m_mean,temperature_2m_max,precipitation_sum,wind_speed_10m_max,'
       'wind_direction_10m_dominant,cloud_cover_mean')

MONTHS = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec']


def daylight_hours(lat, month):
    doy = 15 + 30.4 * month
    decl = -23.44 * math.cos(math.radians(360 / 365 * (doy + 10)))
    x = -math.tan(math.radians(lat)) * math.tan(math.radians(decl))
    x = max(-1, min(1, x))
    return 2 * math.degrees(math.acos(x)) / 15


def fetch_climate(F: Fetcher, lat, lon):
    url = URL.format(lat=lat, lon=lon)
    try:
        d = json.loads(F.get(F.key('climate', url), url))
    except Exception as e:
        if e.__class__.__name__ == 'Missing': return None, 1
        raise
    dl = d['daily']; t = dl['time']
    mon = np.array([int(x[5:7]) - 1 for x in t])
    arr = lambda k: np.array([np.nan if v is None else v for v in dl.get(k, [None] * len(t))], float)
    tm, tx, pr, ws, wd, cc = (arr(k) for k in ('temperature_2m_mean', 'temperature_2m_max', 'precipitation_sum',
                                                'wind_speed_10m_max', 'wind_direction_10m_dominant', 'cloud_cover_mean'))
    years = len(set(x[:4] for x in t))
    out = {}
    for m in range(12):
        k = mon == m
        dirs = np.radians(wd[k][~np.isnan(wd[k])])
        u, v = np.mean(np.sin(dirs)) if dirs.size else 0, np.mean(np.cos(dirs)) if dirs.size else 0
        out[MONTHS[m]] = {
            'temp_c': round(float(np.nanmean(tm[k])), 1), 'temp_max_c': round(float(np.nanmean(tx[k])), 1),
            'rain_mm': round(float(np.nansum(pr[k]) / years), 0), 'rain_days': round(float(np.nanmean(pr[k] >= 1.0)) * 30.4, 0),
            'wind_kmh': round(float(np.nanmean(ws[k])) * 0.6, 0),       # daily max -> typical riding wind
            'wind_from_deg': round(float(math.degrees(math.atan2(u, v)) % 360), 0),
            'wind_steadiness': round(float(math.hypot(u, v)), 2),
            'cloud_pct': round(float(np.nanmean(cc[k])), 0) if np.isfinite(cc[k]).any() else None,
            'snow_likely': bool(np.nanmean(tm[k]) < 1.0),
            'daylight_h': round(daylight_hours(lat, m), 1),
        }
    return {'source': 'Open-Meteo historical weather API (ERA5), 2015-2024', 'lat': round(lat, 3), 'lon': round(lon, 3),
            'months': out}, 0
