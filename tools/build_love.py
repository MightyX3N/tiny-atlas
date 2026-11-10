"""Puts the standalone (LÖVE 12) together in one folder: the LÖVE layer (game/love), the shared world code
(gamemode atlas/ and core/), the routes and the asset packs. Run it with LÖVE 12: `lovec <folder>`.

usage: python3 tools/build_love.py <out dir> [--exe <love-11.5-win64 folder> <exe out dir>]
  --exe also makes a Windows build: LÖVE's love.exe with the game fused onto it (TinyAtlas.exe, and
  TinyAtlas-console.exe from lovec.exe, which shows the status lines), LÖVE's DLLs and licence.
"""
import os, shutil, sys, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
GM = os.path.join(REPO, "game", "gamemodes", "tinyatlas")
out = sys.argv[1]
if os.path.exists(out):
    shutil.rmtree(out)
os.makedirs(out)

def copy_tree(src, dst, keep=lambda p: True):
    for root, _, files in os.walk(src):
        for f in files:
            p = os.path.join(root, f)
            rel = os.path.relpath(p, src)
            if not keep(rel):
                continue
            d = os.path.join(dst, rel)
            os.makedirs(os.path.dirname(d), exist_ok=True)
            shutil.copy2(p, d)

copy_tree(os.path.join(REPO, "game", "love"), out, lambda p: p.endswith(".lua"))
copy_tree(os.path.join(GM, "gamemode", "atlas"), os.path.join(out, "atlas"), lambda p: p.endswith(".lua"))
copy_tree(os.path.join(GM, "gamemode", "core"), os.path.join(out, "core"), lambda p: p.endswith(".lua"))
copy_tree(os.path.join(GM, "routes"), os.path.join(out, "routes"), lambda p: p.endswith(".gpx"))
for pack in ("tinyatlas_pack_default", "tinyatlas_pack_city"):
    src = os.path.join(REPO, "packs", pack)
    copy_tree(os.path.join(src, "lua"), os.path.join(out, "packs", pack, "lua"), lambda p: not p.endswith("_gmod.lua"))
    copy_tree(os.path.join(src, "materials"), os.path.join(out, "packs", pack, "materials"),
              lambda p: p.endswith(".png") or p.endswith(".jpg"))
    for extra in ("SOURCES.md",):
        if os.path.exists(os.path.join(src, extra)):
            shutil.copy2(os.path.join(src, extra), os.path.join(out, "packs", pack, extra))
n = sum(len(f) for _, _, f in os.walk(out))
size = sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(out) for f in fs)
print("%d files, %.1f MB in %s" % (n, size / 1e6, out))

if "--exe" in sys.argv:
    i = sys.argv.index("--exe")
    love_dir, exe_out = sys.argv[i + 1], sys.argv[i + 2]
    os.makedirs(exe_out, exist_ok=True)
    game = os.path.join(exe_out, "game.love.tmp")
    with zipfile.ZipFile(game, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for root, _, files in os.walk(out):
            for f in files:
                p = os.path.join(root, f)
                z.write(p, os.path.relpath(p, out))
    data = open(game, "rb").read()
    for exe, name in (("love.exe", "TinyAtlas.exe"), ("lovec.exe", "TinyAtlas-console.exe")):
        with open(os.path.join(exe_out, name), "wb") as o:
            o.write(open(os.path.join(love_dir, exe), "rb").read())
            o.write(data)
    os.remove(game)
    for f in os.listdir(love_dir):
        if f.lower().endswith(".dll"):
            shutil.copy2(os.path.join(love_dir, f), exe_out)
    shutil.copy2(os.path.join(love_dir, "license.txt"), os.path.join(exe_out, "LOVE-license.txt"))
    print("Windows build in", exe_out, sorted(os.listdir(exe_out)))
