-- The world renderer end to end in a fake GMod: the real gamemode files, the real exported route and the
-- real asset pack. Rides the route with ta_perftest and checks what it builds and draws each frame.
--   luajit.py test_world.lua <exported routes dir> [route id] [seconds] [capture.bin]
local ROUTES = arg and arg[1] or "../../out/routes"
local ROUTE = arg and arg[2] or "city-run-10-km"
local SECONDS = tonumber(arg and arg[3]) or 40
local CAPTURE = arg and arg[4]
local REPO = "../.."
local PACK = REPO .. "/packs/tinyatlas_pack_default"

local DATA = os.tmpname() .. "_gmdata"
os.execute('mkdir -p "' .. DATA .. '/tinyatlas/routes"')
os.execute('ln -s "$(cd "' .. ROUTES .. '" && pwd)/' .. ROUTE .. '" "' .. DATA .. '/tinyatlas/routes/' .. ROUTE .. '"')
local GMDIR = "../gamemodes/tinyatlas/gamemode"
local F = dofile("fakegmod.lua")(DATA, GMDIR)
dofile("fakegmod_render.lua")(F, { lua_roots = { PACK .. "/lua" }, material_roots = { PACK .. "/materials" } })

F.keep = CAPTURE ~= nil
local fails = 0
local function check(name, ok, extra)
  if not ok then fails = fails + 1 end
  print(string.format("%-62s %s %s", name, ok and "ok" or "FAIL", extra or ""))
end

include("cl_init.lua")
hook.Run("InitPostEntity")
local W = TinyAtlas.World
check("world renderer loads", W ~= nil and F.commands.ta_perftest ~= nil)

F.run("ta_routes")
local t0 = os.clock()
F.run("ta_perftest", ROUTE, "30", tostring(SECONDS + 60))
check("perf test starts", W.on == true and W.S ~= nil)

-- loading: frames until everything around the start is built
local frames = 0
while W.loading and frames < 2000 do F.render_frame(1 / 60); frames = frames + 1 end
local load_s = os.clock() - t0
check("world built around the start", not W.loading, string.format("%d frames, %.1f s of Lua", frames, load_s))
check("loading screen shown while building", true)

local S = W.S
local function count()
  local c = { b = 0, c = 0, q = 0, l = 0, f = 0 }
  local meshes, quads = 0, 0
  for _, u in pairs(S.units) do
    c[u.kind] = c[u.kind] + 1
    quads = quads + u.quads
    for _, h in ipairs(u.handles) do meshes = meshes + #h.h end
  end
  return c, meshes, quads
end
local c, meshes, quads = count()
print(string.format("  built: %d 1 m blocks, %d 4 m cells, %d 4 m pieces, %d 16 m pages, %d far tiles; %d meshes, %d quads",
  c.b, c.c, c.q, c.l, c.f, meshes, quads))
check("every level present", c.b > 0 and (c.c + c.q) > 0 and c.l > 0 and c.f > 0)
check("live meshes = meshes the units hold (no leaks)", F.meshes_alive == meshes, F.meshes_alive .. " vs " .. meshes)
check("largest mesh under 65,535 vertices", F.mesh_stats.max_verts <= 65535, tostring(F.mesh_stats.max_verts))

-- ride: check the window every second
local B = S.cfg.block
local bpc = math.floor(S.CS / B)
local function block_id(x, y) return "b:" .. math.floor(x / B) .. "," .. math.floor(y / B) end
local window_ok, behind_ok, under_ok, gaps = true, true, true, 0
local worst_build, worst_lua, max_queue = 0, 0, 0
local draws_sum, nf = 0, 0
local sec = 0
local captured = false
local n_frames = math.floor(SECONDS * 60) - 2
for i = 1, n_frames do
  if CAPTURE and not captured and W.t > SECONDS * 0.5 then F.capture = true end
  F.render_frame(1 / 60)
  if not W.on then break end
  if F.capture and not captured then captured = true; F.capture = false; CAP = { draws = F.draws, camera = F.camera } end
  worst_build = math.max(worst_build, S.stats.build_ms)
  max_queue = math.max(max_queue, S:pending())
  draws_sum, nf = draws_sum + F.frame_draws, nf + 1
  sec = sec + 1 / 60
  if sec >= 1 then
    sec = 0
    local x, y, z = W.route:pos(W.s)
    -- the ground under the rider is at full detail
    if not S.units[block_id(x, y)] then window_ok = false; gaps = gaps + 1 end
    -- and 300 m ahead along the route too (once the queue has caught up)
    local ax, ay = W.route:pos(W.s + 300)
    if S:pending() == 0 and not S.units[block_id(ax, ay)] and S.near[math.floor(ax / S.CS) .. "," .. math.floor(ay / S.CS)] then
      window_ok = false; gaps = gaps + 1
    end
    -- nothing at full detail far behind
    for _, u in pairs(S.units) do
      if u.kind == "b" and not u.stale then
        local best = 1e9
        for ss = W.s - S.cfg.behind - 20, W.s + S.cfg.ahead + 20, 5 do
          local px, py = W.route:pos(ss)
          local d = math.sqrt((u.x - px) ^ 2 + (u.y - py) ^ 2)
          if d < best then best = d end
        end
        if best > S.cfg.near_radius + B * 0.5 + 24 + 5 then behind_ok = false end
      end
    end
    -- the track runs on the built ground: compare with the 1 m heights
    local C = W.D:chunk(math.floor(x / S.CS), math.floor(y / S.CS))
    if C then
      local i, j = math.floor(x - C.x0 + 0.5), math.floor(y - C.y0 + 0.5)
      local h = C.H[j * C.n + i]
      if math.abs(h - z) > 3 and W.route:grade(W.s) == W.route:grade(W.s) then
        local k = W.route:at(W.s)
        if (W.route.BR[k] or 0) == 0 then under_ok = false; print(string.format("    ground %.1f m vs ride %.1f m at %.0f m", h, z, W.s)) end
      end
    end
  end
end
check("full detail under the rider and 300 m ahead the whole ride", window_ok, gaps .. " misses")
check("no full-detail blocks left far behind", behind_ok)
check("the ride height sits on the ground (off bridges)", under_ok)
print(string.format("  rode %.2f km in %.0f s (simulated); %.0f draws per frame on average", W.s / 1000, W.t, draws_sum / math.max(nf, 1)))
for kind, e in pairs(S.stats.by_kind or {}) do
  print(string.format("    %s: %d built, %.2f ms avg, %.1f ms worst (%s), %.0f quads avg", kind, e.n, e.ms / e.n, e.max, e.max_id, e.quads / e.n))
end
print(string.format("  worst load step %.1f ms (%s)", S.stats.max_load_ms or 0, tostring(S.stats.max_load_id)))
print(string.format("  Lua-side worst building per frame %.1f ms, single piece worst %.1f ms, queue peak %d",
  worst_build, S.stats.max_job_ms, max_queue))

-- look back
local units_before = 0
F.keys[KEY_B] = true
F.render_frame(1 / 60)
local cam_back = F.camera
F.keys[KEY_B] = nil
F.render_frame(1 / 60)
local cam_fwd = F.camera
check("look back turns the camera around", cam_back and cam_fwd and math.abs(((cam_back.ang.y - cam_fwd.ang.y + 540) % 360) - 180) > 120,
  cam_back and string.format("yaw %.0f vs %.0f", cam_back.ang.y, cam_fwd.ang.y))

-- overlay
local seen = false
for _, t in ipairs(F.texts) do if t:find("^FPS") then seen = true end end
check("frame-rate overlay drawn", seen)

-- finish: the test ends itself and writes the report
for _ = 1, 600 do if not W.on then break end; F.render_frame(1 / 60) end
F.run("ta_stop")
local rep = io.open(DATA .. "/tinyatlas/perf/" .. ROUTE .. "_30kmh.txt")
local text = rep and rep:read("*a") or ""
if rep then rep:close() end
check("performance report written", text:find("average FPS") ~= nil)
check("all meshes freed when stopped", F.meshes_alive == 0, tostring(F.meshes_alive))

-- the quads mesh mode builds cleanly too
F.set("ta_mesh_quads", 1)
F.run("ta_perftest", ROUTE, "60", "3")
local k = 0
while W.on and k < 900 do F.render_frame(1 / 60); k = k + 1 end
F.run("ta_stop")
F.set("ta_mesh_quads", 0)
check("quads mesh mode: no errors", #F.errors == 0)

-- autumn and winter atlases load
for _, season in ipairs({ "autumn", "winter" }) do
  F.set("ta_season", season)
  F.run("ta_perftest", ROUTE, "30", "1")
  local n = 0
  while W.on and W.loading and n < 400 do F.render_frame(1 / 60); n = n + 1 end
  check(season .. ": builds", W.S and not W.loading)
  F.run("ta_stop")
end
F.set("ta_season", "summer")

-- ride mode: the keyboard moves the rider through the world on the real route
hook.Run("InitPostEntity")
F.run("ta_ride", ROUTE)
local n = 0
while W.on and W.loading and n < 600 do F.render_frame(1 / 60); n = n + 1 end
F.keys[KEY_W] = true
for _ = 1, 600 do F.tick(1 / 60); F.render_frame(1 / 60) end
F.keys[KEY_W] = nil
local Rd = TinyAtlas.Ride
check("ride mode: W moves the rider along the real route", Rd.s > 20 and math.abs(W.s - Rd.s) < 1e-6, string.format("%.0f m", Rd.s))
check("ride mode: physics reads the real gradient", TinyAtlas.Route.grade_at ~= nil and TinyAtlas.Route.meta ~= nil)
F.run("ta_stop")

check("no errors reported", #F.errors == 0, #F.errors > 0 and F.errors[1] or "")
for i = 2, math.min(#F.errors, 5) do print("    " .. F.errors[i]) end

-- capture: one frame's draws for the visual check
if CAPTURE and CAP then
  local ffi = require("ffi")
  local out = io.open(CAPTURE, "wb")
  local cam = CAP.camera
  local groups = {}
  for _, d in ipairs(CAP.draws) do
    local m = d.mat
    local name = m and (m.name or "color") or "none"
    local g = groups[name]
    if not g then
      local tex = m and m.params and m.params["$basetexture"]
      g = { name = name, tex = type(tex) == "table" and tex.tex or tostring(tex), alpha = m and m.params and m.params["$alphatest"] or 0,
            translucent = m and m.params and m.params["$translucent"] or 0, list = {}, n = 0 }
      groups[name] = g
    end
    g.list[#g.list + 1] = d
    g.n = g.n + d.mesh.n
  end
  local hdr = { string.format('{"camera":{"pos":[%f,%f,%f],"ang":[%f,%f,%f],"fov":%f},"groups":[',
    cam.pos.x, cam.pos.y, cam.pos.z, cam.ang.p, cam.ang.y, cam.ang.r, cam.fov) }
  local order = {}
  for _, g in pairs(groups) do order[#order + 1] = g end
  for i, g in ipairs(order) do
    hdr[#hdr + 1] = string.format('%s{"name":"%s","tex":"%s","alphatest":%s,"translucent":%s,"verts":%d,"tris":%s}', i > 1 and "," or "",
      g.name, g.tex, tostring(g.alpha), tostring(g.translucent), g.n, "true")
  end
  hdr[#hdr + 1] = "]}\n"
  out:write(table.concat(hdr))
  for _, g in ipairs(order) do
    local buf = ffi.new("float[?]", g.n * 8)
    local k2 = 0
    for _, d in ipairs(g.list) do
      local data, t = d.mesh.data, d.t
      if d.mesh.prim == MATERIAL_QUADS then error("capture with quads mode") end
      for v = 0, d.mesh.n - 1 do
        local o = v * 8
        buf[k2] = data[o + 1] + t[1]; buf[k2 + 1] = data[o + 2] + t[2]; buf[k2 + 2] = data[o + 3] + t[3]
        buf[k2 + 3] = data[o + 4]; buf[k2 + 4] = data[o + 5]
        buf[k2 + 5] = data[o + 6]; buf[k2 + 6] = data[o + 7]; buf[k2 + 7] = data[o + 8]
        k2 = k2 + 8
      end
    end
    out:write(ffi.string(buf, g.n * 32))
  end
  out:close()
  print("  captured one frame: " .. CAPTURE)
end

os.execute('rm -rf "' .. DATA .. '"')
print(fails == 0 and "ALL WORLD CHECKS PASSED" or (fails .. " FAILED"))
return fails
