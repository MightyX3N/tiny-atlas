"""Validate an asset pack addon with the same Lua code the game uses (LuaJIT 2.1, like GMod and LÖVE).
usage: check_pack.py ADDON_DIR [BASE_ADDON_DIR]   -> prints the report, writes pack.json next to the Lua file for tools"""
import glob, json, os, sys
from lupa import luajit21 as lj

L = lj.LuaRuntime(unpack_returned_tuples=True)

def load_pack(addon):
    luas = [f for f in glob.glob(os.path.join(addon, 'lua', 'tinyatlas', 'packs', '*.lua')) if not f.endswith('_gmod.lua')]
    if len(luas) != 1: raise SystemExit(f'{addon}: expected exactly one lua/tinyatlas/packs/<id>.lua, found {len(luas)}')
    src = open(luas[0], encoding='utf-8').read()
    # packs are data: run the file with an empty environment (no os, io, require, ...)
    fn = L.eval('function(s) local f, e = loadstring(s, "pack") if not f then return nil, e end setfenv(f, {}) local ok, r = pcall(f) if not ok then return nil, r end return r, nil end')
    pack, e = fn(src)
    if pack is None: raise SystemExit(f'{luas[0]}: the pack file failed to load: {e}')
    return L, pack, luas[0]

def to_py(v):
    if hasattr(v, 'items'):
        d = dict(v.items())
        if d and all(isinstance(k, int) for k in d): return [to_py(d[i]) for i in sorted(d)]
        return {k: to_py(x) for k, x in d.items()}
    return v

def check(addon, base_addon=None):
    L, pack, luafile = load_pack(addon)
    pid = pack['id']
    mat = os.path.join(addon, 'materials', 'tinyatlas', 'packs', pid)
    base = load_pack(base_addon)[1] if base_addon else None
    V = L.execute(open(os.path.join(os.path.dirname(__file__), 'validate.lua')).read())
    fs = L.table_from({'exists': lambda p: os.path.isfile(os.path.join(mat, p)),
                       'read': lambda p: open(os.path.join(mat, p), 'rb').read() if os.path.isfile(os.path.join(mat, p)) else None})
    rep = V.validate(pack, fs, base)
    r = to_py(rep)
    for k in ('errors', 'warnings', 'info'): r[k] = r.get(k) or []
    json.dump(to_py(pack), open(os.path.join(mat, 'pack.json'), 'w'), indent=1)
    json.dump({'id': pid}, open(os.path.join(addon, 'pack_index.json'), 'w'))
    return r

if __name__ == '__main__':
    r = check(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None)
    print('OK' if r['ok'] else 'FAILED', '| publishable:', r.get('publishable'))
    for k in ('errors', 'warnings', 'info'):
        for m in r[k]: print(f"  {dict(errors='error', warnings='warning', info='note')[k]}: {m}")
    sys.exit(0 if r['ok'] else 1)
