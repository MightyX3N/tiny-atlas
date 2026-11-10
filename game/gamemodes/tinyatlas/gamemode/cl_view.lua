-- The new world in Garry's Mod: builds the ground around the rider from live map data (atlas/world.lua), draws it,
-- and rides a GPX route on it (or roams freely).
--
--   ta_ride <route>        ride a route: one of the test routes (ta_ride with no name lists them) or a GPX file
--                          you put in garrysmod/data/tinyatlas/gpx/
--   ta_roam [lat] [lon]    ride freely from a place (default: central Copenhagen); A / D steer
--   ta_stop                back to the normal game view
-- The world is built while you ride; the route gets its heights as the cells along it are built. It says what it is
-- doing in the console by itself: loading, how riding goes every 30 s, falling behind, problems, FAILED lines.
local world = ATLAS_REQUIRE("world")
local route = ATLAS_REQUIRE("route")
local mesh_lib = ATLAS_REQUIRE("mesh")
local trees_lib = ATLAS_REQUIRE("trees")      -- trees and plants: drawn by their block's distance

TinyAtlas.View = TinyAtlas.View or {}
local V = TinyAtlas.View
local U = 52.4934                         -- Source units per metre
V.U = U
local VIEW = 700                          -- metres: built cells farther away are not drawn
local LOOK = { sky_top = { 96, 150, 206 }, sky_horizon = { 196, 216, 232 }, fog_near = 300, fog_far = 2000 }
local MAX_BOOST_MS = 40                   -- build time per frame while the loading screen is up
-- settings (console for now; the settings menu will use the same names)
local cv_style = CreateClientConVar("ta_style", "flat", true, false, "World look: flat (low-poly colours) or textured (the asset pack's ground textures)")
local cv_pack = CreateClientConVar("ta_pack", "default", true, false, "Asset pack for the textured look (default, city, ...)")
-- the pixel-art look is made over the whole picture (drawn small, stretched with sharp pixels), not in the textures
local cv_pixel = CreateClientConVar("ta_pixelate", "4", true, false, "Pixel size of the pixel-art look: 1 = off, 2-8 = screen pixels per pixel")
local cv_outline = CreateClientConVar("ta_outlines", "0.5", true, false, "Pixel-art outlines: how dark, where something stands in front of something farther away (0 = off, 1 = black)")
-- The look's settings as the player set them, then as the asset pack wants them: a pack's look table can fix a
-- setting (force) or move the player's own up or down (add), e.g.
--   look = { pixelate = { force = 1 }, outlines = { add = -0.2 } }     -- in packs/<id>.lua
V.LOOK_SETTINGS = {
  pixelate = { cv = cv_pixel, min = 1, max = 8, whole = true },
  outlines = { cv = cv_outline, min = 0, max = 1 },
}
function V.look_setting(name, pack)
  local S = V.LOOK_SETTINGS[name]
  local v = S.cv:GetFloat()
  local rule = pack and pack.look and pack.look[name]
  if type(rule) == "table" then
    if tonumber(rule.force) then v = tonumber(rule.force)
    elseif tonumber(rule.add) then v = v + tonumber(rule.add) end
  end
  v = math.Clamp(v, S.min, S.max)
  if S.whole then v = math.floor(v + 0.5) end
  return v, type(rule) == "table" and rule.force ~= nil
end
local cv_back = CreateClientConVar("ta_cam_back", "9", true, false, "Camera distance behind the rider (m)")
local cv_up = CreateClientConVar("ta_cam_up", "4", true, false, "Camera height above the rider (m)")

local function say(msg) print("[Tiny Atlas] " .. msg) end

-- ---- the asset pack's ground textures ----
local function load_pack(id)
  local ok, pack = pcall(include, "tinyatlas/packs/" .. id .. ".lua")
  if not ok or type(pack) ~= "table" then error("asset pack '" .. id .. "' not found (" .. tostring(pack) .. ")") end
  -- files that come with it: its 3D trees (<id>_trees3d.lua, tools/packs/trees3d.py) and its building textures
  -- (<id>_bld.lua, tools/packs/pixel_buildings.py); their textures join the pack's
  if not pack.extras_loaded then
    pack.extras_loaded = true
    for _, extra in ipairs({ "_trees3d", "_bld", "_ground" }) do
      local okt, t3 = pcall(include, "tinyatlas/packs/" .. id .. extra .. ".lua")
      if okt and type(t3) == "table" then
        if extra == "_trees3d" then pack.trees3d = t3 end
        pack.alphatest = pack.alphatest or {}
        for tex, def in pairs(t3.textures or {}) do
          if not pack.ground[tex] then pack.ground[tex] = { def.file } end
          if def.alphatest then pack.alphatest[tex] = true end
        end
      end
    end
  end
  return pack
end
local mats = {}
local function ground_material(pack, tex)
  local key = pack.id .. "/" .. tex
  if mats[key] then return mats[key] end
  if tex == "flat" then
    -- the flat look: colours come from the vertices only
    local m = CreateMaterial("tinyatlas_flat", "UnlitGeneric",
      { ["$basetexture"] = "color/white", ["$vertexcolor"] = 1, ["$nocull"] = 1, ["$model"] = 0 })
    mats[key] = m
    return m
  end
  local files = pack.ground[tex] or pack.ground.rural
  local params = { ["$basetexture"] = "color/white", ["$vertexcolor"] = 1, ["$nocull"] = 1, ["$model"] = 0 }
  if pack.alphatest and pack.alphatest[tex] then params["$alphatest"] = 1 end      -- windows and other cut-outs
  local m = CreateMaterial("tinyatlas_ground_" .. pack.id .. "_" .. tex, "UnlitGeneric", params)
  local png = "tinyatlas/packs/" .. pack.id .. "/" .. files[1]
  -- smooth, with mipmaps: the pixels come from the picture's pixel-art filter, so textures must not shimmer under it
  local src = Material(png, "noclamp smooth mips")
  if src and not src:IsError() then m:SetTexture("$basetexture", src:GetTexture("$basetexture"))
  else say("texture missing: materials/" .. png) end
  mats[key] = m
  return m
end

-- render targets for the pixel-art filter, one per size (GMod cannot resize or free them, so they are reused)
local targets = {}
function V.pixel_target(w, h)
  local key = w .. "x" .. h
  local t = targets[key]
  if t then return t end
  -- point sampling (1) + clamp s/t (4, 8) + no mipmaps (256): sharp pixels when stretched
  local rt = GetRenderTargetEx("tinyatlas_pixel_" .. key, w, h, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_SEPARATE,
    1 + 4 + 8 + 256, 0, IMAGE_FORMAT_RGB888)
  local mat = CreateMaterial("tinyatlas_pixel_" .. key, "UnlitGeneric",
    { ["$basetexture"] = rt:GetName(), ["$ignorez"] = 1, ["$vertexcolor"] = 0, ["$model"] = 0 })
  t = { rt = rt, mat = mat }
  -- the outlines: the distance at every pixel (a float target, the stock DepthWrite shader writes it), then
  -- shaders/fxc/tinyatlas_edges_ps20b.vcs (tools/shaders/) draws the picture with dark edges where the distance jumps
  if V.edges_ok == nil then V.edges_ok = file.Exists("shaders/fxc/tinyatlas_edges_ps20b.vcs", "GAME") end
  if V.edges_ok then
    t.drt = GetRenderTargetEx("tinyatlas_depth_" .. key, w, h, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_SEPARATE,
      1 + 4 + 8 + 256, 0, IMAGE_FORMAT_RGBA16161616F)
    t.edge = CreateMaterial("tinyatlas_edges_" .. key, "screenspace_general", {
      ["$pixshader"] = "tinyatlas_edges_ps20", ["$basetexture"] = rt:GetName(), ["$texture1"] = t.drt:GetName(),
      ["$linearread_basetexture"] = 1, ["$linearread_texture1"] = 1, ["$linearwrite"] = 1,
      ["$ignorez"] = 1, ["$vertextransform"] = 0, ["$copyalpha"] = 0, ["$alpha_blend"] = 0,
      ["$c0_x"] = 1 / w, ["$c0_y"] = 1 / h, ["$c0_z"] = V.EDGE_SILHOUETTE, ["$c0_w"] = 0.5 })
  end
  targets[key] = t
  return t
end
V.EDGE_SILHOUETTE = 0.12     -- how much farther (as a share) the pixel beside must be than the surface going on
V.EDGE_M = 250               -- metres: what is nearer has outlines (the depth pass draws only that)
-- the depth pass's material for a texture: the stock DepthWrite shader writing the distance as a colour, cut-outs
-- (leaves, windows) cut the same way as in the picture
local dmats = {}
local function depth_material(pack, tex)
  local key = pack.id .. "/" .. tex
  if dmats[key] then return dmats[key] end
  local src = ground_material(pack, tex)
  local params = { ["$color_depth"] = 1, ["$nocull"] = 1 }
  if pack.alphatest and pack.alphatest[tex] then params["$alphatest"] = 1; params["$alphatestreference"] = 0.5 end
  local m = CreateMaterial("tinyatlas_depth_" .. pack.id .. "_" .. tex, "DepthWrite", params)
  if params["$alphatest"] then m:SetTexture("$basetexture", src:GetTexture("$basetexture")) end
  dmats[key] = m
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
      -- trees and plants: which kind (0 3D trees, 1 their pictures, 2 plants) and their block's middle
      if G.lod then h.lod = h.lod or {}; h.lod[m] = { G.lod, G.bx or 0, G.by or 0, G.near } end
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
  local pack = load_pack(opts.pack or (cv_style:GetString() == "textured" and cv_pack:GetString()) or "default")
  V.pack = pack
  local W = world.new({
    fetch = TinyAtlasFetch, lat = opts.lat, lon = opts.lon, tile_metres = pack.tile_metres or 3.3, unit = U,
    tex_metres = pack.tex_metres, far_metres = pack.far_metres, buildings = pack.buildings and cv_style:GetString() == "textured",
    make = make_meshes, free = free_meshes, log = say, style = cv_style:GetString() == "textured" and "textured" or "flat",
    trees = pack.trees3d,
  })
  V.W, V.R, V.mode, V.on = W, opts.R, opts.mode, true
  V.s, V.phase, V.progress, V.t = 0, "loading", nil, 0
  V.perf = { n = 0, sum = 0, worst = 0, behind = false }
  V.plan_t, V.O, V.note_t = 0, nil, 0
  V.x, V.y, V.z, V.fx, V.fy = 0, 0, 0, 1, 0
  V.started = SysTime()
  V.frames = 0
  if opts.R then
    opts.R.world = W
    W:set_route(opts.R)             -- route heights come in as the cells along it are built
  end
  if TinyAtlasJobs then TinyAtlasJobs.boost_ms = MAX_BOOST_MS end
  V.job = TinyAtlasJobs.add(function(job)
    job.where = "the world"
    job.quiet = true
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
  say(string.format("riding %s (%.2f km): building the world around the start...", g.name or name, R.length / 1000))
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
  local d, h = math.Clamp(cv_back:GetFloat(), 2, 40), math.Clamp(cv_up:GetFloat(), 0.5, 30)
  local cx, cy, gz
  if V.mode == "ride" then
    local cs = back and V.s + 5 or V.s - d
    cx, cy, gz = V.R:pos(cs)
    if cs < 0 or cs > V.R.length then cx, cy = x - fx * (back and -5 or d), y - fy * (back and -5 or d) end   -- start / end
    -- in a sharp corner the route point behind is right beside the rider: step back along the heading instead
    local want = back and 5 or d
    local dx, dy = x - cx, y - cy
    if math.sqrt(dx * dx + dy * dy) < want * 0.75 then
      local k = back and -want or want
      cx, cy = x - fx * k, y - fy * k
      gz = V.W:height_at(cx, cy) or gz
    end
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
  if V.phase == "loading" then
    if now < V.note_t then return end
    V.note_t = now + 3
    local miss, total = W:missing_near(300)
    say(string.format("building the world around you: %d of %d cells ready", total - miss, total))
    return
  end
  -- while riding: how it is doing, every 30 s, and straight away when the world falls behind the rider
  local P = V.perf
  local ahead, all = 0, true
  if V.mode == "ride" then ahead, all = W:route_ready_ahead(V.s) end
  local behind = V.mode == "ride" and not all and ahead < 150
  if behind and not P.behind then
    say(string.format("FALLING BEHIND: the world is built only %.0f m ahead of you (%d cells waiting)", ahead, #W.queue))
  end
  P.behind = behind
  if now < V.note_t then return end
  V.note_t = now + 30
  if P.n == 0 then return end
  say(string.format("riding: %.0f fps, worst frame %.0f ms | %s | %d cells built (%.0f ms each), %d waiting, %d failed",
    P.n / P.sum, P.worst * 1000,
    V.mode == "ride" and (all and "world built to the finish" or string.format("world built %.0f m ahead", ahead)) or "free roam",
    W.stats.built, W.stats.built > 0 and W.stats.ms / W.stats.built or 0, #W.queue, W.stats.failed))
  P.n, P.sum, P.worst = 0, 0, 0
end

local function frame(fov)
  local W = V.W
  local dt = RealFrameTime()
  V.t = V.t + dt
  V.frames = V.frames + 1
  if V.phase == "riding" then
    local P = V.perf
    P.n, P.sum = P.n + 1, P.sum + dt
    if dt > P.worst then P.worst = dt end
  end
  local x, y, z, fx, fy = rider()
  V.x, V.y, V.z, V.fx, V.fy = x, y, z, fx, fy
  -- plan a few times a second
  V.plan_t = V.plan_t - dt
  if V.plan_t <= 0 then
    W.s = V.s
    W:focus(x, y, fx, fy)
    V.plan_t = 0.25
  end
  if V.phase == "loading" then
    local miss = W:missing_near(300)
    -- ready when the ground around the start is built (and, on a route, the start has its height)
    if miss == 0 and (V.mode ~= "ride" or V.R.known[1]) then
      V.phase = "riding"
      TinyAtlasJobs.boost_ms = nil
      say(string.format("world ready in %.1f s (%d cells built, %.0f ms each on average)", SysTime() - V.started,
        W.stats.built, W.stats.built > 0 and W.stats.ms / W.stats.built or 0))
      V.note_t = SysTime() + 30
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
  -- the pixel-art filter: draw the world into a small render target, then stretch it over the screen with sharp pixels
  local px = V.look_setting("pixelate", V.pack)
  local rw, rh = ScrW(), ScrH()
  local pix
  if px >= 2 then
    rw, rh = math.ceil(ScrW() / px), math.ceil(ScrH() / px)
    pix = V.pixel_target(rw, rh)
    render.PushRenderTarget(pix.rt, 0, 0, rw, rh)
  end
  render.Clear(hz[1], hz[2], hz[3], 255, true, true)
  cam.Start2D()
  surface.SetDrawColor(top[1], top[2], top[3], 255)
  surface.SetMaterial(GRAD)
  surface.DrawTexturedRect(0, 0, rw, rh * 0.55)
  cam.End2D()
  render.ClearDepth()
  cam.Start3D(Vector((cx - O[1]) * U, (cy - O[2]) * U, (cz - O[3]) * U), ang, fov, 0, 0, rw, rh, 4, (L.fog_far + 400) * U)
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
  for _, f in pairs(W.far) do
    if f.handle then
      TV:SetUnpacked((f.ox - O[1]) * U, (f.oy - O[2]) * U, -O[3] * U)
      MT:SetTranslation(TV)
      cam.PushModelMatrix(MT)
      for tex, L2 in pairs(f.handle.tex) do
        render.SetMaterial(ground_material(V.pack, tex))
        for _, m in ipairs(L2) do m:Draw(); draws = draws + 1 end
      end
      cam.PopModelMatrix()
    end
  end
  render.ClearDepth()
  -- a mesh's level of detail: drawn at this distance?
  local function shown(c, m)
    local l = c.handle.lod and c.handle.lod[m]
    if not l then return true end
    local dx, dy = c.ox + l[2] - cx, c.oy + l[3] - cy
    local dd = dx * dx + dy * dy
    if l[1] == 0 then return dd < trees_lib.LOD_M ^ 2
    elseif l[1] == 1 then return dd >= trees_lib.LOD_M ^ 2
    elseif l[1] == 3 then return dd < l[4] * l[4]          -- building detail, near only
    else return dd < trees_lib.PLANT_M ^ 2 end
  end
  for _, tex in ipairs(mesh_lib.TEXTURES) do
    local mat
    for _, c in ipairs(vis) do
      local L2 = c.handle.tex[tex]
      if L2 then
        if not mat then mat = ground_material(V.pack, tex); render.SetMaterial(mat) end
        TV:SetUnpacked((c.ox - O[1]) * U, (c.oy - O[2]) * U, -O[3] * U)
        MT:SetTranslation(TV)
        cam.PushModelMatrix(MT)
        for _, m in ipairs(L2) do
          if shown(c, m) then m:Draw(); draws = draws + 1 end
        end
        cam.PopModelMatrix()
      end
    end
  end
  for _, c in ipairs(vis) do tris = tris + c.handle.tris end
  -- the outlines' depth pass: the near cells again, each pixel's distance (nothing there: 0)
  local dark = V.look_setting("outlines", V.pack)
  local edges = pix and pix.drt and dark > 0
  if edges and pix.dark ~= dark then pix.edge:SetFloat("$c0_w", dark); pix.dark = dark end
  if edges then
    render.FogMode(MATERIAL_FOG_NONE)
    render.PushRenderTarget(pix.drt, 0, 0, rw, rh)
    render.Clear(0, 0, 0, 0, true, true)
    local near2 = (V.EDGE_M + cm) ^ 2
    for _, tex in ipairs(mesh_lib.TEXTURES) do
      local set = false
      for _, c in ipairs(vis) do
        local L2 = c.handle.tex[tex]
        local mx, my = c.ox + cm / 2 - cx, c.oy - cm / 2 - cy
        if L2 and mx * mx + my * my < near2 then
          if not set then render.SetMaterial(depth_material(V.pack, tex)); set = true end
          TV:SetUnpacked((c.ox - O[1]) * U, (c.oy - O[2]) * U, -O[3] * U)
          MT:SetTranslation(TV)
          cam.PushModelMatrix(MT)
          for _, m in ipairs(L2) do
            if shown(c, m) then m:Draw(); draws = draws + 1 end
          end
          cam.PopModelMatrix()
        end
      end
    end
    render.PopRenderTarget()
    render.FogMode(MATERIAL_FOG_LINEAR)
  end
  -- the rider (a stand-in until the bike model is in)
  do
    render.SetColorMaterial()
    render.DrawBox(Vector((x - O[1]) * U, (y - O[2]) * U, (z - O[3]) * U), Angle(0, math.deg(math.atan2(fy, fx)), 0),
      Vector(-0.9, -0.25, 0) * U, Vector(0.9, 0.25, 1.7) * U, rider_col)
  end
  cam.End3D()
  render.FogMode(MATERIAL_FOG_NONE)
  if pix then
    render.PopRenderTarget()
    render.SetMaterial(edges and pix.edge or pix.mat)
    render.DrawScreenQuad()
  end
  V.px = px
  V.draws, V.tris = draws, tris
end

surface.CreateFont("TinyAtlas_View", { font = "Arial", size = 22, weight = 700 })
surface.CreateFont("TinyAtlas_ViewSmall", { font = "Arial", size = 16, weight = 600 })

local function hud()
  local W = V.W
  local sw, sh = ScrW(), ScrH()
  if V.phase == "loading" then
    local miss, tot = W:missing_near(300)
    local done, total, label = tot - miss, math.max(tot, 1), "Building the world around you"
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

-- ---- settings: the look (ta_settings, or F1) ----
function V.OpenSettings()
  if IsValid(V.settings_frame) then V.settings_frame:Remove() end
  local f = vgui.Create("DFrame")
  V.settings_frame = f
  f:SetTitle("Tiny Atlas - settings")
  f:SetSize(380, 190)
  f:Center()
  f:MakePopup()
  local y = 34
  local function slider(name, label, decimals)
    local S = V.LOOK_SETTINGS[name]
    local s = vgui.Create("DNumSlider", f)
    s:SetPos(14, y); s:SetSize(352, 32)
    s:SetText(label)
    s:SetMin(S.min); s:SetMax(S.max); s:SetDecimals(decimals)
    s:SetConVar(S.cv:GetName())
    local _, forced = V.look_setting(name, V.pack)
    local note = vgui.Create("DLabel", f)
    note:SetPos(18, y + 30); note:SetSize(348, 16)
    note:SetText(forced and "(the asset pack sets this one)" or "")
    y = y + 54
    return s
  end
  slider("pixelate", "Pixel size (1 = off)", 0)
  slider("outlines", "Outlines (0 = off)", 2)
end
concommand.Add("ta_settings", function() V.OpenSettings() end)
hook.Add("PlayerBindPress", "TinyAtlas_Settings", function(_, bind, pressed)
  if pressed and bind == "gm_showhelp" then V.OpenSettings(); return true end
end)
