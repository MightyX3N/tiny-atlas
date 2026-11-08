"""Contact sheets of a rendered ride (tools/gmodcheck/ride.js output) plus automatic picture checks.
usage: ride_sheets.py CAPTURE_PREFIX PICS_DIR OUT_DIR [per sheet]
Each tile: the rider's view (left) and the view from above (right), labelled with the distance and grade.
Checks every rider view for holes (sky colour below the horizon line) and missing textures (magenta)."""
import json, os, sys
from PIL import Image, ImageDraw

cap, pics, out = sys.argv[1], sys.argv[2], sys.argv[3]
per = int(sys.argv[4]) if len(sys.argv) > 4 else 32
os.makedirs(out, exist_ok=True)
frames = json.load(open(cap + '.json'))['frames']
SKY = (196, 216, 232)
cols, tw, th = 4, 320, 180
flagged = []

def check(im, f):
    """fraction of sky-coloured and magenta pixels in the lower 40 % of the rider view"""
    w, h = im.size
    px = im.load()
    sky = mag = n = 0
    for y in range(int(h * 0.6), h, 3):
        for x in range(0, w, 3):
            r, g, b = px[x, y]
            n += 1
            if abs(r - SKY[0]) < 10 and abs(g - SKY[1]) < 10 and abs(b - SKY[2]) < 10: sky += 1
            if r > 200 and g < 60 and b > 200: mag += 1
    return sky / n, mag / n

nsheets = (len(frames) + per - 1) // per
for si in range(nsheets):
    rows = (min(per, len(frames) - si * per) + cols - 1) // cols
    sheet = Image.new('RGB', (cols * tw * 2, rows * (th + 16)), (30, 30, 30))
    d = ImageDraw.Draw(sheet)
    for k in range(per):
        fi = si * per + k
        if fi >= len(frames): break
        a = Image.open(f'{pics}/{fi:04d}_a.jpg').convert('RGB')
        b = Image.open(f'{pics}/{fi:04d}_b.jpg').convert('RGB')
        sky, mag = check(a, frames[fi])
        if sky > 0.02 or mag > 0.001: flagged.append((fi, frames[fi]['s'], sky, mag))
        x, y = (k % cols) * tw * 2, (k // cols) * (th + 16)
        sheet.paste(a.resize((tw, th)), (x, y + 16))
        sheet.paste(b.resize((tw, th)), (x + tw, y + 16))
        f = frames[fi]
        d.text((x + 4, y + 2), f"#{fi}  {f['s'] / 1000:.3f} km  grade {f['grade']:.1f} %" + ("  HOLE?" if sky > 0.02 else "") + ("  MAGENTA" if mag > 0.001 else ""), fill=(255, 255, 255) if sky <= 0.02 else (255, 90, 90))
    sheet.save(f'{out}/sheet_{si:03d}.jpg', quality=85)
print(f'{len(frames)} frames, {nsheets} sheets, {len(flagged)} frames flagged')
for fi, s, sky, mag in flagged: print(f'  frame {fi} at {s / 1000:.3f} km: sky below the horizon {sky * 100:.1f} %, magenta {mag * 100:.2f} %')
