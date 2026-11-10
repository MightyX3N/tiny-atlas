-- The rider on the bike (or running), drawn in the world: the asset pack's rider (packs/<id>_rider.lua, made by
-- tools/packs/rider3d.py) - parts that move with their bone, posed from the pack's pedalling poses (the frame for
-- the crank's angle, turning at the rider's cadence) or its run cycle, the wheels and cranks turning, the bike
-- tilted with the road. The kit (core/kit.lua) is painted into a small texture per kit, made the first time it is
-- drawn.
--   TinyAtlas.Rider.draw(r)        r = { x, y, z (metres, the world's), fx, fy, O, U, kit, running, mat = fn or nil }
--   TinyAtlas.Rider.update(dt, r)  advances its crank, wheels, run cycle from r.speed (m/s) and r.cadence (rpm)
TinyAtlas.Rider = TinyAtlas.Rider or {}
local RD = TinyAtlas.Rider
local Kit = include("core/kit.lua")
RD.Kit = Kit
local cos, sin, floor, atan = math.cos, math.sin, math.floor, math.atan

-- ---- the kit's texture ----
local kits = {}                 -- key -> { rt, mat, painted }
RD.MAX_KITS = 32                -- GMod cannot free render targets: a pool, reused
local slots = 0
local function kit_key(K)
  local p = {}
  for _, k in ipairs({ "jersey", "accent", "accent2", "shorts", "socks", "shoes", "trim", "skin", "hair" }) do
    local c = K[k]; p[#p + 1] = c and (c[1] .. "," .. c[2] .. "," .. c[3]) or "-"
  end
  return table.concat(p, ";") .. ";" .. tostring(K.pattern) .. ";" .. tostring(K.sleeves) .. ";" .. tostring(K.shorts_stripe)
end
function RD.kit_material(K)
  local key = kit_key(K)
  local e = kits[key]
  if e then return e.mat end
  slots = slots % RD.MAX_KITS + 1
  -- a slot that held another kit is painted again
  for k, v in pairs(kits) do if v.slot == slots then kits[k] = nil end end
  local rt = GetRenderTargetEx("tinyatlas_kit_" .. slots, Kit.SIZE, Kit.SIZE, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE or 2,
    1 + 256, 0, IMAGE_FORMAT_RGBA8888)
  local mat = CreateMaterial("tinyatlas_kitmat_" .. slots, "UnlitGeneric",
    { ["$basetexture"] = rt:GetName(), ["$vertexcolor"] = 1, ["$model"] = 0, ["$nocull"] = 1 })
  mat:SetTexture("$basetexture", rt)
  e = { rt = rt, mat = mat, kit = K, slot = slots, painted = false }
  kits[key] = e
  return mat
end
-- paint the kits not painted yet (inside a render hook, before the world is drawn)
function RD.paint_kits()
  for _, e in pairs(kits) do
    if not e.painted then
      e.painted = true
      render.PushRenderTarget(e.rt, 0, 0, Kit.SIZE, Kit.SIZE)
      render.Clear(255, 0, 255, 255, true, true)
      cam.Start2D()
      Kit.paint(e.kit, function(x, y, w, h, r, g, b)
        surface.SetDrawColor(r, g, b, 255)
        surface.DrawRect(x, y, w, h)
      end)
      cam.End2D()
      render.PopRenderTarget()
    end
  end
end

-- ---- meshes: made once per pack ----
local function build(pack)
  local D = pack.rider
  if not D then return nil end
  local M = { D = D, bike = {}, parts = {} }
  local VEC = Vector(0, 0, 0)
  for name, part in pairs(D.bike.parts) do
    local m = Mesh()
    local v, idx = part.v, part.i
    mesh.Begin(m, MATERIAL_TRIANGLES, #idx / 3)
    for _, k in ipairs(idx) do
      local o = k * 6
      VEC:SetUnpacked(v[o + 1], v[o + 2], v[o + 3])
      mesh.Position(VEC)
      mesh.TexCoord(0, v[o + 4], v[o + 5])
      local c = math.min(255, floor(v[o + 6] * 236))
      mesh.Color(c, c, c, 255)
      mesh.AdvanceVertex()
    end
    mesh.End()
    M.bike[name] = { mesh = m, pivot = part.pivot }
  end
  for bone, part in pairs(D.rider.parts) do
    local m = Mesh()
    local v, idx = part.v, part.i
    mesh.Begin(m, MATERIAL_TRIANGLES, #idx / 3)
    for _, k in ipairs(idx) do
      local o = k * 7
      VEC:SetUnpacked(v[o + 1], v[o + 2], v[o + 3])
      mesh.Position(VEC)
      local u, vv = Kit.uv(D.areas[v[o + 5] + 1], v[o + 6], v[o + 7])
      mesh.TexCoord(0, u, vv)
      local c = math.min(255, floor(v[o + 4] * 240))
      mesh.Color(c, c, c, 255)
      mesh.AdvanceVertex()
    end
    mesh.End()
    M.parts[bone] = m
  end
  return M
end
function RD.models(pack)
  if not pack then return nil end
  if RD.pack ~= pack then
    if RD.M then
      for _, b in pairs(RD.M.bike) do if IsValid(b.mesh) then b.mesh:Destroy() end end
      for _, m in pairs(RD.M.parts) do if IsValid(m) then m:Destroy() end end
    end
    RD.pack, RD.M = pack, build(pack)
  end
  return RD.M
end

-- ---- moving: crank, wheels, run cycle ----
-- each rider has its own: RD itself is yours, other riders pass their own table (RD.new_anim())
RD.crank, RD.wheel, RD.run_t = 0, 0, 0
function RD.new_anim() return { crank = math.random() * 6.28, wheel = 0, run_t = math.random() } end
function RD.update(dt, r, a)
  a = a or RD
  local D = RD.M and RD.M.D
  if not D then return end
  local v = r.speed or 0
  a.wheel = (a.wheel - v / D.bike.wheel_r * dt) % (2 * math.pi)
  a.crank = (a.crank - (r.cadence or 0) / 60 * 2 * math.pi * dt) % (2 * math.pi)
  a.run_t = (a.run_t + v * dt / D.rider.run_cycle_m) % 1
end

-- ---- matrices (3 x 4, rows) ----
local function mul(a, b)            -- a * b, both 3 x 4 affine
  return {
    a[1] * b[1] + a[2] * b[5] + a[3] * b[9], a[1] * b[2] + a[2] * b[6] + a[3] * b[10], a[1] * b[3] + a[2] * b[7] + a[3] * b[11], a[1] * b[4] + a[2] * b[8] + a[3] * b[12] + a[4],
    a[5] * b[1] + a[6] * b[5] + a[7] * b[9], a[5] * b[2] + a[6] * b[6] + a[7] * b[10], a[5] * b[3] + a[6] * b[7] + a[7] * b[11], a[5] * b[4] + a[6] * b[8] + a[7] * b[12] + a[8],
    a[9] * b[1] + a[10] * b[5] + a[11] * b[9], a[9] * b[2] + a[10] * b[6] + a[11] * b[10], a[9] * b[3] + a[10] * b[7] + a[11] * b[11], a[9] * b[4] + a[10] * b[8] + a[11] * b[12] + a[12],
  }
end
-- turning about the y axis (an axle): positive turns the front (x) up (z)
local function rot_y(a, px, py, pz)
  local c, s = cos(a), sin(a)
  return { c, 0, -s, px or 0, 0, 1, 0, py or 0, s, 0, c, pz or 0 }
end
local MT = Matrix and Matrix() or nil
local function push(m)
  local M = Matrix({ { m[1], m[2], m[3], m[4] }, { m[5], m[6], m[7], m[8] }, { m[9], m[10], m[11], m[12] }, { 0, 0, 0, 1 } })
  cam.PushModelMatrix(M)
end

-- the rider in the world. r.mat(kind) -> the material for "bike" / "kit" (the depth pass gives its own)
function RD.draw(r)
  local M = RD.models(r.pack)
  if not M then return 0 end
  local D = M.D
  local A = r.anim or RD
  local U, O = r.U, r.O
  -- the world's matrix: where, turned to the heading, tilted with the road, metres -> Source units
  local yaw = math.atan2(r.fy, r.fx)
  local pitch = atan((r.grade or 0) / 100)
  local cy, sy = cos(yaw), sin(yaw)
  local cp, sp = cos(pitch), sin(pitch)
  -- Rz(yaw) * Ry(pitch) (front up for a climb) * U
  local W = {
    cy * cp * U, -sy * U, -cy * sp * U, (r.x - O[1]) * U,
    sy * cp * U, cy * U, -sy * sp * U, (r.y - O[2]) * U,
    sp * U, 0, cp * U, (r.z - O[3]) * U,
  }
  local draws = 0
  if not r.running then
    render.SetMaterial(r.mat("bike"))
    for name, b in pairs(M.bike) do
      local p = b.pivot
      local a = 0
      if name == "rear" or name == "front" then a = A.wheel
      elseif name == "cranks" then
        local N = #D.rider.ride
        local f = floor(((-A.crank) / (2 * math.pi)) % 1 * N)
        a = -2 * math.pi * f / N - D.bike.crank0
      end
      push(mul(W, rot_y(a, p[1], p[2], p[3])))
      b.mesh:Draw()
      cam.PopModelMatrix()
      draws = draws + 1
    end
  end
  -- the pose: the pedalling frame for the crank's angle, or the run cycle's
  local P
  if r.running then
    local N = #D.rider.run
    P = D.rider.run[floor(A.run_t * N) % N + 1]
  else
    local N = #D.rider.ride
    P = D.rider.ride[floor(((-A.crank) / (2 * math.pi)) % 1 * N) % N + 1]
  end
  render.SetMaterial(r.mat("kit"))
  for bone, m in pairs(M.parts) do
    local pm = P[bone]
    if pm then
      push(mul(W, pm))
      m:Draw()
      cam.PopModelMatrix()
      draws = draws + 1
    end
  end
  return draws
end

-- ---- the player's own kit and looks (saved settings) ----
local cv_seed = CreateClientConVar("ta_kit_seed", "0", true, false, "Your kit: the seed it is made from (0 = roll one)")
local cv_locks = CreateClientConVar("ta_kit_locks", "", true, false, "Parts of your kit you fixed (pattern=..., jersey=r g b, ...)")
local cv_skin = CreateClientConVar("ta_skin", "2", true, false, "Your rider's skin tone (1-6)")
local cv_hair = CreateClientConVar("ta_hair", "2", true, false, "Your rider's hair colour (1-7)")
RD.cv = { seed = cv_seed, locks = cv_locks, skin = cv_skin, hair = cv_hair }
-- locks as text: "pattern=hoops;jersey=200 40 44;sleeves=accent"
function RD.parse_locks(s)
  local L = {}
  for k, v in tostring(s or ""):gmatch("([%w_]+)=([^;]*)") do
    local r, g, b = v:match("^(%d+) (%d+) (%d+)$")
    if r then L[k] = { tonumber(r), tonumber(g), tonumber(b) }
    elseif v == "true" or v == "false" then L[k] = v == "true"
    else L[k] = v end
  end
  return L
end
function RD.write_locks(L)
  local out = {}
  for k, v in pairs(L) do
    if type(v) == "table" then out[#out + 1] = k .. "=" .. v[1] .. " " .. v[2] .. " " .. v[3]
    else out[#out + 1] = k .. "=" .. tostring(v) end
  end
  table.sort(out)
  return table.concat(out, ";")
end
-- a kit as a short text (what other riders get): "seed|locks|skin|hair"
function RD.kit_string()
  return cv_seed:GetString() .. "|" .. cv_locks:GetString() .. "|" .. cv_skin:GetString() .. "|" .. cv_hair:GetString()
end
local other_kits = {}
function RD.kit_from_string(str)
  str = tostring(str or "")
  local K = other_kits[str]
  if K then return K end
  local seed, locks, skin, hair = str:match("^(%d*)|([^|]*)|(%d*)|(%d*)$")
  seed = tonumber(seed) or tonumber(str:match("^(%d+)")) or 1
  local L = RD.parse_locks(locks or "")
  L.skin = Kit.SKINS[math.Clamp(tonumber(skin) or 2, 1, #Kit.SKINS)]
  L.hair = Kit.HAIRS[math.Clamp(tonumber(hair) or 2, 1, #Kit.HAIRS)]
  K = Kit.generate(seed, L)
  other_kits[str] = K
  return K
end

local cache_key, cache_kit
function RD.local_kit()
  local seed = cv_seed:GetInt()
  if seed == 0 then
    seed = math.random(1, 2000000000)
    cv_seed:SetString(tostring(seed))
    RunConsoleCommand("ta_kit_seed", tostring(seed))
  end
  local key = seed .. "|" .. cv_locks:GetString() .. "|" .. cv_skin:GetString() .. "|" .. cv_hair:GetString()
  if key ~= cache_key then
    local L = RD.parse_locks(cv_locks:GetString())
    L.skin = Kit.SKINS[math.Clamp(cv_skin:GetInt(), 1, #Kit.SKINS)]
    L.hair = Kit.HAIRS[math.Clamp(cv_hair:GetInt(), 1, #Kit.HAIRS)]
    cache_key, cache_kit = key, Kit.generate(seed, L)
  end
  return cache_kit
end
