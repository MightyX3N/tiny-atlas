-- The world renderer in Garry's Mod: takes over drawing the scene, streams the route around the rider,
-- and has a performance test that rides a route on its own and writes what it measured.
--
--   ta_ride <route>                       ride a route (keyboard W / your trainer through OmniPlay)
--   ta_perftest <route> [km/h] [seconds]  ride it automatically, show and log the frame rate
--   ta_stop                               back to the normal game view
-- Routes live in garrysmod/data/tinyatlas/routes/<route>/ (made by tools/gmod_export.py).
-- Hold B to look back.
local Data = include("world/world_data.lua")
local MeshB = include("world/world_mesh.lua")
local Stream = include("world/world_stream.lua")
local RouteT = include("world/route.lua")
local Look = include("world/look.lua")

TinyAtlas.World = TinyAtlas.World or {}
local W = TinyAtlas.World
local U = 52.4934                 -- Source units per metre (1 unit = 0.75 inch)
W.U = U

local cv = {
  quads = CreateClientConVar("ta_mesh_quads", "0", true, false, "Build meshes from quads instead of triangles (test)"),
  budget = CreateClientConVar("ta_build_budget_ms", "4", true, false, "Milliseconds per frame spent building the world"),
  ahead = CreateClientConVar("ta_ahead", "450", true, false, "Full detail this far ahead along the route (m)"),
  behind = CreateClientConVar("ta_behind", "60", true, false, "Full detail kept this far back along the route (m)"),
  radius = CreateClientConVar("ta_near_radius", "110", true, false, "Full detail this far to the sides of the route (m)"),
  lod4 = CreateClientConVar("ta_lod4_radius", "1200", true, false, "Medium detail radius (m)"),
  trees = CreateClientConVar("ta_tree_dist", "900", true, false, "Distant trees drawn up to this far (m)"),
  season = CreateClientConVar("ta_season", "summer", true, false, "summer, autumn or winter"),
  overlay = CreateClientConVar("ta_perf_overlay", "1", true, false, "Show the frame-rate overlay"),
  slice = CreateClientConVar("ta_mesh_slice", "4000", true, false, "Quads per mesh (max 10000); one mesh is built per step"),
}

-- ------------------------------------------------------------------ meshes ----
local V0 = Vector(0, 0, 0)
-- one IMesh from quads [q0, q0 + cnt) of a buffer
local function upload(b, matname, q0, cnt)
  local v = b.v
  local quads = cv.quads:GetBool()
  local m = Mesh()
  mesh.Begin(m, quads and MATERIAL_QUADS or MATERIAL_TRIANGLES, quads and cnt or cnt * 2)
  local ok, err = pcall(function()
    local Vx = V0
    local function put(o)
      Vx:SetUnpacked(v[o + 1] * U, v[o + 2] * U, v[o + 3] * U)
      mesh.Position(Vx)
      mesh.TexCoord(0, v[o + 4], v[o + 5])
      mesh.Color(v[o + 6], v[o + 7], v[o + 8], 255)
      mesh.AdvanceVertex()
    end
    for q = q0, q0 + cnt - 1 do
      local o = q * 32
      if quads then put(o); put(o + 8); put(o + 16); put(o + 24)
      else put(o); put(o + 8); put(o + 16); put(o); put(o + 16); put(o + 24) end
    end
  end)
  mesh.End()
  if not ok then ErrorNoHalt("[Tiny Atlas] mesh build failed: " .. tostring(err) .. "\n") end
  return m
end

local function free(list) for _, m in ipairs(list) do if IsValid(m) then m:Destroy() end end end

-- ------------------------------------------------------------------ materials ----
local matn = 0
local function make_mat(kind, png, extra, flags)
  matn = matn + 1
  local p = { ["$basetexture"] = "color/white", ["$vertexcolor"] = 1, ["$nocull"] = 1, ["$model"] = 0 }
  for k, x in pairs(extra or {}) do p[k] = x end
  local m = CreateMaterial("tinyatlas_" .. kind .. "_" .. matn, "UnlitGeneric", p)
  if png then
    local src = Material(png, flags or "noclamp")
    if src and not src:IsError() then m:SetTexture("$basetexture", src:GetTexture("$basetexture"))
    else print("[Tiny Atlas] texture missing: " .. png) end
  end
  return m
end

local function load_pack(id)
  local pack = include("tinyatlas/packs/" .. id .. ".lua")
  local ok, atlas = pcall(include, "tinyatlas/packs/" .. id .. "_gmod.lua")
  if not ok or not atlas then error("pack '" .. id .. "' has no GMod atlas: run tools/packs/gmod_prep.py on it") end
  return pack, atlas
end

-- ------------------------------------------------------------------ start / stop ----
local function json(s) return util.JSONToTable(s) end
local function read(path)
  local f = file.Open(path, "rb", "DATA")
  if not f then return nil end
  local s = f:Read(f:Size())
  f:Close()
  return s
end

function W.Start(route_id, mode, opts)
  W.Stop()
  opts = opts or {}
  local root = "tinyatlas/routes/" .. route_id
  if not file.Exists(root .. "/route.txt", "DATA") then
    print("[Tiny Atlas] no route at garrysmod/data/" .. root .. " (export one with tools/gmod_export.py)")
    return false
  end
  local t0 = SysTime()
  local D = Data.new(read, json, root)
  local rt = D:route()
  local route = RouteT.new(rt)
  local pack, atlas = load_pack(opts.pack or "default")
  local look = Look.build(pack, atlas, rt, cv.season:GetString())
  local mats = {
    ground = make_mat("ground", atlas.ground_png),
    flat = make_mat("flat", nil),
    objects = make_mat("objects", look.objects_png, { ["$alphatest"] = 1, ["$alphatestreference"] = 0.5 }),
    water = make_mat("water", "tinyatlas/packs/" .. (opts.pack or "default") .. "/" .. look.water_sheet_png,
      { ["$translucent"] = 1, ["$alpha"] = look.water_opacity, ["$basetexturetransform"] = "center 0 0 scale 1 1 rotate 0 translate 0 0" }),
  }
  mats.objects_far = mats.objects
  local E = {
    upload = upload,
    free = free,
    clock = SysTime,
  }
  local S = Stream.new(E, D, MeshB, route, look, {
    ahead = cv.ahead:GetFloat(), behind = cv.behind:GetFloat(), near_radius = cv.radius:GetFloat(),
    lod4_radius = cv.lod4:GetFloat(), tree_dist = cv.trees:GetFloat(),
    slice_quads = math.Clamp(cv.slice:GetInt(), 500, 10000),
  })
  W.D, W.route, W.look, W.mats, W.S, W.mode, W.opts = D, route, look, mats, S, mode, opts
  W.s = opts.start or 0
  W.speed = (opts.kmh or 30) / 3.6
  W.t = 0
  W.loading = true
  W.plan_t = 0          -- plan on the first frame (a second ride in the same session must not start "loaded")
  W.load_t0 = t0
  W.O = nil
  W.perf = { frames = {}, lua = {}, build = {}, draws = 0, quads = 0, log = {}, sec = 0, t0 = nil }
  W.on = true
  TinyAtlas.Route = route
  if mode == "ride" and TinyAtlas.Ride then TinyAtlas.Ride.s = W.s end
  print(string.format("[Tiny Atlas] %s: %s, %.1f km, %d chunks", mode, rt.name, route.length / 1000, #rt.chunks))
  return true
end

function W.Stop()
  if W.S then
    for _, u in pairs(W.S.units) do for _, h in ipairs(u.handles) do free(h.h) end end
  end
  W.S, W.on = nil, false
end

-- ------------------------------------------------------------------ the camera ----
local function rider_state()
  local R = W.route
  local s = W.s
  local x, y, z = R:pos(s)
  local fx, fy = R:dir(s, 8)
  return x, y, z, fx, fy
end

-- the camera sits on the route itself a few metres back (on a hairpin it stays on the path instead of
-- swinging out into whatever is beside it), and looks past the rider
local function camera(x, y, z, fx, fy, back)
  local R = W.route
  local d, h = 7, 2.8
  local cs = back and W.s + 5 or W.s - d
  local cx, cy, gz = R:pos(cs)
  local cz = math.max(z, gz) + h
  local lfx, lfy = fx, fy
  if back then lfx, lfy = -fx, -fy end
  local lx, ly, lz = x + lfx * 10, y + lfy * 10, z + 0.6
  local dx, dy, dz = lx - cx, ly - cy, lz - cz
  local hd = math.sqrt(dx * dx + dy * dy)
  local yaw = math.deg(math.atan2(dy, dx))
  local pitch = -math.deg(math.atan2(dz, hd))
  return cx, cy, cz, Angle(pitch, yaw, 0), dx / math.max(hd, 1e-6), dy / math.max(hd, 1e-6)
end

-- ------------------------------------------------------------------ per frame ----
local ORDER = { "flat", "ground", "objects", "objects_far", "water" }
local MT = Matrix()
local TV = Vector(0, 0, 0)
local rider_col = Color(200, 57, 47)
local GRAD = Material("gui/gradient_down")

local function frame(fov)
  local S = W.S
  local dt = RealFrameTime()
  local tl0 = SysTime()
  -- move
  if not W.loading then
    if W.mode == "perftest" then W.s = W.s + W.speed * dt
    elseif W.mode == "ride" and TinyAtlas.Ride then W.s = TinyAtlas.Ride.s end
    W.t = W.t + dt
  end
  local x, y, z, fx, fy = rider_state()
  local back = input.IsKeyDown(KEY_B)
  local cx, cy, cz, ang, vfx, vfy = camera(x, y, z, fx, fy, back)
  -- plan a few times a second, build within the budget
  W.plan_t = (W.plan_t or 0) - dt
  if W.plan_t <= 0 then
    S:plan(W.s, x, y, fx, fy)
    W.plan_t = 0.25
  end
  local budget = W.loading and 60 or cv.budget:GetFloat()
  S:work(budget)
  if W.loading and S:pending() == 0 then
    W.loading = false
    W.load_s = SysTime() - W.load_t0
    print(string.format("[Tiny Atlas] world ready in %.1f s", W.load_s))
  end
  -- floating origin: keep the camera near (0, 0, 0) in Source units
  local O = W.O
  if not O or math.abs(cx - O[1]) > 512 or math.abs(cy - O[2]) > 512 or math.abs(cz - O[3]) > 512 then
    O = { math.floor(cx / 256) * 256, math.floor(cy / 256) * 256, math.floor(cz / 256) * 256 }
    W.O = O
  end
  -- draw
  local L = W.look
  local hz, top = L.sky_horizon, L.sky_top
  render.Clear(hz[1], hz[2], hz[3], 255, true, true)
  cam.Start2D()
  surface.SetDrawColor(top[1], top[2], top[3], 255)
  surface.SetMaterial(GRAD)
  surface.DrawTexturedRect(0, 0, ScrW(), ScrH() * 0.55)
  cam.End2D()
  render.ClearDepth()
  cam.Start3D(Vector((cx - O[1]) * U, (cy - O[2]) * U, (cz - O[3]) * U), ang, fov, 0, 0, ScrW(), ScrH(), 4, 9000 * U)
  render.FogMode(MATERIAL_FOG_LINEAR)
  render.FogStart(L.fog_near * U)
  render.FogEnd(L.fog_far * U)
  render.FogMaxDensity(1)
  render.FogColor(L.haze[1], L.haze[2], L.haze[3])
  -- animate the water: slide the sheet by one frame
  local fr = math.floor(RealTime() * 1000 / L.water_ms) % L.water_frames
  local TM = Matrix()
  TM:SetTranslation(Vector(0, fr / L.water_frames, 0))
  W.mats.water:SetMatrix("$basetexturetransform", TM)
  local vis = S:visible(cx, cy, vfx, vfy, L.fog_far + 300)
  local tree_d = cv.trees:GetFloat()
  local draws, quads = 0, 0
  for _, mname in ipairs(ORDER) do
    render.SetMaterial(W.mats[mname])
    for _, u in ipairs(vis) do
      for _, h in ipairs(u.handles) do
        if h.mat == mname then
          local skip = false
          if mname == "objects_far" then
            local dx, dy = u.x - cx, u.y - cy
            skip = math.sqrt(dx * dx + dy * dy) - u.r > tree_d
          end
          if not skip then
            TV:SetUnpacked((u.ox - O[1]) * U, (u.oy - O[2]) * U, -O[3] * U)
            MT:SetTranslation(TV)
            cam.PushModelMatrix(MT)
            for _, m in ipairs(h.h) do m:Draw(); draws = draws + 1 end
            cam.PopModelMatrix()
            quads = quads + h.quads
          end
        end
      end
    end
  end
  -- the rider (a stand-in until the bike model is in)
  render.SetColorMaterial()
  render.DrawBox(Vector((x - O[1]) * U, (y - O[2]) * U, (z - O[3]) * U), Angle(0, math.deg(math.atan2(fy, fx)), 0),
    Vector(-0.9, -0.25, 0) * U, Vector(0.9, 0.25, 1.7) * U, rider_col)
  cam.End3D()
  render.FogMode(MATERIAL_FOG_NONE)
  local lua_ms = (SysTime() - tl0) * 1000
  return dt, lua_ms, draws, quads
end

-- ------------------------------------------------------------------ measuring ----
surface.CreateFont("TinyAtlas_Perf", { font = "Courier New", size = 16, weight = 700 })

local function percentile_low(frames, pct)
  local t = {}
  for i = 1, #frames do t[i] = frames[i] end
  table.sort(t, function(a, b) return a > b end)
  local n = math.max(1, math.floor(#t * pct))
  local sum = 0
  for i = 1, n do sum = sum + t[i] end
  return n > 0 and 1 / (sum / n) or 0
end

local function write_report()
  local P = W.perf
  local fr = P.frames
  if #fr < 10 then return end
  local sum, worst = 0, 0
  for _, f in ipairs(fr) do sum = sum + f; worst = math.max(worst, f) end
  local function avg(t) local s = 0; for _, x in ipairs(t) do s = s + x end; return #t > 0 and s / #t or 0 end
  local function maxof(t) local m = 0; for _, x in ipairs(t) do m = math.max(m, x) end; return m end
  local lines = {
    "Tiny Atlas performance test",
    "route: " .. W.route.meta.name .. "   speed: " .. string.format("%.0f km/h", W.speed * 3.6) ..
      "   ridden: " .. string.format("%.2f km in %.0f s", (W.s - (W.opts.start or 0)) / 1000, W.t),
    string.format("settings: ahead %d m, behind %d m, sides %d m, medium %d m, trees %d m, budget %.1f ms, %s",
      cv.ahead:GetInt(), cv.behind:GetInt(), cv.radius:GetInt(), cv.lod4:GetInt(), cv.trees:GetInt(), cv.budget:GetFloat(),
      cv.quads:GetBool() and "quads" or "triangles"),
    string.format("screen: %dx%d   loading: %.1f s", ScrW(), ScrH(), W.load_s or 0),
    "",
    string.format("average FPS     %.1f", #fr / sum),
    string.format("1%% low FPS      %.1f", percentile_low(fr, 0.01)),
    string.format("0.1%% low FPS    %.1f", percentile_low(fr, 0.001)),
    string.format("worst frame     %.1f ms", worst * 1000),
    string.format("world Lua/frame %.2f ms average, %.1f ms worst", avg(P.lua), maxof(P.lua)),
    string.format("building/frame  %.2f ms average, %.1f ms worst (single piece worst %.1f ms)", avg(P.build), maxof(P.build), W.S.stats.max_job_ms),
    string.format("draw calls      %.0f average   quads drawn %.0f average", P.draws / #fr, P.quads / #fr),
    string.format("Lua memory      %.0f MB", collectgarbage("count") / 1024),
    "",
    "per second:",
  }
  for _, l in ipairs(P.log) do lines[#lines + 1] = l end
  file.CreateDir("tinyatlas/perf")
  local name = string.format("tinyatlas/perf/%s_%dkmh.txt", W.route.meta.id, math.floor(W.speed * 3.6 + 0.5))
  file.Write(name, table.concat(lines, "\n") .. "\n")
  print("[Tiny Atlas] performance report: garrysmod/data/" .. name)
  for i = 6, 13 do print("  " .. lines[i]) end
end

local function overlay(dt, lua_ms, draws, quads)
  local S, P = W.S, W.perf
  if W.loading then
    draw.SimpleTextOutlined(string.format("Building the world... %d pieces left", S:pending()), "TinyAtlas_Perf",
      ScrW() / 2, ScrH() / 2, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, color_black)
    return
  end
  if not cv.overlay:GetBool() then return end
  local n = 0
  for _ in pairs(S.units) do n = n + 1 end
  local f = P.frames
  local recent = 0
  local k0 = math.max(1, #f - 59)
  for i = k0, #f do recent = recent + f[i] end
  local fps = (#f - k0 + 1) / math.max(recent, 1e-6)
  local lines = {
    string.format("FPS %5.1f   frame %5.1f ms", fps, dt * 1000),
    string.format("world Lua %5.2f ms   building %5.2f ms", lua_ms, S.stats.build_ms),
    string.format("draws %4d   quads %7d   pieces %4d   queued %3d", draws, quads, n, S:pending()),
    string.format("%.2f km  %s", W.s / 1000, W.mode == "perftest" and string.format("%.0f km/h", W.speed * 3.6) or ""),
  }
  for i, l in ipairs(lines) do
    draw.SimpleTextOutlined(l, "TinyAtlas_Perf", 12, 10 + (i - 1) * 18, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP, 1, color_black)
  end
end

hook.Add("RenderScene", "TinyAtlas_World", function(origin, angles, fov)
  if not W.on or not W.S then return end
  local ok, dt, lua_ms, draws, quads = pcall(frame, fov or 75)
  if not ok then
    ErrorNoHalt("[Tiny Atlas] world frame failed: " .. tostring(dt) .. "\n")
    W.Stop()
    return
  end
  local P = W.perf
  if not W.loading then
    P.frames[#P.frames + 1] = dt
    P.lua[#P.lua + 1] = lua_ms
    P.build[#P.build + 1] = W.S.stats.build_ms
    P.draws, P.quads = P.draws + draws, P.quads + quads
    P.sec = P.sec + dt
    P.secf = (P.secf or 0) + 1
    if P.sec >= 1 then
      P.log[#P.log + 1] = string.format("%6.0f s  %6.2f km  %5.1f fps  draws %4d  quads %7d  queued %3d", W.t, W.s / 1000,
        P.secf / P.sec, draws, quads, W.S:pending())
      P.sec, P.secf = 0, 0
    end
    if W.mode == "perftest" and (W.t >= (W.opts.seconds or 120) or (not W.route.loop and W.s >= W.route.length)) then
      write_report()
      W.Stop()
      return true
    end
  end
  cam.Start2D()
  overlay(dt, lua_ms, draws, quads)
  cam.End2D()
  return true
end)

-- ------------------------------------------------------------------ commands ----
concommand.Add("ta_perftest", function(_, _, args)
  local id = args[1] or "city-run-10-km"
  W.Start(id, "perftest", { kmh = tonumber(args[2]) or 30, seconds = tonumber(args[3]) or 120 })
end)
concommand.Add("ta_ride", function(_, _, args)
  W.Start(args[1] or "city-run-10-km", "ride", {})
end)
concommand.Add("ta_stop", function()
  if W.on and W.mode == "perftest" then write_report() end
  W.Stop()
end)
-- start riding the first exported route as soon as the map is loaded
local autostart = CreateClientConVar("ta_autostart", "1", true, false, "Start riding the first route when the map loads")
hook.Add("InitPostEntity", "TinyAtlas_AutoStart", function()
  timer.Simple(1, function()
    if not autostart:GetBool() or W.on then return end
    local _, dirs = file.Find("tinyatlas/routes/*", "DATA")
    if dirs and dirs[1] then
      W.Start(dirs[1], "ride", {})
      chat.AddText(Color(240, 200, 80), "[Tiny Atlas] ", color_white, "Riding " .. dirs[1] ..
        ". W to ride, B to look back. Console: ta_perftest " .. dirs[1] .. " to measure, ta_stop to stop.")
    else
      chat.AddText(Color(240, 200, 80), "[Tiny Atlas] ", color_white, "No routes in garrysmod/data/tinyatlas/routes yet.")
    end
  end)
end)

concommand.Add("ta_routes", function()
  local _, dirs = file.Find("tinyatlas/routes/*", "DATA")
  print("[Tiny Atlas] routes in garrysmod/data/tinyatlas/routes:")
  for _, d in ipairs(dirs or {}) do print("  " .. d) end
end)
