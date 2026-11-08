"""Contact sheets from the per-tile surface rasters written by test_cells.lua (RASTER_PX / RASTER_DIR).
usage: sheets.py RASTER_DIR OUT_DIR [tiles per sheet] [px per tile]
Pixels no triangle covered stay magenta, so a gap anywhere shows up."""
import os, sys, glob
from PIL import Image, ImageDraw
import numpy as np
NAMES = ['none', 'ground', 'building', 'road', 'path', 'rail', 'pier', 'water', 'paved', 'sand', 'wetland', 'wood', 'park',
         'grass', 'pitch', 'cemetery', 'farmland', 'rock', 'ice', 'residential', 'commercial', 'industrial']
COL = {'none': (255, 0, 255), 'building': (184, 120, 104), 'road': (90, 90, 96), 'path': (196, 170, 120), 'rail': (120, 100, 110),
       'pier': (150, 140, 120), 'water': (70, 130, 200), 'paved': (150, 150, 150), 'sand': (230, 210, 150),
       'wetland': (110, 160, 140), 'wood': (50, 120, 60), 'park': (120, 190, 100), 'grass': (140, 200, 110),
       'pitch': (100, 180, 120), 'cemetery': (130, 170, 130), 'farmland': (210, 200, 130), 'rock': (160, 150, 140),
       'ice': (230, 240, 250), 'residential': (215, 205, 195), 'commercial': (220, 195, 195),
       'industrial': (200, 190, 210), 'ground': (200, 196, 170)}
lut = np.zeros((256, 3), np.uint8); lut[:] = (255, 0, 255)
for i, n in enumerate(NAMES): lut[i] = COL[n]
src, out = sys.argv[1], sys.argv[2]
per = int(sys.argv[3]) if len(sys.argv) > 3 else 12
tp = int(sys.argv[4]) if len(sys.argv) > 4 else 512
os.makedirs(out, exist_ok=True)
files = sorted(glob.glob(os.path.join(src, 'r_*.pgm')))
cols = 4; gaps = []
for s in range(0, len(files), per):
    chunk = files[s:s + per]; rows = (len(chunk) + cols - 1) // cols
    sheet = Image.new('RGB', (cols * tp, rows * (tp + 18)), (255, 255, 255)); d = ImageDraw.Draw(sheet)
    for i, f in enumerate(chunk):
        a = np.array(Image.open(f))
        miss = int((a == 0).sum())
        if miss: gaps.append((os.path.basename(f), miss))
        im = Image.fromarray(lut[a]).resize((tp, tp), Image.NEAREST)
        x, y = (i % cols) * tp, (i // cols) * (tp + 18)
        sheet.paste(im, (x, y + 18))
        d.text((x + 4, y + 3), os.path.basename(f)[2:-4] + (f'  UNCOVERED PX {miss}' if miss else ''), fill=(200, 0, 0) if miss else (0, 0, 0))
    p = os.path.join(out, f'sheet_{s // per:02d}.png'); sheet.save(p); print(p)
print('tiles with uncovered pixels:', len(gaps), gaps[:20])
