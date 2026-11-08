"""Builds the default asset pack (an addon folder) from the purchased/free asset packs on disk.
usage: make_default_pack.py ASSET_DIR OUT_ADDON_DIR"""
import json, os, shutil, sys
import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

A, OUT = sys.argv[1], sys.argv[2]
PID = 'default'
MAT = os.path.join(OUT, 'materials', 'tinyatlas', 'packs', PID)
LUA = os.path.join(OUT, 'lua', 'tinyatlas', 'packs')
for d in ('ground', 'trees', 'props', 'buildings', 'bikes'): os.makedirs(os.path.join(MAT, d), exist_ok=True)
os.makedirs(LUA, exist_ok=True)
T = os.path.join(A, 'terrain', 'tiles_192')


def unwarp(path, n=32):
    """Iso diamond tile -> seamless square: lay it out 3x3 on its iso grid and read the middle cell back."""
    t = Image.open(path).convert('RGBA'); can = Image.new('RGBA', (256, 128), (0, 0, 0, 0))
    for r in range(3):
        for c in range(3): can.alpha_composite(t, (32 * (c - r) + 64, 16 * (c + r)))
    im = np.array(can); out = np.zeros((n, n, 4), np.uint8)
    for j in range(n):
        for i in range(n):
            gu, gv = 1 + (i + .5) / n, 1 + (j + .5) / n
            out[j, i] = im[int(16 * (gu + gv)), int(32 * (gu - gv) + 96)]
    out[..., 3] = 255
    return out


def tile(name, v=0): return unwarp(f'{T}/{name}/{name}_v{v}.png')
def tiles(name): return [tile(name, v) for v in range(4)] if os.path.exists(f'{T}/{name}/{name}_v3.png') else [tile(name)]
def tint(t, mul): o = t.astype(float); o[..., :3] = np.clip(o[..., :3] * np.array(mul), 0, 255); return o.astype(np.uint8)


def asphalt(level=92):
    g = tile('gravel').astype(float); lum = g[..., :3].mean(-1, keepdims=True)
    base = (lum - lum.mean()) * 0.35 + level
    return np.clip(np.concatenate([base * .98, base * .97, base * 1.02, np.full_like(base, 255)], -1), 0, 255).astype(np.uint8)


ground = {
    'urban': [tint(tile('flagstone'), (.80, .78, .76))], 'grass': tiles('grass'),
    'scrub': [tint(t, (.75, .85, .75)) for t in tiles('grass')], 'water': [tile('water')], 'asphalt': [asphalt()],
    'paving': [tile('flagstone')], 'cobble': [tile('cobble')], 'gravel': [tile('gravel')], 'sand': tiles('sand'),
    'cycleway': [tint(asphalt(), (1.25, .82, .78))], 'dirt': tiles('dirt'), 'rail': [tint(tile('gravel'), (.8, .75, .7))],
    'pitch': [tint(t, (.9, 1.08, .85)) for t in tiles('grass')], 'farmland': [tile('farmland')],
    'forest_floor': [tint(t, (.7, .78, .62)) for t in tiles('grass')], 'meadow': [tint(t, (1.05, 1.05, .9)) for t in tiles('grass')],
    'rock': [tint(tile('flagstone'), (.75, .75, .76))], 'snow': tiles('snow_ground'), 'wetland': tiles('mud'),
    'orchard': [tint(t, (.92, 1.0, .85)) for t in tiles('grass')], 'rural': tiles('grass'),
    'parking': [asphalt(105)], 'dry_grass': tiles('grass_dry'),
}
ground_files = {}
for tag, ims in ground.items():
    ground_files[tag] = []
    for i, im in enumerate(ims):
        f = f'ground/{tag}_{i + 1}.png'; Image.fromarray(im).save(os.path.join(MAT, f)); ground_files[tag].append(f)
winter = {'grass': tiles('snow_ground'), 'rural': tiles('snow_ground'), 'meadow': tiles('snow_ground'),
          'forest_floor': [tint(t, (.92, .95, 1)) for t in tiles('snow_ground')], 'farmland': tiles('snow_ground')}
winter_files = {}
for tag, ims in winter.items():
    winter_files[tag] = []
    for i, im in enumerate(ims):
        f = f'ground/{tag}_winter_{i + 1}.png'; Image.fromarray(im).save(os.path.join(MAT, f)); winter_files[tag].append(f)
Image.fromarray(tile('water')).save(os.path.join(MAT, 'water.png'))

# ---- trees: cut the sprite sheet, sort by colour and shape
sheet = Image.open(os.path.join(A, 'trees', 'Treeeeeeeeeeeeeeeeeeeeeeee', 'treeeeeee.png')).convert('RGBA')
arr = np.array(sheet); lab, n = ndimage.label(ndimage.binary_dilation(arr[..., 3] > 0, iterations=6))
groups = {'broadleaf': [], 'conifer': [], 'autumn': [], 'bare': []}
for i, sl in enumerate(ndimage.find_objects(lab)):
    hh, ww = sl[0].stop - sl[0].start, sl[1].stop - sl[1].start
    if hh < 60: continue
    crop = arr[sl].copy(); crop[lab[sl] != i + 1] = 0
    px = crop[crop[..., 3] > 0][:, :3].astype(float); r, g, b = px.mean(0)
    if g > r * 1.15 and g > b: groups['conifer' if ww / hh < 0.62 else 'broadleaf'].append(crop)
    elif r > g * 1.05: groups['autumn'].append(crop)
    else: groups['bare'].append(crop)
# the tree pack has no conifers: draw a few original pixel pines in the same palette
def pine(seed, w=44, h=96):
    rng = np.random.default_rng(seed); im = Image.new('RGBA', (w, h)); d = ImageDraw.Draw(im)
    d.rectangle([w // 2 - 2, h - 14, w // 2 + 1, h - 1], fill='#5a3d28'); d.rectangle([w // 2 - 2, h - 14, w // 2 - 1, h - 1], fill='#6e4c32')
    tiers = 5 + seed % 2; top = 4
    for t in range(tiers):
        y0 = top + t * (h - 22) // tiers; y1 = y0 + (h - 22) // tiers + 8; half = 5 + (t + 1) * (w // 2 - 6) // tiers
        d.polygon([(w // 2, y0), (w // 2 - half, y1), (w // 2 + half, y1)], fill='#2e5a2a')
        d.polygon([(w // 2, y0), (w // 2 - half, y1), (w // 2 - half // 3, y1)], fill='#24481f')
        d.line([(w // 2 - half, y1), (w // 2 + half, y1)], fill='#1d3a19')
        for k in range(int(half * 1.5)):
            x = int(rng.integers(w // 2 - half + 2, w // 2 + half - 1)); y = int(rng.integers(y0 + (y1 - y0) // 2, y1))
            if im.getpixel((x, y))[3]: im.putpixel((x, y), (74, 120, 60, 255) if x > w // 2 else (40, 82, 36, 255))
    return np.array(im)
groups['conifer'] = [pine(s) for s in range(4)]
tree_files = {}
for k, ims in groups.items():
    tree_files[k] = []
    for i, im in enumerate(ims):
        f = f'trees/{k}_{i + 1}.png'; Image.fromarray(im).save(os.path.join(MAT, f)); tree_files[k].append(f)

# ---- props from the nature set (one rotation each per season), bushes double as shrubs
NAT = os.path.join(A, 'terrain', 'nature_192')
props = {}
for season in ('summer', 'autumn', 'winter'):
    for name in ('flowers', 'grass_tuft', 'rock_small', 'rock_large', 'pebbles', 'bush', 'bush_large', 'log', 'stump', 'boulders'):
        for r in range(4):
            src = os.path.join(NAT, season, f'{name}_r{r}.png')
            if os.path.exists(src):
                f = f'props/{name}_{season}_{r}.png'; shutil.copy(src, os.path.join(MAT, f)); props.setdefault((name, season), []).append(f)

# ---- bushes (same creator as the trees): 34 on a 6 x 6 sheet, grouped by colour into seasons
BUSH = os.path.join(A, 'bushes', 'bushbushbush-Bush.png')
bush_files = {}
if os.path.exists(BUSH):
    os.makedirs(os.path.join(MAT, 'props', 'bushes'), exist_ok=True)
    sheet = Image.open(BUSH).convert('RGBA'); cw_, ch_ = sheet.width / 6, sheet.height / 6
    colour = ['green'] * 4 + ['olive'] * 4 + ['pink'] * 4 + ['frost'] * 4 + ['orange'] * 4 + ['yellow'] * 4 + ['mint'] * 4 + ['amber'] * 4 + ['red'] * 2
    for k in range(34):
        r_, c_ = divmod(k, 6)
        cell = sheet.crop((int(c_ * cw_), int(r_ * ch_), int((c_ + 1) * cw_), int((r_ + 1) * ch_)))
        bb = cell.getchannel('A').point(lambda a: 255 if a > 40 else 0).getbbox()
        if not bb: continue
        f = f'props/bushes/{colour[k]}_{k}.png'; cell.crop(bb).save(os.path.join(MAT, f)); bush_files.setdefault(colour[k], []).append(f)
BG = lambda *names: [f for n in names for f in bush_files.get(n, [])]
bush_summer = BG('green', 'olive', 'mint') or props.get(('bush_large', 'summer'), [])
bush_flower = BG('pink') or bush_summer
bush_autumn = BG('orange', 'yellow', 'amber', 'red') or bush_summer
bush_winter = BG('frost') or bush_summer

# ---- rocks (same creator): 20 stone colours x 50 rocks on a 10 x 5 sheet. Realistic colours only here;
# leave out the shapes that read as fantasy (crystals, stone circle, dolmens, spires)
ROCKS = os.path.join(A, 'rocks')
rock_files = {}
SKIP_ROCK = {31, 33, 34, 35, 37, 44, 45, 46}
if os.path.isdir(ROCKS):
    os.makedirs(os.path.join(MAT, 'props', 'rocks'), exist_ok=True)
    for mat_ in ('gray', 'granite', 'slate', 'dark_gray', 'brown', 'mossy', 'limestone', 'sandstone', 'sand_beige', 'snowy'):
        src = os.path.join(ROCKS, f'{mat_}_isometric.png')
        if not os.path.exists(src): continue
        sh = Image.open(src).convert('RGBA'); cw_, ch_ = sh.width / 10, sh.height / 5
        for k in range(50):
            if k in SKIP_ROCK: continue
            r_, c_ = divmod(k, 10)
            cell = sh.crop((int(c_ * cw_), int(r_ * ch_), int((c_ + 1) * cw_), int((r_ + 1) * ch_)))
            bb = cell.getchannel('A').point(lambda a: 255 if a > 40 else 0).getbbox()
            if not bb: continue
            size = 'small' if r_ == 0 else 'medium' if r_ == 1 else 'large'
            f = f'props/rocks/{mat_}_{k}.png'; cell.crop(bb).save(os.path.join(MAT, f)); rock_files.setdefault((mat_, size), []).append(f)
RK = lambda mats, size: [f for m_ in mats for f in rock_files.get((m_, size), [])]

# ---- grass tufts (same creator): 25 sheets of 81 tufts (9 x 9). Green for summer, yellow and red for
# autumn, grey-green for dry grass, the frosty teal for winter. A handful from each.
GRASS = os.path.join(A, 'grass')
grass_files = {}
if os.path.isdir(GRASS):
    os.makedirs(os.path.join(MAT, 'props', 'grass'), exist_ok=True)
    pick = {'green': (7, 8, 10, 3), 'dry': (13, 14), 'yellow': (21, 23), 'red': (16, 17), 'frost': (20,)}
    for grp, sheets in pick.items():
        for sn in sheets:
            src = os.path.join(GRASS, f'Grass{sn}.png')
            if not os.path.exists(src): continue
            sh = Image.open(src).convert('RGBA')
            for k in range(0, 81, 7):              # every 7th tuft: 12 per sheet, spread over the sheet's rows
                r_, c_ = divmod(k, 9)
                x0, y0 = 38 + 80.33 * c_, 26 + 49.1 * r_
                cell = sh.crop((int(x0), int(y0), int(x0 + 80.33), int(y0 + 49.1)))
                bb = cell.getchannel('A').point(lambda a: 255 if a > 40 else 0).getbbox()
                if not bb or (bb[2] - bb[0]) < 12: continue
                f = f'props/grass/{grp}_{sn}_{k}.png'; cell.crop(bb).save(os.path.join(MAT, f)); grass_files.setdefault(grp, []).append(f)
GR = lambda *g: [f for n_ in g for f in grass_files.get(n_, [])]

# ---- water: seamless looping animations baked with the WOWe Generator engine (MIT, Yavuz), headless
water_anim = {}
try:
    sys.path.insert(0, os.path.dirname(__file__))
    from wowe_bake import bake
    from wowe_tile import make as make_tiled
    tiled = os.path.join(OUT, '..', '.wowe_tiled_tmp'); make_tiled(tiled)
    os.makedirs(os.path.join(MAT, 'water'), exist_ok=True)
    for name, kind, look in (('still', 'still', 'brook'), ('river', 'river', 'brook')):
        ims = bake(kind, look, (112, 112), 16, 3, {'cell': 14, 'rcell': 14}, tiled_root=tiled)
        sheet = Image.new('RGBA', (112, 112 * len(ims)))
        for i, im in enumerate(ims): sheet.paste(im, (0, 112 * i))
        sheet.save(os.path.join(MAT, 'water', f'{name}.png'))
        ims[0].save(os.path.join(MAT, 'water', f'{name}_0.png'))
        water_anim[name] = {'sheet': f'water/{name}.png', 'frames': len(ims), 'ms': 90, 'tile_metres': 11.2}
    water_anim['river']['flows'] = 'down'          # the river loop flows toward the bottom of the image
    shutil.rmtree(tiled, ignore_errors=True)
except Exception as e:
    print('water bake skipped:', e)

# ---- building facades and roofs (pixel art drawn here, Lyon-ish palette)
cv = Image.new('RGBA', (16 * 6, 40), (128, 128, 128, 255)); c = ImageDraw.Draw(cv, 'RGBA')   # 'RGBA' mode = blend translucent colours
walls = ['#d8a35f', '#d99a86', '#e6d3a8', '#e2bf6c', '#c4b8a6', '#cf8a5c']
shut = ['#5d7a52', '#7a5a3a', '#6d8a99', '#8a8a7a', '#5d7a52', '#7a5a3a']
shop = ['#8a2f2a', '#2f5a3a', '#2d4a7a', '#7a5a2a', '#5a2f5a', '#2f2f2f']
for s in range(6):
    ox = s * 16
    c.rectangle([ox, 0, ox + 15, 39], fill=walls[s])
    wd = tuple(int(int(walls[s][i:i + 2], 16) * .92) for i in (1, 3, 5))       # plaster speckle, a shade darker
    for k in range(40): c.point((ox + (k * 7) % 16, (k * 11) % 20), fill=wd)
    c.rectangle([ox + 2, 4, ox + 3, 14], fill=shut[s]); c.rectangle([ox + 12, 4, ox + 13, 14], fill=shut[s])
    c.rectangle([ox + 4, 4, ox + 11, 14], fill='#2f3a46')
    c.rectangle([ox + 5, 5, ox + 7, 8], fill='#4c6072'); c.rectangle([ox + 9, 5, ox + 10, 8], fill='#4c6072')
    wl = tuple(min(255, int(int(walls[s][i:i + 2], 16) * 1.18)) for i in (1, 3, 5))
    c.line([ox + 3, 15, ox + 12, 15], fill=wl); c.line([ox, 19, ox + 15, 19], fill=wd)
    c.rectangle([ox, 20, ox + 15, 39], fill=tuple(int(int(walls[s][i:i + 2], 16) * .82) for i in (1, 3, 5)))
    c.rectangle([ox + 2, 25, ox + 13, 37], fill='#2a333c'); c.rectangle([ox + 3, 26, ox + 12, 31], fill='#56707f')
    c.rectangle([ox + 1, 21, ox + 14, 23], fill=shop[s])
cv.convert('RGB').save(os.path.join(MAT, 'buildings', 'facades.png'))
rf = Image.new('RGBA', (16, 16), '#b8694a'); d = ImageDraw.Draw(rf, 'RGBA')
for y in range(0, 16, 2): d.line([0, y, 15, y], fill='#a65b40' if y % 4 else '#c27654')
for k in range(20): d.point(((k * 5) % 16, (k * 3) % 16), fill='#94503a')
rf.convert('RGB').save(os.path.join(MAT, 'buildings', 'roof_tiles.png'))
shutil.copy(os.path.join(A, 'bikes', 'x', 'Free Low Poly Bike Models', 'Textures', 'PBR MetalicRoughness', '512',
                         'Low Poly Cycles Staggered_Low Poly Cycles (BMX, Mountain Bike, Unicycle) 1_BaseColor.png'),
            os.path.join(MAT, 'bikes', 'bike_basecolor.png'))
shutil.copy(os.path.join(A, 'terrain', 'preview', 'ter_nature.png'), os.path.join(MAT, 'preview.png'))


def lua(v, ind=1):
    p = '  ' * ind
    if isinstance(v, dict):
        if not v: return '{}'
        items = []
        for k, x in v.items():
            key = k if isinstance(k, str) and k.isidentifier() else f'["{k}"]'
            items.append(f'{p}{key} = {lua(x, ind + 1)},')
        return '{\n' + '\n'.join(items) + '\n' + '  ' * (ind - 1) + '}'
    if isinstance(v, (list, tuple)):
        if all(not isinstance(x, (dict, list, tuple)) for x in v): return '{ ' + ', '.join(lua(x) for x in v) + ' }'
        return '{\n' + '\n'.join(f'{p}{lua(x, ind + 1)},' for x in v) + '\n' + '  ' * (ind - 1) + '}'
    if isinstance(v, bool): return 'true' if v else 'false'
    if v is None: return 'nil'
    if isinstance(v, (int, float)): return repr(v)
    return '"' + str(v).replace('\\', '\\\\').replace('"', '\\"') + '"'


P = lambda name, season, dens, size=1.0: {'sprites': props.get((name, season), []), 'density': dens, 'size': size}
B = lambda files, dens, size=1.0: {'sprites': files, 'density': dens, 'size': size}
theme = {
    'id': PID, 'name': 'Default', 'author': 'Tiny Atlas', 'version': '1.0.0',
    'license': 'Ships with the game only. Art: Antahonist terrain tiles (free, no resale), Pixel Art Isometric Tree pack and Bush pack (same creator), VOiD1 Gaming Low-Poly Bike Models.',
    'credits': ['Terrain & nature: Antahonist (antahonist.itch.io)', 'Trees: Pixel Art Isometric Tree pack', 'Bushes, rocks, grass: Pixel Art Isometric Bush / Rock / Grass packs (same creator as the trees)', 'Water: baked with WOWe Generator by Yavuz (MIT)', 'Bike: VOiD1 Gaming'],
    'local_only': False,
    'tile_metres': 3.3, 'edge_darken': 0.28,
    'ground': ground_files,
    'ground_priority': {'water': 1, 'grass': 2, 'scrub': 2, 'forest_floor': 2, 'meadow': 2, 'farmland': 2, 'rural': 2,
                        'orchard': 2, 'wetland': 2, 'dry_grass': 2, 'sand': 3, 'dirt': 4, 'gravel': 4, 'paving': 5,
                        'cobble': 5, 'asphalt': 6, 'parking': 6, 'rail': 6, 'cycleway': 7},
    'seasons': {'winter': {'ground': winter_files, 'trees': {'broadleaf': {'sprites': tree_files['bare'] or tree_files['broadleaf']},
                                                             'shrub': {'sprites': bush_winter}},
                           'props': {'scrub': [B(bush_winter, 0.8, 1.3)], 'forest_floor': [P('log', 'winter', 0.08, 1.2), B(bush_winter, 0.3, 1.2)],
                                     'dry_grass': [B(bush_winter, 0.2, 1.0), B(GR('frost'), 0.6, 0.45)],
                                     'grass': [B(GR('frost'), 0.4, 0.4)], 'meadow': [B(GR('frost'), 0.8, 0.45)], 'rural': [B(GR('frost'), 0.3, 0.45)],
                                     'rock': [B(RK(('snowy',), 'large') or RK(('gray',), 'large'), 0.25, 2.4), B(RK(('snowy',), 'medium'), 0.35, 1.2),
                                              B(RK(('snowy',), 'small'), 0.6, 0.6)]}},
                'autumn': {'trees': {'broadleaf': {'sprites': tree_files['autumn'] or tree_files['broadleaf']},
                                     'shrub': {'sprites': bush_autumn}},
                           'props': {'scrub': [B(bush_autumn, 0.8, 1.4)], 'forest_floor': [P('log', 'autumn', 0.08, 1.2), P('stump', 'autumn', 0.1, 0.8), B(bush_autumn, 0.35, 1.3)],
                                     'dry_grass': [B(BG('amber', 'orange') or bush_autumn, 0.25, 1.1), B(GR('yellow', 'red'), 1.0, 0.5)],
                                     'meadow': [B(GR('yellow', 'green', 'red'), 1.4, 0.55)], 'grass': [B(GR('green', 'yellow'), 0.8, 0.45)]}}},
    'water': {'texture': 'water/still_0.png' if water_anim else 'water.png', 'opacity': 0.86, 'bed_tint': [0.55, 0.6, 0.62],
              **({'still': water_anim['still'], 'river': water_anim['river']} if water_anim else {})},
    'wall': {'texture': ground_files['cobble'][0], 'tint': [0.95, 0.9, 0.85]},
    'sky': {'top': '#6fa6dc', 'horizon': '#c8dbe8', 'haze': '#c8dbe8', 'fog_near': 300, 'fog_far': 7000},
    'sun': {'colour': '#fff1d6', 'strength': 2.4, 'ambient': '#dfeeff', 'ground': '#6b6050'},
    'trees': {'broadleaf': {'sprites': tree_files['broadleaf'], 'height': [10, 16]},
              'conifer': {'sprites': tree_files['conifer'] or tree_files['broadleaf'], 'height': [12, 22]},
              'orchard': {'sprites': tree_files['broadleaf'], 'height': [4, 6]},
              'shrub': {'sprites': bush_summer + bush_flower[:2], 'height': [1.2, 2.4]}},
    'props': {'grass': [P('flowers', 'summer', 0.25, 0.6), B(GR('green') or props.get(('grass_tuft', 'summer'), []), 0.9, 0.45)],
              'meadow': [P('flowers', 'summer', 0.8, 0.6), B(GR('green') or props.get(('grass_tuft', 'summer'), []), 1.6, 0.55)],
              'rural': [B(GR('green'), 0.5, 0.5), B(RK(('gray', 'brown'), 'small'), 0.05, 0.6)],
              'farmland': [B(GR('green', 'dry'), 0.15, 0.5)],
              'orchard': [B(GR('green'), 0.6, 0.45)],
              'wetland': [B(GR('dry', 'green'), 1.2, 0.6)],
              'forest_floor': [P('log', 'summer', 0.08, 1.2), P('stump', 'summer', 0.1, 0.8), B(bush_summer, 0.35, 1.3),
                               B(RK(('mossy',), 'medium'), 0.08, 1.0), B(GR('green'), 0.3, 0.45)],
              'rock': [B(RK(('gray', 'granite', 'slate'), 'large') or props.get(('rock_large', 'summer'), []), 0.25, 2.4),
                       B(RK(('gray', 'granite', 'slate', 'dark_gray'), 'medium'), 0.35, 1.2), B(RK(('gray', 'slate'), 'small'), 0.6, 0.6)],
              'scrub': [B(bush_summer, 0.8, 1.4), B(bush_flower, 0.12, 1.2), B(RK(('brown', 'gray'), 'small'), 0.1, 0.6)],
              'sand': [B(RK(('sandstone', 'sand_beige'), 'small') or props.get(('pebbles', 'summer'), []), 0.12, 0.5)],
              'dry_grass': [B(BG('olive') or bush_summer, 0.25, 1.1), B(GR('dry', 'yellow'), 1.0, 0.5)]},
    'buildings': {'facades': 'buildings/facades.png', 'styles': 6, 'bay_metres': 2.9, 'floor_metres': 3.2,
                  'ground_floor_metres': 4.2, 'roofs': ['buildings/roof_tiles.png'],
                  'roof_tints': [[1, 1, 1], [1, 1, 1], [1, 1, 1], [0.62, 0.68, 0.78], [0.55, 0.58, 0.62], [1.05, 0.95, 0.85]]},
    'bridge': {'side': '#b9a88f', 'wall': 'bridge/brick_1.png', 'stone': 'bridge/stone_1.png', 'parapet': 'bridge/parapet_1.png',
               'arch': 'bridge/arch_1.png', 'tile_metres': 1.5, 'parapet_height': 1.0, 'deck_thickness': 0.7},
    'filter': {'pixel': 3, 'colours': 64},
    'rider': {'jersey': '#c8392f', 'shorts': '#1f1f24', 'skin': '#e3b48f', 'helmet': '#f2f2f2'},
    'bikes': {'mtb': {'texture': 'bikes/bike_basecolor.png'}},
}
import bridge_art; bridge_art.main(OUT, PID)        # bridge parts (drawn, not from an asset pack)
open(os.path.join(LUA, PID + '.lua'), 'w').write('-- Tiny Atlas asset pack. Format: docs/FORMATS.md\nreturn ' + lua(theme) + '\n')
json.dump({'title': 'Tiny Atlas - Default pack', 'type': 'gamemode', 'tags': ['fun'], 'ignore': []},
          open(os.path.join(OUT, 'addon.json'), 'w'), indent=1)
print({k: len(v) for k, v in tree_files.items()}, len(props), 'prop groups', {k: len(v) for k, v in bush_files.items()}, 'bushes',
      sum(len(v) for v in rock_files.values()), 'rocks', {k: len(v) for k, v in grass_files.items()}, 'grass', list(water_anim), 'water')
