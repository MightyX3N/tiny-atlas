"""Atlases for engines without custom shaders (Garry's Mod, LÖVE's simple path).

    python3 tools/packs/gmod_prep.py packs/tinyatlas_pack_default

Garry's Mod can't repeat part of a texture or blend ground tags in a shader, and every texture switch is
another draw call. So a pack gets two atlases, and the renderer maps each 1 m ground cell or each
facade bay onto one atlas cell itself:
  materials/tinyatlas/packs/<id>/gmod/ground.png   every ground tile (all seasons), 2 px edge padding
  materials/tinyatlas/packs/<id>/gmod/objects_<season>.png  that season's trees, bushes and props,
                                                   facade cells, roof tile, white
  lua/tinyatlas/packs/<id>_gmod.lua                where everything is, plus average colours for the
                                                   distant levels (drawn without textures)
Re-run it whenever the pack's art changes. The pack validator checks it is up to date.
"""
import glob, hashlib, json, os, sys
from PIL import Image
import numpy as np

sys.path.insert(0, os.path.dirname(__file__))


def lua_table(pack_lua):
    import lupa
    L = lupa.LuaRuntime()
    t = L.execute(open(pack_lua, encoding='utf-8').read())

    def py(x):
        if lupa.lua_type(x) == 'table':
            ks = list(x.keys())
            if ks == list(range(1, len(ks) + 1)): return [py(x[k]) for k in ks]
            return {str(k): py(x[k]) for k in ks}
        return x
    return py(t)


def strings(v, out):
    if isinstance(v, str):
        if v.endswith('.png'): out.add(v)
    elif isinstance(v, dict):
        for x in v.values(): strings(x, out)
    elif isinstance(v, list):
        for x in v: strings(x, out)


def lua(v, ind=''):
    if isinstance(v, dict):
        items = []
        for k in sorted(v, key=str):
            key = k if isinstance(k, str) and k.isidentifier() else f'["{k}"]'
            items.append(f'{ind}  {key} = {lua(v[k], ind + "  ")},')
        return '{\n' + '\n'.join(items) + f'\n{ind}}}'
    if isinstance(v, (list, tuple)):
        if all(isinstance(x, (int, float)) for x in v):
            return '{ ' + ', '.join(f'{x:.6g}' if isinstance(x, float) else str(x) for x in v) + ' }'
        return '{\n' + '\n'.join(f'{ind}  {lua(x, ind + "  ")},' for x in v) + f'\n{ind}}}'
    if isinstance(v, str): return json.dumps(v)
    if isinstance(v, bool): return 'true' if v else 'false'
    if isinstance(v, float): return f'{v:.6g}'
    return str(v)


def avg_rgb(im):
    a = np.asarray(im.convert('RGBA')).reshape(-1, 4).astype(np.float64)
    m = a[:, 3] > 128
    return [int(round(x)) for x in (a[m, :3].mean(0) if m.any() else a[:, :3].mean(0))]


def pad_into(dst, im, x, y, p):
    """Paste im at (x, y) and copy its edge pixels p px outward (no bleeding with point sampling)."""
    w, h = im.size
    dst.paste(im, (x, y))
    for i in range(1, p + 1):
        dst.paste(im.crop((0, 0, w, 1)), (x, y - i)); dst.paste(im.crop((0, h - 1, w, h)), (x, y + h - 1 + i))
        dst.paste(im.crop((0, 0, 1, h)), (x - i, y)); dst.paste(im.crop((w - 1, 0, w, h)), (x + w - 1 + i, y))
    for cx, cy, sx, sy in ((0, 0, -1, -1), (w - 1, 0, 1, -1), (0, h - 1, -1, 1), (w - 1, h - 1, 1, 1)):
        c = im.getpixel((cx, cy))
        for i in range(1, p + 1):
            for j in range(1, p + 1): dst.putpixel((x + cx + sx * i, y + cy + sy * j), c)


def shelf(sizes, width, pad):
    """Simple shelf packing, tallest first. Returns {key: (x, y)} and the height used."""
    order = sorted(sizes, key=lambda k: (-sizes[k][1], -sizes[k][0], k))
    pos, x, y, rowh = {}, pad, pad, 0
    for k in order:
        w, h = sizes[k]
        if x + w + pad > width: x, y, rowh = pad, y + rowh + 2 * pad, 0
        pos[k] = (x, y); x += w + 2 * pad; rowh = max(rowh, h)
    return pos, y + rowh + pad


def pow2(n):
    p = 1
    while p < n: p *= 2
    return p


def main(pack_dir):
    luadir = os.path.join(pack_dir, 'lua', 'tinyatlas', 'packs')
    pack_lua = [f for f in glob.glob(os.path.join(luadir, '*.lua')) if not f.endswith('_gmod.lua')][0]
    P = lua_table(pack_lua)
    pid = P['id']
    mat = os.path.join(pack_dir, 'materials', 'tinyatlas', 'packs', pid)
    out_dir = os.path.join(mat, 'gmod'); os.makedirs(out_dir, exist_ok=True)

    # ---- ground atlas: every ground tile of every season, same-size tiles in a grid ----
    gfiles = set()
    strings(P['ground'], gfiles)
    for s in P.get('seasons', {}).values(): strings(s.get('ground', {}), gfiles)
    strings(P.get('bridge', {}), gfiles)                 # bridge parts are opaque tiles too
    gfiles = sorted(gfiles)
    tiles = {f: Image.open(os.path.join(mat, f)).convert('RGBA') for f in gfiles}
    T = tiles[gfiles[0]].size[0]
    assert all(im.size == (T, T) for im in tiles.values()), 'ground tiles must all be the same square size'
    GP = 2; cell = T + 2 * GP
    cols = max(1, int(np.ceil(np.sqrt(len(gfiles)))))
    W = pow2(cols * cell); rows = int(np.ceil(len(gfiles) / (W // cell))); H = pow2(rows * cell)
    cols = W // cell
    G = Image.new('RGBA', (W, H), (0, 0, 0, 255)); gcell = {}
    for i, f in enumerate(gfiles):
        x, y = (i % cols) * cell + GP, (i // cols) * cell + GP
        pad_into(G, tiles[f], x, y, GP)
        gcell[f] = [x / W, y / H, (x + T) / W, (y + T) / H]
    G.convert('RGB').save(os.path.join(out_dir, 'ground.png'))

    def gset(table):
        return {tag: [gcell[f] for f in fl] for tag, fl in table.items()}
    ground = {'cells': gset(P['ground']), 'colour': {t: avg_rgb(tiles[fl[0]]) for t, fl in P['ground'].items()}}
    br = P.get('bridge', {})
    bridge = {k: gcell[v] for k, v in br.items() if isinstance(v, str) and v.endswith('.png')}
    bridge.update({k + '_colour': avg_rgb(tiles[v]) for k, v in br.items() if isinstance(v, str) and v.endswith('.png')})
    seasons = {}
    for sn, s in P.get('seasons', {}).items():
        seasons[sn] = {}
        if 'ground' in s:
            seasons[sn]['ground'] = gset(s['ground'])
            seasons[sn]['ground_colour'] = {t: avg_rgb(tiles[fl[0]]) for t, fl in s['ground'].items()}

    # ---- objects atlases, one per season: its trees and props + facade cells + roof + white ----
    B = P['buildings']
    fac = Image.open(os.path.join(mat, B['facades'])).convert('RGBA')
    fw = fac.size[0] // B['styles']; fh = fac.size[1] // 2
    shared = {}
    for s in range(B['styles']):
        shared[f'facade:{s}:upper'] = fac.crop((s * fw, 0, (s + 1) * fw, fh))
        shared[f'facade:{s}:ground'] = fac.crop((s * fw, fh, (s + 1) * fw, 2 * fh))
    roof = Image.open(os.path.join(mat, B['roofs'][0])).convert('RGBA'); shared['roof'] = roof
    shared['white'] = Image.new('RGBA', (4, 4), (255, 255, 255, 255))
    OP = 2
    allfiles = set()

    def build_objects(name, trees, props):
        files = set(); strings(trees, files); strings(props, files); allfiles.update(files)
        ims = {f: Image.open(os.path.join(mat, f)).convert('RGBA') for f in sorted(files)}
        ims.update(shared)
        sizes = {k: im.size for k, im in ims.items()}
        OW = 512
        while True:
            pos, used = shelf(sizes, OW, OP)
            if used <= OW: break
            OW *= 2
        OH = pow2(used)
        O = Image.new('RGBA', (OW, OH), (0, 0, 0, 0)); cell = {}
        for k, (x, y) in pos.items():
            im = ims[k]; w, h = im.size
            if k.startswith('facade') or k in ('roof', 'white'): pad_into(O, im, x, y, OP)
            else: O.paste(im, (x, y))
            cell[k] = [x / OW, y / OH, (x + w) / OW, (y + h) / OH, w, h]
        O.save(os.path.join(out_dir, f'objects_{name}.png'))
        return {'png': f'tinyatlas/packs/{pid}/gmod/objects_{name}.png', 'size': [OW, OH],
                'sprites': {f: cell[f] for f in sorted(files)},
                'facades': [{'upper': cell[f'facade:{s}:upper'], 'ground': cell[f'facade:{s}:ground'],
                             'colour': avg_rgb(shared[f'facade:{s}:upper'])} for s in range(B['styles'])],
                'roof': cell['roof'], 'roof_colour': avg_rgb(roof), 'white': cell['white']}

    objects = build_objects('summer', P.get('trees', {}), P.get('props', {}))
    for sn, s in P.get('seasons', {}).items():
        trees = dict(P.get('trees', {})); trees.update(s.get('trees', {}))
        props = dict(P.get('props', {})); props.update(s.get('props', {}))
        seasons[sn]['objects'] = build_objects(sn, trees, props)
    ofiles = allfiles
    water = P.get('water', {})
    wcol = avg_rgb(Image.open(os.path.join(mat, water['texture']))) if water.get('texture') else [60, 110, 150]

    src_hash = hashlib.sha1()
    for f in sorted(set(gfiles) | set(ofiles) | {B['facades'], B['roofs'][0]}):
        src_hash.update(f.encode()); src_hash.update(open(os.path.join(mat, f), 'rb').read())
    src_hash.update(open(pack_lua, 'rb').read())
    data = {
        'pack': pid, 'source_hash': src_hash.hexdigest(),
        'ground_png': f'tinyatlas/packs/{pid}/gmod/ground.png', 'ground_size': [W, H], 'tile_px': T,
        'ground': ground, 'objects': objects, 'seasons': seasons, 'water_colour': wcol, 'bridge': bridge,
    }
    out_lua = os.path.join(luadir, f'{pid}_gmod.lua')
    with open(out_lua, 'w', encoding='utf-8') as f:
        f.write('-- Generated by tools/packs/gmod_prep.py - do not edit. Atlas layout for the GMod renderer.\nreturn ' + lua(data) + '\n')
    print(f'{pid}: ground atlas {W}x{H} ({len(gfiles)} tiles); objects atlases ' + ', '.join(f"{n} {o['size'][0]}x{o['size'][1]}" for n, o in [('summer', objects)] + [(k, v['objects']) for k, v in seasons.items()]) + f' -> {out_lua}')


if __name__ == '__main__':
    main(sys.argv[1])
