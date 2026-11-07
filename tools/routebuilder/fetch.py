"""Cached HTTP fetching.

Every request has a stable key and is cached on disk, so a route can be rebuilt offline and
shared caches can be reused. In 'plan' mode nothing is downloaded: missing requests are
collected into a plan (JSON list) that any HTTP client can execute, writing results into the cache."""
import hashlib, json, os, time, urllib.request, urllib.error

UA = 'Tiny Atlas-RouteBuilder/0.1 (+https://github.com/; offline route preprocessing)'
OVERPASS = ['https://overpass-api.de/api/interpreter',
            'https://maps.mail.ru/osm/tools/overpass/api/interpreter',
            'https://overpass.private.coffee/api/interpreter']


class Missing(Exception):
    pass


class Fetcher:
    def __init__(self, cache_dir, mode='online', log=print):
        self.dir = cache_dir; os.makedirs(cache_dir, exist_ok=True)
        self.mode = mode; self.plan = []; self.log = log

    @staticmethod
    def key(kind, ident):
        return kind + '_' + hashlib.sha1(ident.encode()).hexdigest()[:20]

    def path(self, key):
        return os.path.join(self.dir, key)

    def have(self, key):
        return os.path.exists(self.path(key))

    def get(self, key, urls, body=None, binary=True):
        """urls: one URL or a list of mirrors tried in order. body: POST form data (str) or None."""
        p = self.path(key)
        if os.path.exists(p):
            return open(p, 'rb').read()
        urls = [urls] if isinstance(urls, str) else urls
        if self.mode == 'plan':
            self.plan.append({'key': key, 'urls': urls, 'body': body})
            raise Missing(key)
        last = None
        for u in urls:
            for attempt in range(3):
                try:
                    req = urllib.request.Request(u, data=body.encode() if body else None, headers={'User-Agent': UA})
                    with urllib.request.urlopen(req, timeout=180) as r:
                        data = r.read()
                    open(p + '.part', 'wb').write(data); os.replace(p + '.part', p)
                    return data
                except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
                    last = e; code = getattr(e, 'code', None)
                    if code in (400, 404): break
                    time.sleep(2 + 4 * attempt)
        raise RuntimeError(f'could not download {urls[0]} ({last})')

    def save_plan(self, path):
        json.dump(self.plan, open(path, 'w'), indent=0)
        return len(self.plan)
