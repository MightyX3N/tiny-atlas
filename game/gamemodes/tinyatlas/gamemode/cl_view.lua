-- The new world in Garry's Mod: builds the ground around the rider from live map data (atlas/world.lua), draws it,
-- and rides a GPX route on it (or roams freely).
--
--   ta_ride <route>        ride a route: one of the test routes (ta_ride with no name lists them) or a GPX file
--                          you put in garrysmod/data/tinyatlas/gpx/
--   ta_roam [lat] [lon]    ride freely from a place (default: central Copenhagen); A / D steer
--   ta_stop                back to the normal game view
-- It says what it is doing in the console by itself: route preparation, loading, problems, FAILED lines.
local world = ATLAS_REQUIRE("world")
local route = ATLAS_REQUIRE("route")
local mesh_lib = ATLAS_REQUIRE("mesh")

TinyAtlas.View = TinyAtlas.View or {}
local V = TinyAtlas.View
local U = 52.4934                         -- Source units per metre
V.U = U
local VIEW = 700                          -- metres: built cells farther away are not drawn
local LOOK = { sky_top = { 96, 150, 206 }, sky_horizon = { 196, 216, 232 }, fog_near = 300, fog_far = 2000 }
local MAX_BOOST_MS = 40                   -- build time per frame while the loading screen is up

local function say(msg) print("[Tiny Atlas] " .. msg) end

-- ---- the asset pack's ground textures ----
local function load_pack(id)
  local ok, pack = pcall(include, "tinyatlas/packs/" .. id .. ".lua")
  if not ok or type(pack) ~= "table" then error("asset pack '" .. id .. "' not found (" .. tostring(pack) .. ")") end
  return pack
end
local mats = {}
local function ground_material(pack, tex)
  local key = pack.id .. "/" .. tex
  if mats[key] then return mats[key] end
  local files = pack.ground[tex] or pack.ground.rural
  local m = CreateMaterial("tinyatlas_ground_" .. pack.id .. "_" .. tex, "UnlitGeneric",
    { ["$basetexture"] = "color/white", ["$vertexcolor"] = 1, ["$nocull"] = 1, ["$model"] = 0 })
  local png = "tinyatlas/packs/" .. pack.id .. "/" .. files[1]
  local src = Material(png, "noclamp")
  if src and not src:IsError() then m:SetTexture("$basetexture", src:GetTexture("$basetexture"))
  else say("texture missing: materials/" .. png) end
  mats[key] = m
  return m
end

-- ---- meshes: mesh.lua groups -> IMeshes, one per group ----
local VEC = Vector(0, 0, 0)
local function make_meshes(groups)
  local h = { tex = {}, tris = 0 }
  for _, G in ipairs(groups) do
    if G.n >= 3 then
      local m = Mesh()
      local d = G.d
      mesh.Begin(m, MATERIAL_TRIANGLES, G.n / 3)
      local ok, err = pcall(function()
        for i = 0, G.n - 1 do
          local o = i * 8
          VEC:SetUnpacked(d[o + 1], d[o + 2], d[o + 3])
          mesh.Position(VEC)
          mesh.TexCoord(0, d[o + 4], d[o + 5])
          mesh.Color(d[o + 6], d[o + 7], d[o + 8], 255)
          mesh.AdvanceVertex()
        end
      end)
      mesh.End()
      if not ok then ErrorNoHalt("[Tiny Atlas] mesh build failed: " .. tostring(err) .. "\n") end
      local L = h.tex[G.tex]
      if not L then L = {}; h.tex[G.tex] = L end
      L[#L + 1] = m
      h.tris = h.tris + G.n / 3
    end
  end
  return h
end
local function free_meshes(h)
  for _, L in pairs(h.tex) do for _, m in ipairs(L) do if IsValid(m) then m:Destroy() end end end
  h.tex = {}
end

-- ---- reading routes ----
local function read_gpx(name)
  local text = file.Read("tinyatlas/gpx/" .. name .. ".gpx", "DATA") or file.Read("tinyatlas/gpx/" .. name, "DATA")
  if not text then text = file.Read("gamemodes/" .. (GM or GAMEMODE).FolderName .. "/routes/" .. name .. ".gpx", "GAME") end
  return text
end
local function list_routes()
  local out = {}
  for _, f in ipairs(file.Find("gamemodes/" .. (GM or GAMEMODE).FolderName .. "/routes/*.gpx", "GAME") or {}) do out[#out + 1] = f:gsub("%.gpx$", "") end
  for _, f in ipairs(file.Find("tinyatlas/gpx/*.gpx", "DATA") or {}) do out[#out + 1] = f:gsub("%.gpx$", "") .. " (your file)" end
  return out
end

-- ---- start / stop ----
function V.Stop()
  if V.W then V.W:shutdown() end
  V.W, V.on = nil, false
  if V.job then V.job.cancel = true end
  V.job = nil
  if TinyAtlasJobs then TinyAtlasJobs.boost_ms = nil end
end

local function start(opts)
  V.Stop()
  local pack = load_pack(opts.pack or "default")
  V.pack = pack
  local W = world.new({
    fetch = TinyAtlasFetch, lat = opts.lat, lon = opts.lon, tile_metres = pack.tile_metres or 3.3, unit = U,
    make = make_meshes, free = free_meshes, log = say,
  })
  V.W, V.R, V.mode, V.on = W, opts.R, opts.mode, true
  V.s, V.phase, V.progress, V.t = 0, opts.R and "route" or "loading", nil, 0
  V.plan_t, V.O, V.note_t = 0, nil, 0
  V.x, V.y, V.z, V.fx, V.fy = 0, 0, 0, 1, 0
  V.started = SysTime()
  V.frames = 0
  if opts.R then
    opts.R.world = W
    W.route = opts.R
  end
  if TinyAtlasJobs then TinyAtlasJobs.boost_ms = MAX_BOOST_MS end
  V.job = TinyAtlasJobs.add(function(job)
    job.where = "the world"
    job.quiet = true
    local R = V.R
    if R then
      job.where = "preparing the route"
      local sum = W:prepare_route(R, job.tick, function(i, n) V.progress = { i, n } end)
      if job.cancel then return end
      say(string.format("route ready: %.2f km, climbing %.0f m, steepest %.1f %% (at %.2f km), %.0f m steeper than 25 %%",
        sum.length / 1000, sum.climb, sum.worst_grade, sum.worst_at / 1000, sum.steep_m))
      if sum.gaps > 0 then
        say(string.format("  %d bridges / tunnels on the route (%.0f m): ridden straight across until bridges are built", sum.gaps, sum.gap_m))
      end
      if sum.failed > 0 then say(string.format("  FAILED: %d of %d route cells could not be built (no map data)", sum.failed, sum.cells)) end
      V.phase = "loading"
      V.plan_t = 0
    end
    job.where = "building the world"
    while not job.cancel and V.W == W do
      if not W:work(job.tick, SysTime) then coroutine.yield() end
    end
  end)
  return true
end

function V.StartRoute(name)
  local text = read_gpx(name)
  if not text then
    say("no route called '" .. tostring(name) .. "'. Routes: " .. table.concat(list_routes(), ", "))
    return false
  end
  local g, err = route.parse_gpx(text)
  if not g then say("FAILED: " .. name .. ": " .. err) return false end
  -- the world's origin is the route's first point; route.new needs the world, so make a throwaway one for it
  local lat, lon = g.points[1][1], g.points[1][2]
  local tmp = world.new({ fetch = TinyAtlasFetch, lat = lat, lon = lon, tile_metres = 3.3, unit = U,
    make = function() end, free = function() end })
  local R = route.new(g.points, tmp)
  say(string.format("riding %s (%.2f km): preparing the route...", g.name or name, R.length / 1000))
  TinyAtlas.Route = R
  if TinyAtlas.Ride then TinyAtlas.Ride.s = 0 end
  return start({ mode = "ride", R = R, lat = lat, lon = lon })
end

function V.StartRoam(lat, lon)
  say(string.format("free roam at %.4f, %.4f: loading...", lat, lon))
  local ok = start({ mode = "roam", lat = lat, lon = lon })
  V.heading = 0
  TinyAtlas.Route = { grade_at = function() return V.roam_grade or 0 end, tag_at = function() return V.roam_tag or "asphalt" end, wind_along = 0 }
  if TinyAtlas.Ride then TinyAtlas.Ride.s = 0 end
  V.last_s = 0
  return ok
end

-- ---- the rider and the camera ----
local function rider()
  if V.mode == "ride" then
    local R = V.R
    local s = math.max(0, math.min(R.length, TinyAtlas.Ride and TinyAtlas.Ride.s or 0))
    V.s = s
    local x, y, z = R:pos(s)
    local fx, fy = R:dir(s, 8)
    return x, y, z, fx, fy
  end
  -- roam: move by what the trainer rode since the last frame, steer with A / D
  local s = TinyAtlas.Ride and TinyAtlas.Ride.s or 0
  local ds = s - (V.last_s or s)
  V.last_s = s
  local dt = RealFrameTime()
  if input.IsKeyDown(KEY_A) then V.heading = V.heading + 60 * dt end
  if input.IsKeyDown(KEY_D) then V.heading = V.heading - 60 * dt end
  local fx, fy = math.cos(math.rad(V.heading)), math.sin(math.rad(V.heading))
  local x, y = V.x + fx * ds, V.y + fy * ds
  local z = V.W:height_at(x, y)
  if not z then x, y, z = V.x, V.y, V.z end           -- the ground there is not built yet: wait
  local z2 = V.W:height_at(x + fx * 5, y + fy * 5)
  V.roam_grade = z2 and (z2 - z) / 5 * 100 or 0
  local _, surf = V.W:height_at(x, y)
  V.roam_tag = V.W:tag_of(surf)
  return x, y, z, fx, fy
end

local function camera(x, y, z, fx, fy, back)
  local d, h = 7, 2.8
  local cx, cy, gz
  if V.mode == "ride" then
    local cs = back and V.s + 5 or V.s - d
    cx, cy, gz = V.R:pos(cs)
    if cs < 0 or cs > V.R.length then cx, cy = x - fx * (back and -5 or d), y - fy * (back and -5 or d) end   -- start / end
  else
    local k = back and -5 or d
    cx, cy = x - fx * k, y - fy * k
    gz = V.W:height_at(cx, cy) or z
  end
  local cz = math.max(z, gz) + h
  local lfx, lfy = fx, fy
  if back then lfx, lfy = -fx, -fy end
  local lx, ly, lz = x + lfx * 10, y + lfy * 10, z + 0.6
  local dx, dy, dz = lx - cx, ly - cy, lz - cz
  local hd = math.sqrt(dx * dx + dy * dy)
  return cx, cy, cz, Angle(-math.deg(math.atan2(dz, hd)), math.deg(math.atan2(dy, dx)), 0),
    dx / math.max(hd, 1e-6), dy / math.max(hd, 1e-6)
end

-- ---- per frame ----
local MT = Matrix()
local TV = Vector(0, 0, 0)
local GRAD = Material("gui/gradient_down")
local rider_col = Color(200, 57, 47)

local function status_note()
  local W = V.W
  local now = SysTime()
  if now < V.note_t then return end
  V.note_t = now + 3
  if V.phase == "route" and V.progress then
    say(string.format("preparing the route: %d of %d cells", V.progress[1], V.progress[2]))
  elseif V.phase == "loading" then
    local miss, total = W:missing_near(300)
    say(string.format("building the world around you: %d of %d cells ready", total - miss, total))
  end
end

local function frame(fov)
  local W = V.W
  local dt = RealFrameTime()
  V.t = V.t + dt
  V.frames = V.frames + 1
  local x, y, z, fx, fy = 0, 0, 0, 1, 0
  if V.phase ~= "route" then x, y, z, fx, fy = rider() end
  V.x, V.y, V.z, V.fx, V.fy = x, y, z, fx, fy
  -- plan a few times a second
  V.plan_t = V.plan_t - dt
  if V.plan_t <= 0 and V.phase ~= "route" then
    W.s = V.s
    W:focus(x, y, fx, fy)
    V.plan_t = 0.25
  end
  if V.phase == "loading" then
    local miss = W:missing_near(300)
    if miss == 0 then
      V.phase = "riding"
      TinyAtlasJobs.boost_ms = nil
      say(string.format("world ready in %.1f s (%d cells built, %.0f ms each on average)", SysTime() - V.started,
        W.stats.built, W.stats.built > 0 and W.stats.ms / W.stats.built or 0))
      if V.mode == "roam" and not W:height_at(V.x, V.y) then say("FAILED: no ground under the start point") end
      if V.mode == "roam" then V.z = W:height_at(V.x, V.y) or 0; z = V.z end
    end
  end
  status_note()
  local back = input.IsKeyDown(KEY_B)
  local cx, cy, cz, ang, vfx, vfy = camera(x, y, z, fx, fy, back)
  -- floating origin: keep the camera near (0, 0, 0) in Source units
  local O = V.O
  if not O or math.abs(cx - O[1]) > 256 or math.abs(cy - O[2]) > 256 or math.abs(cz - O[3]) > 256 then
    O = { math.floor(cx / 128) * 128, math.floor(cy / 128) * 128, math.floor(cz / 128) * 128 }
    V.O = O
  end
  local L = LOOK
  local hz, top = L.sky_horizon, L.sky_top
  render.Clear(hz[1], hz[2], hz[3], 255, true, true)
  cam.Start2D()
  surface.SetDrawColor(top[1], top[2], top[3], 255)
  surface.SetMaterial(GRAD)
  surface.DrawTexturedRect(0, 0, ScrW(), ScrH() * 0.55)
  cam.End2D()
  render.ClearDepth()
  cam.Start3D(Vector((cx - O[1]) * U, (cy - O[2]) * U, (cz - O[3]) * U), ang, fov, 0, 0, ScrW(), ScrH(), 4, (L.fog_far + 400) * U)
  render.FogMode(MATERIAL_FOG_LINEAR)
  render.FogStart(L.fog_near * U)
  render.FogEnd(L.fog_far * U)
  render.FogMaxDensity(1)
  render.FogColor(hz[1], hz[2], hz[3])
  -- cells in view: near enough, and not behind the camera
  local vis = {}
  local cm = 8192 * W.k
  for _, c in pairs(W.cells) do
    if c.handle then
      local mx, my = c.ox + cm / 2 - cx, c.oy - cm / 2 - cy
      local d = math.sqrt(mx * mx + my * my)
      if d < VIEW + cm and (mx * vfx + my * vfy) > -cm then vis[#vis + 1] = c end
    end
  end
  local draws, tris = 0, 0
  -- the distant ground first (elevation only); the built cells are then drawn over it
  local fm
  for _, f in pairs(W.far) do
    if f.handle then
      if not fm then fm = ground_material(V.pack, mesh_lib.FAR_TEXTURE); render.SetMaterial(fm) end
      TV:SetUnpacked((f.ox - O[1]) * U, (f.oy - O[2]) * U, -O[3] * U)
      MT:SetTranslation(TV)
      cam.PushModelMatrix(MT)
      for _, L2 in pairs(f.handle.tex) do for _, m in ipairs(L2) do m:Draw(); draws = draws + 1 end end
      cam.PopModelMatrix()
    end
  end
  render.ClearDepth()
  for _, tex in ipairs(mesh_lib.TEXTURES) do
    local mat
    for _, c in ipairs(vis) do
      local L2 = c.handle.tex[tex]
      if L2 then
        if not mat then mat = ground_material(V.pack, tex); render.SetMaterial(mat) end
        TV:SetUnpacked((c.ox - O[1]) * U, (c.oy - O[2]) * U, -O[3] * U)
        MT:SetTranslation(TV)
        cam.PushModelMatrix(MT)
        for _, m in ipairs(L2) do m:Draw(); draws = draws + 1 end
        cam.PopModelMatrix()
      end
    end
  end
  for _, c in ipairs(vis) do tris = tris + c.handle.tris end
  -- the rider (a stand-in until the bike model is in)
  if V.phase ~= "route" then
    render.SetColorMaterial()
    render.DrawBox(Vector((x - O[1]) * U, (y - O[2]) * U, (z - O[3]) * U), Angle(0, math.deg(math.atan2(fy, fx)), 0),
      Vector(-0.9, -0.25, 0) * U, Vector(0.9, 0.25, 1.7) * U, rider_col)
  end
  cam.End3D()
  render.FogMode(MATERIAL_FOG_NONE)
  V.draws, V.tris = draws, tris
end

surface.CreateFont("TinyAtlas_View", { font = "Arial", size = 22, weight = 700 })
surface.CreateFont("TinyAtlas_ViewSmall", { font = "Arial", size = 16, weight = 600 })

local function hud()
  local W = V.W
  local sw, sh = ScrW(), ScrH()
  if V.phase == "route" or V.phase == "loading" then
    local done, total, label
    if V.phase == "route" then
      done, total = V.progress and V.progress[1] or 0, V.progress and V.progress[2] or 1
      label = "Preparing the route"
    else
      local miss, tot = W:missing_near(300)
      done, total, label = tot - miss, math.max(tot, 1), "Building the world around you"
    end
    local bw, bh = math.min(560, sw - 80), 14
    local bx, by = (sw - bw) / 2, sh / 2 + 18
    surface.SetDrawColor(0, 0, 0, 150)
    surface.DrawRect(bx - 2, by - 2, bw + 4, bh + 4)
    surface.SetDrawColor(255, 255, 255, 230)
    surface.DrawRect(bx, by, bw * math.min(1, done / total), bh)
    draw.SimpleTextOutlined(string.format("%s... %d of %d", label, done, total), "TinyAtlas_View", sw / 2, sh / 2 - 8,
      color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, color_black)
    return
  end
  local Rd = TinyAtlas.Ride or {}
  local lines = {
    string.format("%.1f km/h", (Rd.speed or 0) * 3.6),
    V.mode == "ride" and string.format("%.2f / %.2f km   grade %.1f %%", V.s / 1000, V.R.length / 1000, V.R:grade(V.s))
      or string.format("free roam   grade %.1f %%", V.roam_grade or 0),
  }
  for i, l in ipairs(lines) do
    draw.SimpleTextOutlined(l, i == 1 and "TinyAtlas_View" or "TinyAtlas_ViewSmall", 16, 12 + (i - 1) * 26,
      color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP, 1, color_black)
  end
end

hook.Add("RenderScene", "TinyAtlas_View", function(origin, angles, fov)
  if not V.on or not V.W then return end
  local ok, err = pcall(frame, fov or 75)
  if not ok then
    say("FAILED: drawing the world: " .. tostring(err))
    ErrorNoHalt("[Tiny Atlas] world frame failed: " .. tostring(err) .. "\n")
    V.Stop()
    return
  end
  cam.Start2D()
  hud()
  cam.End2D()
  return true
end)

-- ---- commands ----
concommand.Add("ta_ride", function(_, _, args)
  if not args[1] then say("routes: " .. table.concat(list_routes(), ", ")) return end
  V.StartRoute(args[1])
end)
concommand.Add("ta_roam", function(_, _, args)
  V.StartRoam(tonumber(args[1]) or 55.6761, tonumber(args[2]) or 12.5683)
end)
concommand.Add("ta_stop", function() V.Stop(); say("stopped") end)
