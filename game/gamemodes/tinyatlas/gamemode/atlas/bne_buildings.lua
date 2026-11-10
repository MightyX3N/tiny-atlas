-- ported from BeamNG.Earth server/buildings.py (MIT, (c) BeamNG.Earth contributors)
--
-- Buildings from footprints: walls with windows on every floor, flat roofs with a cornice, gabled and hipped roofs
-- with eaves, by region and building type. Heights, floors, roof and facade are predicted from the footprint (area,
-- narrowness, class, neighbours) when the map does not say, the same for a building every time (hashed from where it
-- is). Changes from BeamNG.Earth: its window sheets are BeamNG's own textures, so every building here uses its
-- plain-wall mode (a wall material, the windows laid over it as geometry: dark glass, a light frame); materials are
-- the ambientCG ones in the world pack; no landmarks, ships, bridge parts, parking decks or LOD.
--
--   B.plan(ring, attrs, neighbours, lat, lon, dense, town) -> spec
--   B.build(spec, ground, out)     out = collector (B.collector()); ground(x, y) -> metres (the drawn ground)
--   ring: { {x, y}, ... } metres, counter-clockwise (x east, y north)
local floor, max, min, abs, sqrt, atan2, cos, sin, tan, rad, deg = math.floor, math.max, math.min, math.abs,
  math.sqrt, math.atan2, math.cos, math.sin, math.tan, math.rad, math.deg

local B = {}

B.FLOOR_M = 3.0
B.GROUND_FLOOR_SHOP_M = 4.2
B.SKIRT_M = 1.5               -- walls reach this far under the footprint's lowest ground (hidden under it)
B.MIN_AREA_M2 = 12.0
B.PITCH = { gabled = 32.0, hipped = 26.0 }
B.EAVE_M = 0.35
B.CORNICE_OUT_M, B.CORNICE_DOWN_M, B.CORNICE_UP_M = 0.28, 0.45, 0.2
B.WIN_W, B.WIN_H, B.WIN_SILL = 1.05, 1.75, 0.85
B.WIN_OUT_M = 0.03
B.FRAME_M = 0.08              -- the window frame's width
B.ROOF_CLUTTER_M2 = 250.0
B.GLASS_FLOORS = { 20, 40 }
B.OLD_TOWER_GLASS = 0.65
B.MIDRISE_GLASS_OFFICE = 0.45
B.TOWER_SHOP_FLOORS = 6
B.BIG_BOX_M2 = 1200.0
B.STONE_FLOORS = 4
B.JITTER = 0.06

local SHOP_CLASSES = { retail = true, commercial = true, supermarket = true, kiosk = true, office = true, hotel = true,
  civic = true, restaurant = true }
local HOUSE_CLASSES = { house = true, detached = true, semidetached_house = true, bungalow = true, residential = true,
  farm = true, static_caravan = true, cabin = true, dormitory = true }
local ROW_CLASSES = { terrace = true }
local SHED_CLASSES = { shed = true, garage = true, garages = true, carport = true, roof = true, hut = true, cabin = true,
  barn = true, farm_auxiliary = true, greenhouse = true, service = true, storage_tank = true, toilets = true,
  kiosk = true, parking = true, shelter = true }
local BARN_CLASSES = { barn = true, farm_auxiliary = true, stable = true, cowshed = true }
local CHURCH_CLASSES = { church = true, chapel = true, cathedral = true }
local INDUSTRIAL_CLASSES = { industrial = true, warehouse = true, factory = true, manufacture = true, hangar = true }

-- ---- materials: the world pack's textures (ambientCG, CC0), tinted per building ----
-- (window bays per wall material, as BeamNG.Earth's sheets: m between windows)
B.MAT = {
  plaster = { tex = "bld_plaster", m = 2.5 }, stucco = { tex = "bld_plaster", m = 2.5 },
  brick = { tex = "bld_brick", m = 1.4 }, concrete = { tex = "bld_concrete", m = 2.4 },
  panel = { tex = "bld_concrete", m = 2.4 }, siding = { tex = "bld_wood", m = 3.0 },
  metalwall = { tex = "bld_metal", m = 2.0 }, stone = { tex = "bld_stone", m = 2.0 },
  office = { tex = "bld_glass", m = 6.0 },
  roof_tiles = { tex = "bld_roof_tiles", m = 2.4 }, roof_slate = { tex = "bld_roof_slate", m = 2.4 },
  roof_metal = { tex = "bld_metal", m = 2.0 }, roof_flat = { tex = "bld_roof_flat", m = 4.0 },
  plain = { tex = "bld_plain", m = 1.0 },
}
B.TEXTURES = { "bld_plaster", "bld_brick", "bld_concrete", "bld_wood", "bld_metal", "bld_stone", "bld_glass",
  "bld_roof_tiles", "bld_roof_slate", "bld_roof_flat", "bld_plain" }

-- facade colours (BeamNG.Earth's tints)
local FACADE_TINTS = { { 1.0, 1.0, 1.0 }, { 1.0, 0.93, 0.80 }, { 0.92, 0.82, 0.68 }, { 0.80, 0.82, 0.84 } }
local PAINT_TINTS = { { 0.80, 0.87, 0.96 }, { 0.84, 0.92, 0.82 }, { 0.99, 0.86, 0.82 }, { 1.0, 0.95, 0.72 } }
local BRICK_TINTS = { { 1.0, 1.0, 1.0 }, { 0.78, 0.72, 0.70 }, { 1.0, 0.88, 0.80 } }
local WALL_TINTS = {
  siding = { { 0.96, 0.95, 0.92 }, { 0.90, 0.86, 0.76 }, { 0.78, 0.84, 0.90 }, { 0.95, 0.92, 0.74 }, { 0.78, 0.84, 0.74 },
    { 0.82, 0.78, 0.72 }, { 0.70, 0.72, 0.75 }, { 0.62, 0.20, 0.17 }, { 0.66, 0.24, 0.20 } },
  stucco = { { 1.0, 0.97, 0.90 }, { 0.96, 0.88, 0.74 }, { 0.93, 0.80, 0.68 }, { 0.98, 0.95, 0.88 }, { 0.88, 0.84, 0.78 },
    { 1.0, 0.78, 0.45 }, { 0.92, 0.58, 0.44 }, { 0.66, 0.82, 0.95 }, { 0.70, 0.90, 0.78 }, { 0.98, 0.72, 0.76 },
    { 1.0, 0.92, 0.52 } },
  panel = { { 0.96, 0.94, 0.89 }, { 0.86, 0.86, 0.86 }, { 0.92, 0.85, 0.74 }, { 0.78, 0.80, 0.82 }, { 0.88, 0.78, 0.68 },
    { 0.62, 0.62, 0.60 }, { 0.56, 0.54, 0.50 } },
  metalwall = { { 0.88, 0.89, 0.90 }, { 0.72, 0.74, 0.77 }, { 0.84, 0.80, 0.72 }, { 0.66, 0.72, 0.78 } },
  stone = { { 1.0, 0.93, 0.80 }, { 0.98, 0.86, 0.66 }, { 0.95, 0.80, 0.60 }, { 0.86, 0.85, 0.82 }, { 0.92, 0.88, 0.80 } },
  office = { { 1.0, 1.0, 1.0 }, { 0.74, 0.84, 0.98 }, { 0.76, 0.92, 0.86 }, { 0.98, 0.84, 0.66 }, { 0.56, 0.58, 0.62 },
    { 0.66, 0.74, 0.86 }, { 0.88, 0.90, 0.92 } },
}
local WOOD_TINTS = { { 0.62, 0.44, 0.30 }, { 0.46, 0.33, 0.24 }, { 0.58, 0.52, 0.46 } }
local ROOF_TINTS = {
  roof_flat = { { 0.85, 0.85, 0.85 }, { 0.62, 0.62, 0.64 }, { 0.95, 0.93, 0.88 }, { 0.45, 0.45, 0.46 }, { 0.75, 0.70, 0.64 } },
  -- 1..4 slate / grey; 5..7 clay tiles; 8..10 dark (as BeamNG.Earth's ROOF_SLATE indices 0..9)
  roof_slate = { { 1.0, 1.0, 1.0 }, { 0.80, 0.66, 0.56 }, { 0.76, 0.80, 0.90 }, { 0.62, 0.62, 0.62 },
    { 0.95, 0.52, 0.36 }, { 0.78, 0.40, 0.30 }, { 1.0, 0.66, 0.46 }, { 0.42, 0.43, 0.46 }, { 0.30, 0.31, 0.33 },
    { 0.48, 0.38, 0.32 } },
  roof_metal = { { 0.85, 0.86, 0.88 }, { 0.55, 0.57, 0.60 }, { 0.45, 0.58, 0.48 }, { 0.62, 0.30, 0.26 }, { 0.40, 0.42, 0.48 } },
}
local BARN_REDS = 2
local COLOR_NAMES = {
  white = { 0.95, 0.95, 0.95 }, black = { 0.12, 0.12, 0.12 }, grey = { 0.50, 0.50, 0.50 }, gray = { 0.50, 0.50, 0.50 },
  lightgrey = { 0.75, 0.75, 0.75 }, lightgray = { 0.75, 0.75, 0.75 }, darkgrey = { 0.30, 0.30, 0.30 },
  darkgray = { 0.30, 0.30, 0.30 }, silver = { 0.75, 0.75, 0.78 }, red = { 0.75, 0.15, 0.15 }, darkred = { 0.50, 0.10, 0.10 },
  maroon = { 0.45, 0.10, 0.15 }, pink = { 0.90, 0.60, 0.65 }, brick = { 0.65, 0.25, 0.18 }, green = { 0.18, 0.55, 0.22 },
  darkgreen = { 0.10, 0.35, 0.12 }, lightgreen = { 0.45, 0.75, 0.40 }, olive = { 0.45, 0.50, 0.20 }, teal = { 0.12, 0.45, 0.45 },
  blue = { 0.18, 0.38, 0.72 }, darkblue = { 0.10, 0.20, 0.45 }, lightblue = { 0.50, 0.70, 0.88 }, navy = { 0.08, 0.15, 0.35 },
  yellow = { 0.92, 0.82, 0.20 }, lightyellow = { 0.95, 0.92, 0.60 }, gold = { 0.85, 0.70, 0.18 }, orange = { 0.90, 0.48, 0.12 },
  brown = { 0.45, 0.30, 0.20 }, darkbrown = { 0.30, 0.20, 0.12 }, beige = { 0.90, 0.85, 0.75 }, cream = { 0.95, 0.92, 0.82 },
  tan = { 0.82, 0.70, 0.55 }, terracotta = { 0.78, 0.40, 0.26 }, ochre = { 0.80, 0.55, 0.20 }, sand = { 0.88, 0.80, 0.65 },
  copper = { 0.55, 0.75, 0.65 }, purple = { 0.50, 0.20, 0.55 }, firebrick = { 0.70, 0.13, 0.13 },
}
function B.parse_color(v)
  if type(v) ~= "string" then return nil end
  local s = v:lower():gsub("%s", ""):gsub("%-", "_")
  if COLOR_NAMES[s] then return COLOR_NAMES[s] end
  local h = s:match("^#(%x+)$")
  if h and (#h == 3 or #h == 4) then
    return { tonumber(h:sub(1, 1):rep(2), 16) / 255, tonumber(h:sub(2, 2):rep(2), 16) / 255, tonumber(h:sub(3, 3):rep(2), 16) / 255 }
  elseif h and (#h == 6 or #h == 8) then
    return { tonumber(h:sub(1, 2), 16) / 255, tonumber(h:sub(3, 4), 16) / 255, tonumber(h:sub(5, 6), 16) / 255 }
  end
end

-- ---- regions (BeamNG.Earth's Style / region_style) ----
local function style(name, brick, walls, porch, flat, hipped, roofs, o)
  o = o or {}
  return { name = name, brick = brick, walls = walls, porch = porch, flat = flat, hipped = hipped, roofs = roofs,
    pitch = o.pitch, paint = o.paint or 0.3, wall_tints = o.wall_tints, wood = o.wood, attached = o.attached or 0,
    barn_red = o.barn_red or 0, stone = o.stone or 0 }
end
local US_ROOFS = { { "roof_slate", { 1, 2, 3, 4 } } }
local CLAY = { "roof_slate", { 5, 6, 7 } }
local DARK = { "roof_slate", { 8, 9, 10 } }
B.STYLES = {
  us_east = style("us_east", 0.75, { { "siding", 0.75 } }, 0.55, 0.0, 0.4, US_ROOFS, { barn_red = 0.5 }),
  us_south = style("us_south", 0.35, { { "siding", 0.75 } }, 0.55, 0.0, 0.4, US_ROOFS, { barn_red = 0.5 }),
  us_plains = style("us_plains", 0.15, { { "siding", 0.75 } }, 0.55, 0.0, 0.4, US_ROOFS, { barn_red = 0.5 }),
  us_west = style("us_west", 0.15, { { "stucco", 0.65 }, { "siding", 0.25 } }, 0.25, 0.0, 0.4, US_ROOFS, { barn_red = 0.5 }),
  alpine = style("alpine", 0.05, { { "siding", 0.45 } }, 0.0, 0.03, 0.15, { DARK, { "roof_slate", { 10, 6 } } },
    { pitch = 24.0, paint = 0.05, wood = true, attached = 0.85, stone = 0.15 }),
  europe_north = style("europe_north", 0.5, {}, 0.02, 0.05, 0.3, { CLAY, DARK, { "roof_slate", { 6 } } },
    { pitch = 42.0, paint = 0.15, attached = 0.75, stone = 0.12 }),
  nordic = style("nordic", 0.12, { { "siding", 0.65 } }, 0.0, 0.08, 0.2, { DARK, CLAY },
    { pitch = 35.0, paint = 0.2, attached = 0.3, barn_red = 0.7 }),
  mediterranean = style("mediterranean", 0.08, { { "stucco", 0.85 } }, 0.0, 0.35, 0.5, { CLAY },
    { pitch = 22.0, paint = 0.1, wall_tints = { 1, 2, 3, 4, 5, 6 }, attached = 0.8, stone = 0.4 }),
  latin_america = style("latin_america", 0.25, { { "stucco", 0.9 } }, 0.02, 0.7, 0.3, { CLAY, { "roof_metal", { 1, 2 } } },
    { pitch = 22.0, paint = 0.0, wall_tints = { 1, 2, 3, 4, 6, 7, 8, 9, 10, 11 } }),
  east_asia = style("east_asia", 0.08, { { "siding", 0.5 }, { "stucco", 0.3 } }, 0.0, 0.35, 0.5,
    { DARK, { "roof_metal", { 2, 5 } } }, { pitch = 25.0, paint = 0.0, wall_tints = { 1, 2, 7, 6 }, attached = 0.3 }),
  oceania = style("oceania", 0.55, { { "stucco", 0.5 }, { "siding", 0.3 } }, 0.25, 0.05, 0.7, { CLAY, { "roof_metal", { 1, 2, 5 } } },
    { pitch = 24.0, paint = 0.1 }),
  south_asia = style("south_asia", 0.08, { { "stucco", 0.92 } }, 0.0, 0.94, 0.2, { CLAY, { "roof_metal", { 1, 2, 4 } } },
    { pitch = 18.0, paint = 0.15, wall_tints = { 1, 2, 3, 4, 6, 7, 9, 11 }, attached = 0.90 }),
  warm = style("warm", 0.15, { { "stucco", 0.85 } }, 0.0, 0.75, 0.4, { CLAY, { "roof_metal", { 1, 2, 4 } } },
    { pitch = 20.0, paint = 0.0, wall_tints = { 1, 2, 3, 4, 5, 6, 7, 9 } }),
  cool = style("cool", 0.3, { { "siding", 0.4 } }, 0.05, 0.1, 0.3, { DARK, { "roof_metal", { 1, 2, 3, 4 } } },
    { pitch = 30.0, paint = 0.3, barn_red = 0.5 }),
}
function B.region_style(lat, lon)
  local S = B.STYLES
  if not lat or not lon then return S.us_east end
  if lat >= 24 and lat <= 72 and lon >= -170 and lon <= -52 then
    if lon < -100 then return S.us_west end
    if lon <= -95 then return S.us_plains end
    return lat > 36 and S.us_east or S.us_south
  end
  if lat >= -56 and lat < 24 and lon >= -120 and lon <= -30 then return S.latin_america end
  if lat >= 45.4 and lat <= 48 and lon >= 5.8 and lon <= 16.5 then return S.alpine end
  if lat >= 56 and lat <= 72 and lon >= 4.5 and lon <= 32 then return S.nordic end
  if lat >= 46 and lat <= 72 and lon >= -11 and lon <= 32 then return S.europe_north end
  if lat >= 30 and lat < 46 and lon >= -10 and lon <= 40 then return S.mediterranean end
  if lat >= 20 and lat <= 46 and lon >= 100 and lon <= 146 then return S.east_asia end
  if lat >= -50 and lat <= -10 and lon >= 110 and lon <= 180 then return S.oceania end
  if lat >= 6 and lat <= 37.5 and lon >= 68 and lon <= 92.5 then return S.south_asia end
  if abs(lat) >= 50 then return S.cool end
  return S.warm
end

-- ---- small things ----
-- a number in [0, 1) from the values, the same on every run (FNV-1a over their text)
function B.hash01(...)
  local s = table.concat({ ... }, "|", 1, select("#", ...))
  local h = 2166136261
  for i = 1, #s do
    h = (h ~= h) and 0 or h
    local c = s:byte(i)
    -- xor without bit ops: h = (h xor c) * 16777619 mod 2^32
    local x, y, r, p = h, c, 0, 1
    for _ = 1, 8 do
      local a, b = x % 2, y % 2
      if a ~= b then r = r + p end
      x, y, p = (x - a) / 2, (y - b) / 2, p * 2
    end
    r = r + x * p
    h = (r * 16777619) % 4294967296
  end
  return h / 4294967296
end
local H = B.hash01

local function area2(ring)
  local a, n = 0, #ring
  for i = 1, n do
    local p, q = ring[i], ring[i % n + 1]
    a = a + p[1] * q[2] - q[1] * p[2]
  end
  return a
end
B.area2 = area2

-- the minimum-area rectangle along one of the ring's edges: centre, axis u (long side), half length, half width
function B.oriented_box(ring)
  local best
  local n = #ring
  for i = 1, n do
    local p, q = ring[i], ring[i % n + 1]
    local dx, dy = q[1] - p[1], q[2] - p[2]
    local l = sqrt(dx * dx + dy * dy)
    if l > 1e-6 then
      local ux, uy = dx / l, dy / l
      local vx, vy = -uy, ux
      local amin, amax, bmin, bmax = 1e18, -1e18, 1e18, -1e18
      for _, r in ipairs(ring) do
        local a, b = r[1] * ux + r[2] * uy, r[1] * vx + r[2] * vy
        if a < amin then amin = a end
        if a > amax then amax = a end
        if b < bmin then bmin = b end
        if b > bmax then bmax = b end
      end
      local area = (amax - amin) * (bmax - bmin)
      if not best or area < best[1] - 1e-9 then best = { area, ux, uy, vx, vy, amin, amax, bmin, bmax } end
    end
  end
  if not best then return nil end
  local _, ux, uy, vx, vy, amin, amax, bmin, bmax = unpack(best)
  local sa, sb = amax + amin, bmax + bmin
  local c = { ux * sa / 2 + vx * sb / 2, uy * sa / 2 + vy * sb / 2 }
  local hl, hw = (amax - amin) / 2, (bmax - bmin) / 2
  local u = { ux, uy }
  if hw > hl then u, hl, hw = { vx, vy }, hw, hl end
  return c, u, hl, hw
end

-- per ring, how many other rings have a corner within tol of one of its edges (attached houses)
function B.shared_walls(rings, tol, tick)
  tol = tol or 0.6
  tick = tick or function() end
  local n = #rings
  local cnt = {}
  local cx, cy, rad = {}, {}, {}
  for i, r in ipairs(rings) do
    local sx, sy = 0, 0
    for _, p in ipairs(r) do sx = sx + p[1]; sy = sy + p[2] end
    cx[i], cy[i] = sx / #r, sy / #r
    local m = 0
    for _, p in ipairs(r) do local d = (p[1] - cx[i]) ^ 2 + (p[2] - cy[i]) ^ 2; if d > m then m = d end end
    rad[i] = sqrt(m)
    cnt[i] = 0
  end
  for i = 1, n do
    tick()
    for j = 1, n do
      if i ~= j and sqrt((cx[i] - cx[j]) ^ 2 + (cy[i] - cy[j]) ^ 2) <= rad[i] + rad[j] + tol then
        local ri, rj = rings[i], rings[j]
        local hit = false
        for _, p in ipairs(rj) do
          for k = 1, #ri do
            local a, b = ri[k], ri[k % #ri + 1]
            local dx, dy = b[1] - a[1], b[2] - a[2]
            local L2 = dx * dx + dy * dy
            local t = L2 > 0 and ((p[1] - a[1]) * dx + (p[2] - a[2]) * dy) / L2 or 0
            t = t < 0 and 0 or (t > 1 and 1 or t)
            local qx, qy = a[1] + dx * t - p[1], a[2] + dy * t - p[2]
            if qx * qx + qy * qy <= tol * tol then hit = true; break end
          end
          if hit then break end
        end
        if hit then cnt[i] = cnt[i] + 1 end
      end
    end
  end
  return cnt
end

-- ---- plan: what is built on a footprint ----
local function pick(list, u) return list[min(#list, floor(u * #list) + 1)] end
local function num(v)
  if v == nil then return nil end
  local n = tonumber(v)
  if n and n == n and n > -1e9 and n < 1e9 then return n end
end

function B.plan(ring, attrs, neighbours, lat, lon, dense, town)
  neighbours = neighbours or 0
  local area = area2(ring) / 2
  local sx, sy = 0, 0
  for _, p in ipairs(ring) do sx = sx + p[1]; sy = sy + p[2] end
  local seed = attrs.seed or H(floor(sx / #ring * 2 + 0.5), floor(sy / #ring * 2 + 0.5), floor(area + 0.5))
  local st = B.region_style(lat, lon)
  local _, _, hl, hw = B.oriented_box(ring)
  local box_fill = area / max(4 * hl * hw, 1e-6)
  local cls = tostring(attrs.class or attrs.building or ""):lower()
  if cls == "yes" then cls = "" end
  local name = tostring(attrs.name or ""):lower()
  local church = CHURCH_CLASSES[cls] or name:find("church") or name:find("chapel") or name:find("cathedral")
  church = church and true or false
  local narrow = hw < 4.2 and hl > 2.2 * hw
  local row = ROW_CLASSES[cls] or (narrow and (neighbours >= 1 or dense)) or (dense and area < 260 and not SHOP_CLASSES[cls])
  row = row and true or false
  local shed = (SHED_CLASSES[cls] and true) or (area < 40 and not row)
  local shop = SHOP_CLASSES[cls] or false
  local industrial = INDUSTRIAL_CLASSES[cls] or (area > 2500 and (cls == "" or cls == "commercial"))
  industrial = industrial and true or false

  local h = num(attrs.height)
  local nf = num(attrs.num_floors)
  -- a part over another (Overture / OSM min_height): its walls from there up to its height
  local mh0 = num(attrs.min_height)
  if h and mh0 and mh0 > 0 then h = h - mh0; if h <= 0.5 then h = nil end end
  if church and not h and not nf and area < 2500 then nf = 1 end
  if h and h <= 0 then h = nil end
  if nf then nf = nf > 0 and floor(nf + 0.5) or nil end
  local floor_h = B.FLOOR_M
  if industrial then floor_h = 4.5 end
  if church then floor_h = 7.5 end
  local barn = BARN_CLASSES[cls] or (shed and area >= 150 and cls ~= "garage" and cls ~= "garages" and cls ~= "carport"
    and cls ~= "roof" and cls ~= "shelter")
  barn = barn and true or false
  if barn then floor_h = area >= 150 and 5.5 or 3.5 end
  if not h and not nf then
    if shed then nf = 1
    elseif row then nf = seed < 0.25 and 2 or (seed < 0.85 and 3 or 4)
    elseif HOUSE_CLASSES[cls] or (area < 220 and not shop) then nf = seed < 0.3 and 1 or 2
    elseif industrial then nf = area > 6000 and 2 or 1
    elseif cls == "apartments" then nf = 3 + floor(seed * 3)
    elseif town then nf = seed < 0.6 and 1 or 2
    elseif area < 900 then nf = 2 + floor(seed * 2)
    else nf = 2 + floor(seed * 3) end
  end
  local roof_given = tostring(attrs.roof_shape or ""):lower()
  local roof
  if roof_given == "gabled" or roof_given == "hipped" or roof_given == "flat" then roof = roof_given
  elseif roof_given == "pyramidal" or roof_given == "half-hipped" or roof_given == "mansard" or roof_given == "gambrel" then roof = "hipped"
  elseif roof_given == "skillion" or roof_given == "dome" or roof_given == "onion" or roof_given == "round" or roof_given == "saltbox" then roof = "gabled"
  else
    local detached_house = (HOUSE_CLASSES[cls] or (area < 260 and not shop)) and not industrial and not row
    if church and neighbours == 0 then roof = "gabled"
    elseif neighbours >= 1 then
      local low = (nf or (h or 0) / B.FLOOR_M or 3) <= 6
      roof = (st.attached > 0 and low and not industrial and not shop and H(seed, "attached roof") < st.attached) and "gabled" or "flat"
    elseif barn then roof = "gabled"
    elseif shed and area < 80 then roof = seed > 0.4 and "gabled" or "flat"
    elseif detached_house then
      if st.flat > 0 and H(seed, "flat roof") < st.flat then roof = "flat"
      else roof = seed < 1.0 - st.hipped and "gabled" or "hipped" end
    else roof = "flat" end
  end
  if roof ~= "flat" and (box_fill < (church and 0.6 or 0.8) or hw < 2.0 or hw > (barn and 18.0 or (church and 20.0 or 14.0))) then
    roof = "flat"
  end
  local tall = (nf or (h or 0) / B.FLOOR_M) >= B.TOWER_SHOP_FLOORS
  if dense and tall and not HOUSE_CLASSES[cls] and not (shed or barn or church) then shop = true end
  if church then shop = false end
  if not h then
    h = nf * floor_h + ((shop and nf > 1) and (B.GROUND_FLOOR_SHOP_M - floor_h) or 0) + (roof == "flat" and 0.6 or 0.2)
  else
    local rh = num(attrs.roof_height)
    if rh and roof ~= "flat" then h = max(2.5, h - rh)
    elseif roof ~= "flat" then h = max(2.5, h - hw * tan(rad(st.pitch or B.PITCH[roof]))) end
    if not nf then nf = church and 1 or max(1, floor(h / floor_h + 0.5)) end
  end
  nf = max(1, min(nf, 120))
  floor_h = h / nf

  -- the walls: material and colour
  local wall, tint
  local windows = true
  if shed or barn then
    wall = "siding"
  else
    local u_glass = H(seed, "glass")
    local modern = (cls == "office" or cls == "commercial" or cls == "hotel") and u_glass < B.MIDRISE_GLASS_OFFICE
    local glass = nf >= B.GLASS_FLOORS[2] or (nf >= B.GLASS_FLOORS[1] and (modern or u_glass < B.OLD_TOWER_GLASS))
      or (nf >= 7 and modern)
    if nf >= 7 and not glass and not industrial then
      if H(seed, "brick") < st.brick * 1.2 then wall, tint = "brick", pick(BRICK_TINTS, H(seed, "bt"))
      else wall, tint = "plaster", pick(FACADE_TINTS, H(seed, "ft")) end
    elseif glass then
      wall, tint = "office", pick(WALL_TINTS.office, H(seed, "glass tint"))
    elseif industrial then
      wall, tint = "panel", FACADE_TINTS[4]
    else
      local detached = (HOUSE_CLASSES[cls] or (area < 260 and not shop)) and not row and neighbours == 0
      local f = row and 1.15 or (detached and 0.35 or 1.0)
      if H(seed, "brick") < st.brick * f then wall, tint = "brick", pick(BRICK_TINTS, H(seed, "bt"))
      else
        wall, tint = "plaster", pick(FACADE_TINTS, H(seed, "ft"))
        if (row or HOUSE_CLASSES[cls]) and H(seed, "paint") < st.paint then tint = pick(PAINT_TINTS, H(seed, "pc")) end
      end
    end
  end
  local house = (HOUSE_CLASSES[cls] or (area < 260 and not shop and not industrial)) and not row and not shed
    and neighbours == 0 and area < 300
  if house and wall ~= "brick" and nf <= 3 then
    local u, acc, kind = H(seed, "wall"), 0, nil
    for _, ws in ipairs(st.walls) do acc = acc + ws[2]; if u < acc then kind = ws[1]; break end end
    if kind then
      if st.wood and kind == "siding" then wall, tint = "siding", pick(WOOD_TINTS, H(seed, "wc"))
      else
        local list = WALL_TINTS[kind]
        local n = #list - (kind == "siding" and BARN_REDS or 0)
        local idx = st.wall_tints
        if idx then
          local ok = {}
          for _, t in ipairs(idx) do if t <= n then ok[#ok + 1] = t end end
          if #ok == 0 then ok = { 1 } end
          tint = list[pick(ok, H(seed, "wc"))]
        else tint = list[floor(H(seed, "wc") * n) + 1] end
        wall = kind
      end
    end
  end
  if wall ~= "brick" and wall ~= "office" and st.stone > 0 and nf <= B.STONE_FLOORS
      and not (shop or industrial or shed or barn or church) and cls ~= "apartments" and cls ~= "office"
      and cls ~= "commercial" and cls ~= "hotel" and cls ~= "retail" and H(seed, "stone") < st.stone then
    wall, tint = "stone", pick(WALL_TINTS.stone, H(seed, "stc"))
  end
  -- the mapped material and colour over the guesses
  local fm = tostring(attrs.facade_material or ""):lower()
  if (fm == "stone" or fm == "sandstone" or fm == "limestone" or fm == "granite" or fm == "marble") and not (barn or shed) then
    wall, tint = "stone", pick(WALL_TINTS.stone, H(seed, "stc"))
  elseif fm == "brick" and not (barn or shed) then wall, tint = "brick", pick(BRICK_TINTS, H(seed, "bt"))
  elseif fm == "glass" or fm == "mirror" then wall, tint = "office", pick(WALL_TINTS.office, H(seed, "glass tint"))
  elseif (fm == "wood" or fm == "timber") and not (barn or shed) then wall, tint = "siding", pick(WOOD_TINTS, H(seed, "wc"))
  elseif (fm == "concrete" or fm == "cement") and not (barn or shed) then wall, tint = "concrete", { 1, 1, 1 }
  elseif (fm == "plaster" or fm == "stucco" or fm == "render") and not (barn or shed) then wall, tint = "stucco", pick(WALL_TINTS.stucco, H(seed, "wc"))
  elseif (fm == "metal" or fm == "steel") and not (barn or shed) then wall, tint = "metalwall", pick(WALL_TINTS.metalwall, H(seed, "wc")) end
  local fc = B.parse_color(attrs.facade_color)
  if fc then tint = fc end
  if not (shed or barn or row or house or church) and nf <= 2 and roof == "flat" and (area >= B.BIG_BOX_M2 or industrial)
      and not HOUSE_CLASSES[cls] and cls ~= "apartments" then
    wall = industrial and "metalwall" or "panel"
    tint = pick(WALL_TINTS[wall], H(seed, "wc"))
    windows = false
  end
  if shed or barn then
    local list = WALL_TINTS.siding
    if barn and H(seed, "barn") < st.barn_red then tint = list[#list - floor(H(seed, "red") * 2)]
    elseif st.wood then tint = pick(WOOD_TINTS, H(seed, "wc"))
    else tint = list[floor(H(seed, "sc") * (#list - 2)) + 1] end
    windows = false
  end
  -- the roof material
  local rmat = tostring(attrs.roof_material or ""):lower()
  local roof_mat, roof_tint
  if rmat == "metal" or rmat == "tin" or rmat == "steel" or rmat == "zinc" then roof_mat = "roof_metal"; roof_tint = pick(ROOF_TINTS.roof_metal, H(seed, "roof"))
  elseif rmat == "copper" then roof_mat, roof_tint = "roof_metal", COLOR_NAMES.copper
  elseif rmat == "tile" or rmat == "tiles" or rmat == "roof_tiles" or rmat == "clay" then roof_mat = "roof_tiles"; roof_tint = ROOF_TINTS.roof_slate[5 + floor(H(seed, "roof") * 3)]
  elseif rmat == "slate" or rmat == "stone" then roof_mat = "roof_slate"; roof_tint = ROOF_TINTS.roof_slate[1 + floor(H(seed, "roof") * 4)]
  elseif roof == "flat" then roof_mat = "roof_flat"; roof_tint = pick(ROOF_TINTS.roof_flat, H(seed, "roof"))
  elseif barn or shed then roof_mat = "roof_metal"; roof_tint = pick(ROOF_TINTS.roof_metal, H(seed, "roof"))
  else
    local r = st.roofs[min(#st.roofs, floor(seed * #st.roofs) + 1)]
    local ti = pick(r[2], H(seed, "roof"))
    roof_tint = ROOF_TINTS[r[1]][ti]
    -- clay colours on the tile texture, slate greys on the slate texture
    roof_mat = (r[1] == "roof_slate" and ti >= 5 and ti <= 7) and "roof_tiles" or r[1]
  end
  local rc = B.parse_color(attrs.roof_color)
  if rc then roof_tint = rc end
  return { ring = ring, floors = nf, floor_h = floor_h, height = h, roof = roof, roof_mat = roof_mat, roof_tint = roof_tint,
    wall = wall, tint = tint, shop = shop and not shed and nf >= 1, windows = windows, seed = seed, cls = cls,
    church = church, steeple = church and area < 2500, pitch = st.pitch, min_h = num(attrs.min_height) or 0,
    jitter = 1 + B.JITTER * (2 * H(seed, "jit") - 1) }
end

-- ---- the mesh ----
B.SUN = { -0.45, -0.35, 0.82 }
do local s = B.SUN; local l = sqrt(s[1] ^ 2 + s[2] ^ 2 + s[3] ^ 2); B.SUN = { s[1] / l, s[2] / l, s[3] / l } end
local function light(nx, ny, nz)
  local d = nx * B.SUN[1] + ny * B.SUN[2] + nz * B.SUN[3]
  return 0.58 + 0.5 * (d > 0 and d or 0)
end

-- triangles grouped by texture (at most max_verts each): { tex, n, d = { x, y, z, u, v, r, g, b, ... } }
-- Small detail (window frames and bars, cornice undersides, roof clutter) is drawn near the camera only: while
-- C.detail is set, triangles go into groups per DETAIL_BLOCK_M block of the cell with G.lod = 3, G.bx, G.by the
-- block's middle and G.near = DETAIL_M (the game draws them within that distance of the block's middle).
B.DETAIL_M = 130
B.DETAIL_BLOCK_M = 64
function B.collector(max_verts)
  local C = { list = {}, cur = {}, max = max_verts or 65535, detail = false }
  function C:tri(tex, a, b, c, ua, ub, uc, col)
    local key, bi, bj = tex
    if self.detail then
      local K = B.DETAIL_BLOCK_M
      bi, bj = floor((a[1] + b[1] + c[1]) / 3 / K), floor((a[2] + b[2] + c[2]) / 3 / K)
      key = tex .. "#d#" .. bi .. "#" .. bj
    end
    local G = self.cur[key]
    if not G or G.n + 3 > self.max then
      G = { tex = tex, n = 0, d = {} }
      if bi then
        local K = B.DETAIL_BLOCK_M
        G.lod, G.bx, G.by, G.near = 3, (bi + 0.5) * K, (bj + 0.5) * K, B.DETAIL_M
      end
      self.cur[key] = G
      self.list[#self.list + 1] = G
    end
    -- the light by the triangle's facing
    local ux, uy, uz = b[1] - a[1], b[2] - a[2], b[3] - a[3]
    local vx, vy, vz = c[1] - a[1], c[2] - a[2], c[3] - a[3]
    local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
    local l = sqrt(nx * nx + ny * ny + nz * nz)
    local s = l > 0 and light(nx / l, ny / l, nz / l) or 1
    local d = G.d
    for k, p in ipairs({ a, b, c }) do
      local o = G.n * 8
      local uv = (k == 1 and ua) or (k == 2 and ub) or uc
      d[o + 1], d[o + 2], d[o + 3], d[o + 4], d[o + 5] = p[1], p[2], p[3], uv[1], uv[2]
      d[o + 6], d[o + 7], d[o + 8] = min(255, col[1] * s * 255), min(255, col[2] * s * 255), min(255, col[3] * s * 255)
      G.n = G.n + 1
    end
  end
  -- corners counter-clockwise seen from outside
  function C:quad(tex, a, b, c, d, ua, ub, uc, ud, col)
    self:tri(tex, a, b, c, ua, ub, uc, col)
    self:tri(tex, a, c, d, ua, uc, ud, col)
  end
  function C:groups() return self.list end
  return C
end

-- ear clipping of a counter-clockwise ring (indices)
local function triangulate(ring)
  local n = #ring
  local idx = {}
  for i = 1, n do idx[i] = i end
  local out = {}
  local function cross(a, b, c) return (b[1] - a[1]) * (c[2] - a[2]) - (b[2] - a[2]) * (c[1] - a[1]) end
  local guard = 0
  while #idx > 3 and guard < n * n do
    guard = guard + 1
    local m = #idx
    local found = false
    for k = 1, m do
      local ia, ib, ic = idx[(k - 2) % m + 1], idx[k], idx[k % m + 1]
      local a, b, c = ring[ia], ring[ib], ring[ic]
      if cross(a, b, c) > 1e-12 then
        local ear = true
        for _, j in ipairs(idx) do
          if j ~= ia and j ~= ib and j ~= ic then
            local p = ring[j]
            if cross(a, b, p) >= 0 and cross(b, c, p) >= 0 and cross(c, a, p) >= 0 then ear = false; break end
          end
        end
        if ear then out[#out + 1] = { ia, ib, ic }; table.remove(idx, k); found = true; break end
      end
    end
    if not found then break end
  end
  if #idx == 3 then out[#out + 1] = { idx[1], idx[2], idx[3] } end
  return out
end

local function col_of(c, f) return { c[1] * f, c[2] * f, c[3] * f } end

-- one wall from a to b: the wall material from bottom (following the ground) to top, windows over it
local function wall(out, spec, a, b, ground, z_top, base, mat, col)
  local dx, dy = b[1] - a[1], b[2] - a[2]
  local L = sqrt(dx * dx + dy * dy)
  if L < 0.05 then return end
  local tm = B.MAT[mat]
  local tw = tm.m
  -- the bottom edge follows the ground every ~2 m (and reaches a little under it)
  local n = max(1, floor(L / 2 + 0.5))
  for k = 0, n - 1 do
    local t0, t1 = k / n, (k + 1) / n
    local p = { a[1] + dx * t0, a[2] + dy * t0 }
    local q = { a[1] + dx * t1, a[2] + dy * t1 }
    local gp, gq = ground(p[1], p[2]) - B.SKIRT_M, ground(q[1], q[2]) - B.SKIRT_M
    local s0, s1 = L * t0 / tw, L * t1 / tw
    out:quad(B.MAT[mat].tex, { p[1], p[2], gp }, { q[1], q[2], gq }, { q[1], q[2], z_top }, { p[1], p[2], z_top },
      { s0, -gp / tw }, { s1, -gq / tw }, { s1, -z_top / tw }, { s0, -z_top / tw }, col)
  end
  if not spec.windows then return end
  -- windows: dark glass in a light frame, a whole number of bays, every floor above the base; the ground floor of a
  -- shop is one wide shopfront per bay
  local d = { dx / L, dy / L }
  local nrm = { d[2], -d[1] }                -- outward (counter-clockwise ring)
  local bay = spec.wall == "office" and 1.5 or 3.4
  local nb = floor(L / bay)
  if nb < 1 or L < 2 then return end
  local glass = { 0.19, 0.23, 0.27 }      -- dark, a little blue: matte glass, never a mirror
  local frame = { 0.92, 0.91, 0.88 }
  if spec.wall == "office" then frame = col_of(col, 0.75) end
  local o = B.WIN_OUT_M
  local function rect(s0, s1, z0, z1, c, out_m, near)
    out.detail = near or false
    local p = { a[1] + d[1] * s0 + nrm[1] * out_m, a[2] + d[2] * s0 + nrm[2] * out_m }
    local q = { a[1] + d[1] * s1 + nrm[1] * out_m, a[2] + d[2] * s1 + nrm[2] * out_m }
    out:quad("bld_plain", { p[1], p[2], z0 }, { q[1], q[2], z0 }, { q[1], q[2], z1 }, { p[1], p[2], z1 },
      { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 }, c)
    out.detail = false
  end
  local fw = B.FRAME_M
  for f = 0, spec.floors - 1 do
    local zf = base + f * spec.floor_h
    if f == 0 and spec.shop then
      local zt = min(base + B.GROUND_FLOOR_SHOP_M - 0.5, z_top - 0.3)
      for k = 0, nb - 1 do
        local s0, s1 = L * k / nb + 0.35, L * (k + 1) / nb - 0.35
        if s1 - s0 > 0.8 then
          rect(s0 - fw, s1 + fw, zf + 0.15, zt + fw, frame, o, true)
          rect(s0, s1, zf + 0.25, zt, glass, o + 0.01)
          -- a transom under the top lights, and mullions about every 1.4 m
          local zm = zt - min(0.6, (zt - zf) * 0.25)
          rect(s0, s1, zm - 0.04, zm + 0.04, frame, o + 0.02, true)
          local np = max(1, floor((s1 - s0) / 1.4 + 0.5))
          for j = 1, np - 1 do
            local sm = s0 + (s1 - s0) * j / np
            rect(sm - 0.04, sm + 0.04, zf + 0.25, zt, frame, o + 0.02, true)
          end
        end
      end
    else
      local w = spec.wall == "office" and (L / nb - 0.25) or B.WIN_W
      local z0 = zf + (spec.wall == "office" and 0.4 or B.WIN_SILL)
      local z1 = z0 + (spec.wall == "office" and spec.floor_h - 0.8 or min(B.WIN_H, spec.floor_h - 1.1))
      if z1 <= z_top - 0.2 and z1 > z0 + 0.3 then
        for k = 0, nb - 1 do
          if not (f == 0 and nb % 2 == 1 and k == floor(nb / 2) and not spec.shop) then     -- the front door's bay
            local s = L * (k + 0.5) / nb
            rect(s - w / 2 - fw, s + w / 2 + fw, z0 - fw, z1 + fw, frame, o, true)
            rect(s - w / 2, s + w / 2, z0, z1, glass, o + 0.01)
            if spec.wall ~= "office" then
              -- a sash bar across and one down the middle
              local zm = z0 + (z1 - z0) * 0.62
              rect(s - w / 2, s + w / 2, zm - 0.035, zm + 0.035, frame, o + 0.02, true)
              rect(s - 0.035, s + 0.035, z0, z1, frame, o + 0.02, true)
            end
          end
        end
      end
    end
  end
end

-- the ring the walls go on: a pitched roof's house is its oriented box
local function drawn_ring(spec)
  if spec.roof == "flat" then return spec.ring end
  local c, u, hl, hw = B.oriented_box(spec.ring)
  local v = { -u[2], u[1] }
  local function P(s, t) return { c[1] + u[1] * s + v[1] * t, c[2] + u[2] * s + v[2] * t } end
  return { P(-hl, -hw), P(hl, -hw), P(hl, hw), P(-hl, hw) }
end

local function roof(out, spec, ring, z_eave, col_wall)
  local rm = B.MAT[spec.roof_mat]
  local tex, tm = rm.tex, rm.m
  local rc = col_of(spec.roof_tint, spec.jitter)
  if spec.roof == "flat" then
    for _, t in ipairs(triangulate(ring)) do
      local a, b, c = ring[t[1]], ring[t[2]], ring[t[3]]
      out:tri(tex, { a[1], a[2], z_eave }, { b[1], b[2], z_eave }, { c[1], c[2], z_eave },
        { a[1] / tm, a[2] / tm }, { b[1] / tm, b[2] / tm }, { c[1] / tm, c[2] / tm }, rc)
    end
    return
  end
  local c, u, hl, hw = B.oriented_box(ring)
  local v = { -u[2], u[1] }
  local pitch = spec.pitch or B.PITCH[spec.roof]
  local hl2, hw2 = hl + B.EAVE_M, hw + B.EAVE_M
  local rise = hw2 * tan(rad(pitch))
  local ze = z_eave - B.EAVE_M * tan(rad(pitch))
  local zr = ze + rise
  local function at(s, t, z) return { c[1] + u[1] * s + v[1] * t, c[2] + u[2] * s + v[2] * t, z } end
  local slope = sqrt(hw2 * hw2 + rise * rise)
  local function uv(s, t) return { s / tm, (hw2 - abs(t)) / hw2 * slope / tm } end
  local r = spec.roof == "gabled" and hl2 or max(hl2 - hw2, 0)
  out:quad(tex, at(-hl2, -hw2, ze), at(hl2, -hw2, ze), at(r, 0, zr), at(-r, 0, zr), uv(-hl2, -hw2), uv(hl2, -hw2), uv(r, 0), uv(-r, 0), rc)
  out:quad(tex, at(hl2, hw2, ze), at(-hl2, hw2, ze), at(-r, 0, zr), at(r, 0, zr), uv(hl2, hw2), uv(-hl2, hw2), uv(-r, 0), uv(r, 0), rc)
  if spec.roof == "gabled" then
    -- the gable ends: the wall material from the eave line up to the ridge
    local wm = B.MAT[spec.wall]
    for _, sg in ipairs({ -1, 1 }) do
      local s = sg * hl
      local a, b, top = at(s, -sg * hw, z_eave), at(s, sg * hw, z_eave), at(s, 0, zr - B.EAVE_M * 0.2)
      out:tri(wm.tex, a, b, top, { 0, -z_eave / wm.m }, { 2 * hw / wm.m, -z_eave / wm.m }, { hw / wm.m, -(zr) / wm.m }, col_wall)
    end
  else
    out:tri(tex, at(hl2, -hw2, ze), at(hl2, hw2, ze), at(r, 0, zr), { -hw2 / tm, 0 }, { hw2 / tm, 0 }, { 0, slope / tm }, rc)
    out:tri(tex, at(-hl2, hw2, ze), at(-hl2, -hw2, ze), at(-r, 0, zr), { -hw2 / tm, 0 }, { hw2 / tm, 0 }, { 0, slope / tm }, rc)
  end
end

local function cornice(out, ring, z_eave)
  local col = { 0.93, 0.92, 0.89 }
  local o, z0, z1 = B.CORNICE_OUT_M, z_eave - B.CORNICE_DOWN_M, z_eave + B.CORNICE_UP_M
  local n = #ring
  local uv = { 0, 0 }
  for i = 1, n do
    local a, b = ring[i], ring[i % n + 1]
    local ex, ey = b[1] - a[1], b[2] - a[2]
    local L = sqrt(ex * ex + ey * ey)
    if L >= 0.3 then
      local dx, dy = ex / L, ey / L
      local nx, ny = dy, -dx
      local a2 = { a[1] + nx * o - dx * o, a[2] + ny * o - dy * o }
      local b2 = { b[1] + nx * o + dx * o, b[2] + ny * o + dy * o }
      out:quad("bld_plain", { a2[1], a2[2], z0 }, { b2[1], b2[2], z0 }, { b2[1], b2[2], z1 }, { a2[1], a2[2], z1 }, uv, uv, uv, uv, col)
      out.detail = true
      out:quad("bld_plain", { a[1], a[2], z1 }, { a2[1], a2[2], z1 }, { b2[1], b2[2], z1 }, { b[1], b[2], z1 }, uv, uv, uv, uv, col)
      out:quad("bld_plain", { a[1], a[2], z0 }, { b[1], b[2], z0 }, { b2[1], b2[2], z0 }, { a2[1], a2[2], z0 }, uv, uv, uv, uv, col)
      out:quad("bld_plain", { b[1], b[2], z_eave }, { a[1], a[2], z_eave }, { a[1], a[2], z1 }, { b[1], b[2], z1 }, uv, uv, uv, uv, col)
      out.detail = false
    end
  end
end

local function inside(ring, x, y)
  local c = false
  local n = #ring
  for i = 1, n do
    local a, b = ring[i], ring[i % n + 1]
    if (a[2] > y) ~= (b[2] > y) and x < a[1] + (y - a[2]) / (b[2] - a[2]) * (b[1] - a[1]) then c = not c end
  end
  return c
end

local function box(out, c, u, hx, hy, z0, z1, col, tex)
  tex = tex or "bld_plain"
  local v = { -u[2], u[1] }
  local k = {}
  for i, sg in ipairs({ { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } }) do
    k[i] = { c[1] + u[1] * sg[1] * hx + v[1] * sg[2] * hy, c[2] + u[2] * sg[1] * hx + v[2] * sg[2] * hy }
  end
  local uv = { 0, 0 }
  for i = 1, 4 do
    local a, b = k[i], k[i % 4 + 1]
    out:quad(tex, { a[1], a[2], z0 }, { b[1], b[2], z0 }, { b[1], b[2], z1 }, { a[1], a[2], z1 }, uv, uv, uv, uv, col)
  end
  out:quad(tex, { k[1][1], k[1][2], z1 }, { k[2][1], k[2][2], z1 }, { k[3][1], k[3][2], z1 }, { k[4][1], k[4][2], z1 }, uv, uv, uv, uv, col)
end

local function clutter(out, spec, ring, z_eave)
  local area = area2(ring) / 2
  if spec.roof ~= "flat" or area < B.ROOF_CLUTTER_M2 or spec.church then return end
  local c, u, hl, hw = B.oriented_box(ring)
  local v = { -u[2], u[1] }
  local n = min(6, 1 + floor(area / 600))
  local col = { 0.80, 0.82, 0.84 }
  for k = 1, n do
    local s = (H(spec.seed, "cx", k) * 2 - 1) * (hl - 3)
    local t = (H(spec.seed, "cy", k) * 2 - 1) * (hw - 3)
    local p = { c[1] + u[1] * s + v[1] * t, c[2] + u[2] * s + v[2] * t }
    if inside(ring, p[1], p[2]) then
      local big = H(spec.seed, "cb", k) < 0.25
      local hx, hy, h = 1.1, 0.7, 1.1
      if big then hx, hy, h = 2.0, 1.6, 2.6 end
      out.detail = true
      box(out, p, u, hx, hy, z_eave, z_eave + h, col)
      out.detail = false
    end
  end
end

local function steeple(out, spec, z_eave, col)
  local c, u, hl, hw = B.oriented_box(spec.ring)
  if H(spec.seed, "steeple") < 0.5 then u = { -u[1], -u[2] } end
  local side = max(3.0, min(6.0, 1.1 * hw)) / 2
  local p = { c[1] + u[1] * (hl - side), c[2] + u[2] * (hl - side) }
  local rise = (min(hw, 12.0) + B.EAVE_M) * tan(rad(spec.pitch or B.PITCH.gabled))
  local top = z_eave + rise + 6
  box(out, p, u, side, side, z_eave - 1, top, col, B.MAT[spec.wall].tex)
  local v = { -u[2], u[1] }
  local k = {}
  for i, sg in ipairs({ { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } }) do
    k[i] = { p[1] + u[1] * sg[1] * side + v[1] * sg[2] * side, p[2] + u[2] * sg[1] * side + v[2] * sg[2] * side, top }
  end
  local apex = { p[1], p[2], top + 2.6 * side * 2 }
  for i = 1, 4 do
    out:tri("bld_roof_slate", k[i], k[i % 4 + 1], apex, { 0, 0 }, { 1, 0 }, { 0.5, 2 }, { 0.62, 0.62, 0.62 })
  end
end

-- one building; ground(x, y) -> the drawn ground's height there
function B.build(spec, ground, out)
  local ring = drawn_ring(spec)
  -- the floors stand on the footprint's highest ground (no windows into a slope); the walls go down to its lowest
  local gmax, gmin = -1e9, 1e9
  for _, p in ipairs(spec.ring) do
    local g = ground(p[1], p[2])
    if g > gmax then gmax = g end
    if g < gmin then gmin = g end
  end
  local base = gmax + (spec.min_h > 0.5 and spec.min_h or 0)
  local z_eave = base + spec.height
  local col = col_of(spec.tint or { 1, 1, 1 }, spec.jitter)
  local n = #ring
  for i = 1, n do
    local a, b = ring[i], ring[i % n + 1]
    if spec.min_h > 0.5 then
      -- a part over a street / another building: no ground, a flat underside
      wall(out, spec, a, b, function() return base + B.SKIRT_M end, z_eave, base, spec.wall, col)
    else
      wall(out, spec, a, b, ground, z_eave, base, spec.wall, col)
    end
  end
  roof(out, spec, ring, z_eave, col)
  if spec.roof == "flat" and spec.wall ~= "office" and spec.floors <= 6 and not (spec.cls == "shed") then cornice(out, ring, z_eave) end
  clutter(out, spec, ring, z_eave)
  if spec.steeple then steeple(out, spec, z_eave, col) end
  return base, z_eave
end

return B
