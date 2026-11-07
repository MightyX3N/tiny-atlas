"""Bake looping water animations with the WOWe Generator engine (MIT, by Yavuz) without Aseprite.
The engine's own modules run unchanged in LuaJIT (the Lua GMod and LOVE use); only the Aseprite-facing
parts (reading layers, UI, writing cels) are left out. Masks come from Mask.fromFunctions.

usage (as a module): bake(kind, look, size, frames, seed, out_png_prefix, overrides) -> list of PIL images"""
import os
import numpy as np
from PIL import Image
from lupa import lua54 as lupa

ROOT = os.path.join(os.path.dirname(__file__), '..', 'third_party', 'wowe', 'wowe')


def runtime(root=None, tile=0):
    L = lupa.LuaRuntime(unpack_returned_tuples=True, encoding=None)
    L.execute(f'''
      ColorMode = {{ RGB = 0, GRAY = 1, INDEXED = 2 }}
      _WOWE = {{ cache = {{}}, TILE = {tile} }}
      function _WOWE.require(name)
        local hit = _WOWE.cache[name]; if hit ~= nil then return hit end
        local chunk, err = loadfile([[{os.path.abspath(root or ROOT)}/]] .. name .. ".lua")
        if not chunk then error(err) end
        local v = chunk(_WOWE); if v == nil then v = true end
        _WOWE.cache[name] = v; return v
      end''')
    return L


def bake(kind='still', look='pool', size=(128, 128), frames=16, seed=1, overrides=None, river_angle=0, tiled_root=None):
    """kind: 'still' (whole picture is still water) or 'river' (whole picture flows, toward river_angle)."""
    W, H = size
    L = runtime(tiled_root, W if tiled_root else 0)
    f = L.eval('''function(kind, look, W, H, frames, seed, ov, angle)
      local Styles = _WOWE.require("styles"); local Mask = _WOWE.require("mask")
      local Scape = _WOWE.require("scape"); local Paint = _WOWE.require("paint")
      local p = Styles.apply(look, { frames = frames, ms = 90, seed = seed })
      if ov then for k, v in pairs(ov) do p[k] = v end end
      local all = function(x, y) return true end
      local R
      if kind == "river" then
        p.drift = 0; p.angle = angle
        R = Mask.fromFunctions(W, H, nil, nil, all)
      else
        R = Mask.fromFunctions(W, H, all, nil, nil)
      end
      local F = Scape.prepare(R, p, nil, nil)
      local map = Paint.map(p.colors, nil, nil)
      local box = Scape.box(F)
      local out = {}
      for i = 1, p.frames do
        local lv = Scape.frame(F, p, i, nil)
        out[i] = (lv:gsub(".", map))
      end
      return out, box
    end''')
    ov = L.table_from({k.encode(): (v.encode() if isinstance(v, str) else v) for k, v in (overrides or {}).items()})
    out, box = f(kind.encode(), look.encode(), W, H, frames, seed, ov, river_angle)
    bx = dict(box.items())
    bw, bh = bx.get(b'w', bx.get(3)), bx.get(b'h', bx.get(4))
    ims = []
    for i in range(1, frames + 1):
        s = out[i]
        b = bytes(s)
        a = np.frombuffer(b, np.uint8).reshape(bh, bw, 4)
        ims.append(Image.fromarray(a.copy(), 'RGBA'))
    return ims


if __name__ == '__main__':
    import sys
    ims = bake(sys.argv[1] if len(sys.argv) > 1 else 'still', sys.argv[2] if len(sys.argv) > 2 else 'pool')
    print(len(ims), ims[0].size)
