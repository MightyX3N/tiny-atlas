-- Buildings of one cell from the map tile's building layer, made by bne_buildings.lua (BeamNG.Earth's rules). Shared
-- by every game; the result is mesh.lua-style groups (tex = "bld_*", the world pack's building textures).
--
--   buildings.build(layers, cx, cy, ground, opts) -> groups, count
--   layers   decoded zoom-14 vector tile (OpenMapTiles); cx, cy the cell inside it (0..7)
--   ground(x, y) -> metres   the drawn ground at a point (metres from the cell origin, x east, y north)
--   opts.k   metres per global unit;  opts.unit  output units per metre;  opts.tick;  opts.lat, opts.lon (region)
-- A building belongs to the cell its outline's centre is in, so each is made once; its walls may reach into the
-- next cell. Positions are relative to the cell origin like mesh.lua (x east, y north, z up).
local B = ATLAS_REQUIRE("bne_buildings")
local mesh = ATLAS_REQUIRE("mesh")
local floor, max, min, abs, sqrt = math.floor, math.max, math.min, math.abs, math.sqrt

local M = {}
M.B = B
M.TOWN_COVERAGE = 0.16          -- share of the cell under buildings: a town (BeamNG.Earth's thresholds)
M.DENSE_COVERAGE = 0.35         -- a dense city block
M.NEAR_M = 30                   -- outlines this close to the cell count as neighbours (attached houses)

mesh.add_textures(B.TEXTURES)

-- OpenMapTiles gives a colour instead of building:material for these materials (its building layer's mapping)
local OMT_MATERIAL = {
  ["#bd8161"] = "brick", ["#dadbdb"] = "plaster", ["#d48741"] = "wood", ["#d3c2b0"] = "concrete",
  ["#b7b1a6"] = "metal", ["#b4a995"] = "stone", ["#5a81a0"] = "glass", ["#6a7880"] = "concrete",
  ["#9d8b75"] = "adobe", ["#b3b0a9"] = "plaster",
}
-- OpenMapTiles' render_height is building:levels * 3.66 when only levels are mapped, 5 when nothing is
local OMT_LEVEL = 3.66

function M.attrs_of(props)
  local a = {}
  local h = tonumber(props.render_height)
  if h and h > 0 and abs(h - 5) > 1e-6 then
    local lv = h / OMT_LEVEL
    if abs(lv - floor(lv + 0.5)) < 0.02 then a.num_floors = max(1, floor(lv + 0.5)) else a.height = h end
  end
  local mh = tonumber(props.render_min_height)
  if mh and mh > 0 then a.min_height = mh end
  local c = props.colour and tostring(props.colour):lower()
  if c then
    if OMT_MATERIAL[c] then a.facade_material = OMT_MATERIAL[c] else a.facade_color = c end
  end
  return a
end

local function signed_area(r)
  local a, n = 0, #r
  for i = 1, n do
    local p, q = r[i], r[i % n + 1]
    a = a + p[1] * q[2] - q[1] * p[2]
  end
  return a / 2
end

-- a tile ring (flat x, y list, y down) as metres from the cell origin, counter-clockwise, no repeats
local function ring_metres(part, x0, y0, s)
  local r = {}
  for i = 1, #part - 1, 2 do
    local x, y = (part[i] - x0) * s, -(part[i + 1] - y0) * s
    local l = r[#r]
    if not l or (x - l[1]) ^ 2 + (y - l[2]) ^ 2 > 0.0025 then r[#r + 1] = { x, y } end
  end
  while #r > 2 and (r[1][1] - r[#r][1]) ^ 2 + (r[1][2] - r[#r][2]) ^ 2 <= 0.0025 do r[#r] = nil end
  if #r < 3 then return nil end
  local a = signed_area(r)
  if a < 0 then
    local n = #r
    for i = 1, floor(n / 2) do r[i], r[n + 1 - i] = r[n + 1 - i], r[i] end
    a = -a
  end
  return r, a
end

-- Overture's building attributes as bne_buildings.plan reads them (base: the building's, for a part)
function M.attrs_of_overture(p, base)
  local a = {}
  if base then for k, v in pairs(base) do a[k] = v end; a.seed = nil end
  for _, k in ipairs({ "height", "min_height", "num_floors", "roof_shape", "roof_height", "roof_material", "roof_color",
    "facade_material", "facade_color" }) do
    if p[k] ~= nil then a[k] = p[k] end
  end
  if p.class then a.class = p.class end
  if p.name then a.name = p.name end
  if base and p.min_height == nil then a.min_height = nil end
  -- a part's floors from its lowest floor (min_floor) when its height is not given
  if base and not p.height and p.num_floors and p.min_floor then a.num_floors = p.num_floors - p.min_floor end
  return a
end

function M.build(layers, cx, cy, ground, opts)
  local L = layers and layers.building
  if not L then return {}, 0 end
  local tick = opts.tick or function() end
  local k, U = opts.k, opts.unit or 1
  local S = L.extent / 8                      -- tile units per cell
  local x0, y0 = cx * S, cy * S
  local s = 8192 / S * k                      -- metres per tile unit
  local size = S * s                          -- the cell's side in metres
  local near = M.NEAR_M
  -- every outline in or near the cell (its outer rings; holes are courtyards, covered by the roof)
  local list = {}
  local covered = 0
  -- Overture's building parts by building (drawn in place of the building's own outline: towers on podiums)
  local parts_of = {}
  local PL = layers.building_part
  if PL then
    for _, f in ipairs(PL.features) do
      local id = f.props.building_id
      if id then local l = parts_of[id]; if not l then l = {}; parts_of[id] = l end; l[#l + 1] = f end
    end
  end
  local function outers(f)
    -- the outer rings: Overture's polygons say which ring is which; in a vector tile, outer rings run clockwise
    -- on screen (positive area with y down)
    local out = {}
    if f.polys then
      for _, poly in ipairs(f.polys) do out[#out + 1] = poly[1] end
      return out
    end
    for _, part in ipairs(f.parts) do
      local t = 0
      for i = 1, #part - 3, 2 do t = t + part[i] * part[i + 3] - part[i + 2] * part[i + 1] end
      t = t + part[#part - 1] * part[2] - part[1] * part[#part]
      if t > 0 then out[#out + 1] = part end
    end
    return out
  end
  for _, f in ipairs(L.features) do
    if f.type == 3 and f.props.hide_3d ~= true and f.props.hide_3d ~= "true" then
      local attrs = f.props.id and M.attrs_of_overture(f.props) or M.attrs_of(f.props)
      local parts = f.props.has_parts and parts_of[f.props.id]
      for _, part in ipairs(outers(f)) do
        local r, a = ring_metres(part, x0, y0, s)
        if r and a >= B.MIN_AREA_M2 then
          local sx, sy = 0, 0
          for _, p in ipairs(r) do sx = sx + p[1]; sy = sy + p[2] end
          sx, sy = sx / #r, sy / #r
          if sx >= -near and sx < size + near and sy <= near and sy > -size - near then
            local own = sx >= 0 and sx < size and sy <= 0 and sy > -size
            if own then covered = covered + a end
            if parts then
              -- the parts instead, each with its own heights (owned with their building)
              for _, pf in ipairs(parts) do
                local pa = M.attrs_of_overture(pf.props, attrs)
                for _, pp in ipairs(outers(pf)) do
                  local pr, parea = ring_metres(pp, x0, y0, s)
                  if pr and parea >= 2 then list[#list + 1] = { ring = pr, area = parea, own = own, attrs = pa, part = true } end
                end
              end
              parts = nil
            else
              list[#list + 1] = { ring = r, area = a, own = own, attrs = attrs }
            end
          end
        end
      end
    end
  end
  tick()
  local rings = {}
  for i, b in ipairs(list) do rings[i] = b.ring end
  local shared = B.shared_walls(rings, nil, tick)
  tick()
  local cover = covered / (size * size)
  local dense, town = cover >= M.DENSE_COVERAGE, cover >= M.TOWN_COVERAGE
  local out = B.collector(mesh.MAX_VERTS)
  local made = 0
  for i, b in ipairs(list) do
    if b.own then
      tick()
      local spec = B.plan(b.ring, b.attrs, b.part and 0 or shared[i], opts.lat, opts.lon, dense, town)
      B.build(spec, ground, out)
      made = made + 1
    end
  end
  local groups = out:groups()
  if U ~= 1 then
    for _, g in ipairs(groups) do
      local d = g.d
      for i = 0, g.n - 1 do local o = i * 8; d[o + 1], d[o + 2], d[o + 3] = d[o + 1] * U, d[o + 2] * U, d[o + 3] * U end
    end
  end
  return groups, made
end

return M
