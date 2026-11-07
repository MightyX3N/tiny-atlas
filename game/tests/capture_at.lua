-- Capture what the GMod renderer draws at given distances along a route (for tools/gmodcheck/shoot.js).
--   luajit.py capture_at.lua <routes dir> <route id> <out prefix> s1 [s2 ...]   (s in metres; "b" suffix = look back)
local ROUTES, ROUTE, OUT = arg[1], arg[2], arg[3]
local PACK = "../../packs/tinyatlas_pack_default"
local DATA = os.tmpname() .. "_gmdata"
os.execute('mkdir -p "' .. DATA .. '/tinyatlas/routes" && ln -s "$(cd "' .. ROUTES .. '" && pwd)/' .. ROUTE .. '" "' .. DATA .. '/tinyatlas/routes/' .. ROUTE .. '"')
local F = dofile("fakegmod.lua")(DATA, "../gamemodes/tinyatlas/gamemode")
dofile("fakegmod_render.lua")(F, { lua_roots = { PACK .. "/lua" }, material_roots = { PACK .. "/materials" } })
F.keep = true
include("cl_init.lua")
local W = TinyAtlas.World
local ffi = require("ffi")
for i = 4, #arg do
  local s, back = tonumber((arg[i]:gsub("b$", ""))), arg[i]:sub(-1) == "b"
  F.run("ta_perftest", ROUTE, "0", "100000")
  W.opts.start = s; W.s = s
  local n = 0
  while W.loading and n < 3000 do F.render_frame(1 / 60); n = n + 1 end
  for _ = 1, 30 do F.render_frame(1 / 60) end
  F.keys[KEY_B] = back or nil
  F.capture = true; F.render_frame(1 / 60); F.capture = false
  F.keys[KEY_B] = nil
  local groups, order = {}, {}
  for _, d in ipairs(F.draws) do
    local m = d.mat; local name = m and (m.name or "color") or "none"
    local g = groups[name]
    if not g then
      local tex = m and m.params and m.params["$basetexture"]
      g = { name = name, tex = type(tex) == "table" and tex.tex or tostring(tex), alpha = m and m.params and m.params["$alphatest"] or 0,
            translucent = m and m.params and m.params["$translucent"] or 0, list = {}, n = 0 }
      groups[name] = g; order[#order + 1] = g
    end
    g.list[#g.list + 1] = d; g.n = g.n + d.mesh.n
  end
  local cam = F.camera
  local out = io.open(OUT .. "_" .. arg[i] .. ".bin", "wb")
  local hdr = { string.format('{"camera":{"pos":[%f,%f,%f],"ang":[%f,%f,%f],"fov":%f},"rider":[%f,%f,%f],"groups":[',
    cam.pos.x, cam.pos.y, cam.pos.z, cam.ang.p, cam.ang.y, cam.ang.r, cam.fov, F.rider_box.x, F.rider_box.y, F.rider_box.z) }
  for k, g in ipairs(order) do
    hdr[#hdr + 1] = string.format('%s{"name":"%s","tex":"%s","alphatest":%s,"translucent":%s,"verts":%d}', k > 1 and "," or "",
      g.name, g.tex, tostring(g.alpha), tostring(g.translucent), g.n)
  end
  hdr[#hdr + 1] = "]}\n"
  out:write(table.concat(hdr))
  for _, g in ipairs(order) do
    local buf = ffi.new("float[?]", g.n * 8); local k2 = 0
    for _, d in ipairs(g.list) do
      local data, t = d.mesh.data, d.t
      for v = 0, d.mesh.n - 1 do
        local o = v * 8
        buf[k2] = data[o + 1] + t[1]; buf[k2 + 1] = data[o + 2] + t[2]; buf[k2 + 2] = data[o + 3] + t[3]
        for c = 3, 7 do buf[k2 + c] = data[o + c + 1] end
        k2 = k2 + 8
      end
    end
    out:write(ffi.string(buf, g.n * 32))
  end
  out:close()
  print("captured " .. arg[i] .. " m")
  F.run("ta_stop")
end
os.execute('rm -rf "' .. DATA .. '"')
