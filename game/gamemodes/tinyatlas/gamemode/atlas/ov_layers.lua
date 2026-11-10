-- The map of one zoom-14 tile from Overture Maps and OpenStreetMap's road tags, in the vector tile layout cell.lua
-- and buildings.lua read (tile units 0..4096, y down). Roads get BeamNG.Earth's widths (server/roads.py
-- carriageway, roadwidth.py's widths measured between the buildings, osmtags.py's lanes and widths); buildings keep
-- Overture's attributes and parts. Shared by every game.
--
--   ov_layers.tile(O, tx, ty, opts) -> layers      inside a coroutine (downloads yield); O = overture.new(fetch)
--   layers.building, .building_part, .transportation, .water, .waterway, .ov_surface, .ov_tree: { extent = 4096, features }
--   (.ov_tree: single trees (points) and tree rows (lines) from OpenStreetMap, props.height when mapped;
--    .ov_wood: woods whose leaf type is mapped, props.leaf = "needleleaved" | "broadleaved" | "mixed")
--   feature = { type = 1 | 2 | 3, parts = { flat x, y lists }, polys = { { outer, holes... } } (polygons), props }
--   opts.tick, opts.osm (true: OpenStreetMap's lanes / widths from Layercake), opts.log
local fetch = ATLAS_REQUIRE("fetch")
local floor, min, max, abs, sqrt, log, tan, cos, rad, pi = math.floor, math.min, math.max, math.abs, math.sqrt,
  math.log, math.tan, math.cos, math.rad, math.pi

local M = {}
M.VERSION = 3
M.MARGIN = 128                  -- tile units around the tile that are read too (roads and walls reaching in)
M.LAYERCAKE = "https://data.openstreetmap.us/layercake/highways.parquet"
M.LAYERCAKE_TAIL = 12000000     -- its footer is ~9 MB
M.LAYERCAKE_MAX_AGE = 7 * 24 * 3600

-- ---- BeamNG.Earth's road widths (server/roads.py) ----
M.STYLE = { motorway = { 11.0, true }, trunk = { 9.0, true }, primary = { 8.0, true }, secondary = { 7.5, true },
  tertiary = { 6.5, true }, residential = { 6.0, true }, living_street = { 5.0, true }, unclassified = { 5.5, true },
  service = { 4.0, true }, track = { 3.5, false }, unknown = { 5.0, true } }
local ONEWAY_STYLE = { primary = 6.5, secondary = 6.5, tertiary = 4.0, residential = 3.5, living_street = 3.5,
  unclassified = 3.5, service = 3.0 }
local LANE_W = { motorway = 3.6, trunk = 3.5, primary = 3.3, secondary = 3.3, tertiary = 3.1 }
local LANE_W_DEFAULT = 3.0
local PARKING_M = 2.3
local PARKING_CLASSES = { residential = true, tertiary = true, secondary = true, unclassified = true, living_street = true }
local SIDEWALK_CLASSES = { residential = true, tertiary = true, secondary = true, primary = true, unclassified = true,
  living_street = true }
local URBAN_ARTERIAL = { trunk = 13.2 }
local EDGE_STRIP_M = 1.0
local EDGE_STRIP_CLASS_M = { tertiary = 0.0, unclassified = 0.0, secondary = 0.25 }
local SHOULDER_M, SHOULDER_WIDE_M, SHOULDER_WIDE_LANES, MOTORWAY_RURAL_M = 2.2, 3.0, 3, 7.4
local LINK_M = { 6.0, 9.0 }
local LINK_LANE_M = 3.7
local SIDEWALK_M = 2.5
local MEASURE_MAX = 3.0
local PAVED = { paved = 1, asphalt = 1, concrete = 1, metal = 1, wood = 1, tar = 1, bitumen = 1 }
local COBBLE = { paving_stones = 1, sett = 1, cobblestone = 1, unhewn_cobblestone = 1, bricks = 1, interlocking = 1,
  paver = 1, paver_blocks = 1, interlocking_pavers = 1, interlocking_stones = 1, pavers = 1, block_pavers = 1,
  paving_stone = 1, stone = 1, stones = 1 }
local GRAVEL = { gravel = 1, fine_gravel = 1, compacted = 1, pebblestone = 1, wbm = 1, laterite = 1 }
local UNPAVED = { unpaved = 1, ground = 1, dirt = 1, earth = 1, mud = 1, grass = 1, grass_paver = 1, sand = 1, soil = 1,
  rock = 1, rocky = 1, bedrock = 1, clay = 1, shells = 1, woodchips = 1 }

local function token(s)
  if not s then return nil end
  return tostring(s):lower():match("^%s*([^:;%s]+)")
end
function M.surface_kind(cls, surface)
  local s = token(surface)
  if s then
    if PAVED[s] then return "paved" end
    if COBBLE[s] then return "cobble" end
    if GRAVEL[s] then return "gravel" end
    if s == "unpaved" and cls ~= "track" then return "gravel" end
    if UNPAVED[s] then return "dirt" end
  end
  return (M.STYLE[cls] or M.STYLE.unknown)[2] and "paved" or "dirt"
end

-- roads.carriageway: the paved / dirt width (m) of a road
function M.carriageway(cls, kind, urban, rule_w, oneway, lanes)
  if rule_w then return rule_w end
  if not lanes and (cls == "motorway" or cls == "trunk") then lanes = 2 end
  local w = (M.STYLE[cls] or M.STYLE.unknown)[1]
  if oneway and ONEWAY_STYLE[cls] then w = ONEWAY_STYLE[cls] end
  if lanes then w = lanes * (LANE_W[cls] or LANE_W_DEFAULT) end
  if kind ~= "paved" and kind ~= "cobble" then return w end
  if lanes and not urban and oneway and cls == "motorway" then
    return w + 2 * (lanes >= SHOULDER_WIDE_LANES and SHOULDER_WIDE_M or SHOULDER_M)
  end
  if urban and not oneway and URBAN_ARTERIAL[cls] and not lanes then return URBAN_ARTERIAL[cls] end
  if urban and PARKING_CLASSES[cls] then return w + (oneway and 1 or 2) * PARKING_M end
  if not urban and cls ~= "service" then
    if oneway and cls == "motorway" then return MOTORWAY_RURAL_M + 2 * SHOULDER_M end
    return w + 2 * (EDGE_STRIP_CLASS_M[cls] or EDGE_STRIP_M)
  end
  return w
end
local function link_width(lanes) return LINK_M[lanes] or (LINK_M[2] + (lanes - 2) * LINK_LANE_M) end

-- ---- roadwidth.py: the right-of-way between the building walls along a street ----
local RW = { STEP = 6.0, END_SKIP = 10.0, REACH = 25.0, MIN_SAMPLES = 4, WALLED = 0.6, AGREE = 0.3, WALK_SHARE = 0.2,
  WALK_MIN = 1.8, WALK_MAX = 4.5, CARRIAGE_MIN = 3.0, WALK_NARROW_MIN = 0.6, BUCKET = 16.0 }
M.RW = RW

local function walls_index(segs)
  local idx = {}
  local B = RW.BUCKET
  for i = 1, #segs, 4 do
    local x0, y0, x1, y1 = segs[i], segs[i + 1], segs[i + 2], segs[i + 3]
    for by = floor(min(y0, y1) / B), floor(max(y0, y1) / B) do
      for bx = floor(min(x0, x1) / B), floor(max(x0, x1) / B) do
        local k = by * 1000003 + bx
        local l = idx[k]
        if not l then l = {}; idx[k] = l end
        l[#l + 1] = i
      end
    end
  end
  return idx
end
-- the distance along (dx, dy) from (px, py) to the first wall, or nil within reach (roadwidth.Walls.ray)
local function wall_ray(segs, idx, px, py, dx, dy, reach)
  local B = RW.BUCKET
  local ex, ey = px + dx * reach, py + dy * reach
  local best = math.huge
  local seen = {}
  for by = floor(min(py, ey) / B), floor(max(py, ey) / B) do
    for bx = floor(min(px, ex) / B), floor(max(px, ex) / B) do
      local l = idx[by * 1000003 + bx]
      if l then
        for _, i in ipairs(l) do
          if not seen[i] then
            seen[i] = true
            local ax, ay, bx2, by2 = segs[i], segs[i + 1], segs[i + 2], segs[i + 3]
            local sx, sy = bx2 - ax, by2 - ay
            local den = dx * sy - dy * sx
            if abs(den) > 1e-12 then
              local wx, wy = ax - px, ay - py
              local t = (wx * sy - wy * sx) / den
              local u = (wx * dy - wy * dx) / den
              if t > 0 and t <= reach and u >= 0 and u <= 1 and t < best then best = t end
            end
          end
        end
      end
    end
  end
  if best < math.huge then return best end
end
local function percentile(v, q)
  local n = #v
  local i = q / 100 * (n - 1)
  local lo = floor(i)
  local hi = min(lo + 1, n - 1)
  local g = i - lo
  local a, b = v[lo + 1], v[hi + 1]
  return a + (b - a) * g
end
-- xs, ys: the centreline (metres); the right-of-way or nil (roadwidth.measure_row)
function M.measure_row(xs, ys, segs, idx)
  local k = #xs
  if k < 2 then return nil end
  local s = { 0 }
  for i = 2, k do s[i] = s[i - 1] + sqrt((xs[i] - xs[i - 1]) ^ 2 + (ys[i] - ys[i - 1]) ^ 2) end
  local total = s[k]
  if total < 2 * RW.END_SKIP + RW.STEP then return nil end
  local w, n = {}, 0
  local j = 2
  local dd = RW.END_SKIP
  while dd <= total - RW.END_SKIP + 1e-9 do
    while j < k and s[j] < dd do j = j + 1 end
    local tx, ty = xs[j] - xs[j - 1], ys[j] - ys[j - 1]
    local len = sqrt(tx * tx + ty * ty)
    if len >= 1e-6 then
      n = n + 1
      local nx, ny = -ty / len, tx / len
      local t = (dd - s[j - 1]) / max(s[j] - s[j - 1], 1e-9)
      if t < 0 then t = 0 elseif t > 1 then t = 1 end
      local cx, cy = xs[j - 1] + tx * t, ys[j - 1] + ty * t
      local a = wall_ray(segs, idx, cx, cy, nx, ny, RW.REACH)
      local b = a and wall_ray(segs, idx, cx, cy, -nx, -ny, RW.REACH)
      if a and b then w[#w + 1] = a + b end
    end
    dd = dd + RW.STEP
  end
  if n == 0 or #w < RW.MIN_SAMPLES or #w / n < RW.WALLED then return nil end
  table.sort(w)
  local m = #w
  local med = m % 2 == 1 and w[(m + 1) / 2] or (w[m / 2] + w[m / 2 + 1]) / 2
  if (percentile(w, 75) - percentile(w, 25)) / med > RW.AGREE then return nil end
  return med
end
function M.split_row(row)
  local walk = min(RW.WALK_MAX, max(RW.WALK_MIN, RW.WALK_SHARE * row))
  walk = min(walk, max(RW.WALK_NARROW_MIN, (row - RW.CARRIAGE_MIN) / 2))
  local cw = row - 2 * walk
  if cw < RW.CARRIAGE_MIN then return nil end
  return cw, walk
end

-- ---- geometry helpers ----
local function proj_fn(tx, ty)
  local n = 2 ^ 14
  return function(lon, lat)
    local x = ((lon + 180) / 360 * n - tx) * 4096
    local lr = rad(lat)
    local y = ((1 - log(tan(lr) + 1 / cos(lr)) / pi) / 2 * n - ty) * 4096
    return x, y
  end
end
local function project(part, proj)
  local out = {}
  for k = 1, #part, 2 do
    out[k], out[k + 1] = proj(part[k], part[k + 1])
  end
  return out
end
-- Sutherland-Hodgman clip of a closed flat ring to [lo, hi]^2 (nil if nothing is left)
local function clip_ring(r, lo, hi)
  local inside = true
  for k = 1, #r, 2 do
    if r[k] < lo or r[k] > hi or r[k + 1] < lo or r[k + 1] > hi then inside = false; break end
  end
  if inside then return r end
  local pts = {}
  for k = 1, #r - 2, 2 do pts[#pts + 1] = r[k]; pts[#pts + 1] = r[k + 1] end
  local function pass(P, keep, cut)
    local out, n = {}, #P
    if n == 0 then return out end
    local sx, sy = P[n - 1], P[n]
    local sin = keep(sx, sy)
    for k = 1, n, 2 do
      local ex, ey = P[k], P[k + 1]
      local ein = keep(ex, ey)
      if ein then
        if not sin then local ix, iy = cut(sx, sy, ex, ey); out[#out + 1] = ix; out[#out + 1] = iy end
        out[#out + 1] = ex; out[#out + 1] = ey
      elseif sin then
        local ix, iy = cut(sx, sy, ex, ey); out[#out + 1] = ix; out[#out + 1] = iy
      end
      sx, sy, sin = ex, ey, ein
    end
    return out
  end
  local function cx(v) return function(ax, ay, bx, by) return v, ay + (v - ax) / (bx - ax) * (by - ay) end end
  local function cy(v) return function(ax, ay, bx, by) return ax + (v - ay) / (by - ay) * (bx - ax), v end end
  pts = pass(pts, function(x) return x >= lo end, cx(lo))
  pts = pass(pts, function(x) return x <= hi end, cx(hi))
  pts = pass(pts, function(_, y) return y >= lo end, cy(lo))
  pts = pass(pts, function(_, y) return y <= hi end, cy(hi))
  if #pts < 6 then return nil end
  pts[#pts + 1] = pts[1]; pts[#pts + 1] = pts[2]
  return pts
end
local function bbox_of(parts)
  local a0, b0, a1, b1 = 1e18, 1e18, -1e18, -1e18
  for _, p in ipairs(parts) do
    for k = 1, #p, 2 do
      local x, y = p[k], p[k + 1]
      if x < a0 then a0 = x end
      if x > a1 then a1 = x end
      if y < b0 then b0 = y end
      if y > b1 then b1 = y end
    end
  end
  return a0, b0, a1, b1
end
-- the piece of a polyline (flat list) between fractions a and b of its length
local function sub_line(p, a, b)
  local n = #p / 2
  local s = { 0 }
  for i = 2, n do
    local k = 2 * i - 1
    s[i] = s[i - 1] + sqrt((p[k] - p[k - 2]) ^ 2 + (p[k + 1] - p[k - 1]) ^ 2)
  end
  local total = s[n]
  if total <= 0 then return nil end
  local da, db = a * total, b * total
  local out = {}
  local function at(d)
    for i = 2, n do
      if s[i] >= d then
        local t = (d - s[i - 1]) / max(s[i] - s[i - 1], 1e-12)
        local k = 2 * i - 1
        return p[k - 2] + (p[k] - p[k - 2]) * t, p[k - 1] + (p[k + 1] - p[k - 1]) * t
      end
    end
    return p[2 * n - 1], p[2 * n]
  end
  local x, y = at(da)
  out[1], out[2] = x, y
  for i = 2, n - 1 do
    if s[i] > da and s[i] < db then out[#out + 1] = p[2 * i - 1]; out[#out + 1] = p[2 * i] end
  end
  x, y = at(db)
  out[#out + 1], out[#out + 2] = x, y
  if #out < 4 then return nil end
  return out
end

-- road flag ranges: { { a, b, kind }, ... } of "bridge" / "tunnel" over the segment (fractions of its length)
local function flag_ranges(values, between, levels, level_between)
  local out = {}
  for i, vs in ipairs(values or {}) do
    local kind
    for _, v in ipairs(vs or {}) do
      if v == "is_bridge" then kind = "bridge" elseif v == "is_tunnel" and kind ~= "bridge" then kind = "tunnel" end
    end
    if kind then
      local bt = between and between[i] or {}
      out[#out + 1] = { bt[1] or 0, bt[2] or 1, kind }
    end
  end
  for i, lv in ipairs(levels or {}) do
    if lv and lv ~= 0 then
      local bt = level_between and level_between[i] or {}
      out[#out + 1] = { bt[1] or 0, bt[2] or 1, lv > 0 and "bridge" or "tunnel" }
    end
  end
  table.sort(out, function(p, q) return p[1] < q[1] end)
  return out
end

-- Overture road class -> the vector tile class cell.lua knows (and its subclass)
local OMT_CLASS = { motorway = "motorway", trunk = "trunk", primary = "primary", secondary = "secondary",
  tertiary = "tertiary", residential = "minor", living_street = "minor", unclassified = "minor", unknown = "minor",
  service = "service", track = "track", pedestrian = "path", footway = "path", steps = "path", path = "path",
  cycleway = "path", bridleway = "path", sidewalk = "path", crosswalk = "path" }
local PATH_W = { pedestrian = 4.0, footway = 2.0, steps = 2.0, path = 2.0, cycleway = 2.5, bridleway = 2.5,
  sidewalk = 2.0, crosswalk = 3.0 }
local RAIL_SKIP = { subway = true, funicular = true, monorail = true }

-- Overture land use -> a ground surface (cell.lua's names)
local LANDUSE = {
  residential = "residential", commercial = "commercial", retail = "commercial", industrial = "industrial",
  cemetery = "cemetery", grave_yard = "cemetery", park = "park", garden = "park", playground = "park",
  dog_park = "park", grass = "grass", meadow = "grass", village_green = "grass", recreation_ground = "grass",
  pitch = "pitch", sports_centre = "pitch", stadium = "pitch", track = "pitch", golf_course = "grass",
  pedestrian = "paved", plaza = "paved", parking = "paved", garages = "paved", railway = "industrial",
  school = "residential", university = "residential", college = "residential", hospital = "residential",
  kindergarten = "residential", farmland = "farmland", farmyard = "farmland", orchard = "farmland",
  vineyard = "farmland", allotments = "park", plant_nursery = "farmland", greenhouse_horticulture = "farmland",
  forest = "wood", wood = "wood", quarry = "rock", landfill = "rock", construction = "industrial",
  brownfield = "industrial", military = "grass", beach = "sand", aerodrome = "grass", apron = "paved",
  runway = "paved", taxiway = "paved",
}
local WATERWAY_CLASS = { river = "river", stream = "stream", canal = "canal", ditch = "ditch", drain = "drain",
  tidal_channel = "canal", fairway = nil }

-- ---- the tile ----
function M.box(tx, ty, margin)
  local n = 2 ^ 14
  local m = (margin or M.MARGIN) / 4096
  local lon0 = (tx - m) / n * 360 - 180
  local lon1 = (tx + 1 + m) / n * 360 - 180
  local lat1 = fetch.lat_of(ty - m, 14)
  local lat0 = fetch.lat_of(ty + 1 + m, 14)
  return lon0, lat0, lon1, lat1
end

local BUILDING_COLS = { "geometry", "id", "height", "min_height", "num_floors", "min_floor", "roof_shape", "roof_height",
  "roof_material", "roof_color", "roof_direction", "roof_orientation", "facade_material", "facade_color", "class",
  "subtype", "has_parts", "is_underground", "names.primary" }
local PART_COLS = { "geometry", "building_id", "height", "min_height", "num_floors", "min_floor", "roof_shape",
  "roof_height", "roof_material", "roof_color", "roof_direction", "roof_orientation", "facade_material", "facade_color" }
local SEGMENT_COLS = { "geometry", "subtype", "class", "subclass", "names.primary", "sources.list.element.record_id",
  "road_flags.list.element.values.list.element", "road_flags.list.element.between.list.element",
  "level_rules.list.element.value", "level_rules.list.element.between.list.element",
  "width_rules.list.element.value", "road_surface.list.element.value" }
local WATER_COLS = { "geometry", "subtype", "class", "is_salt", "level" }
local LANDUSE_COLS = { "geometry", "subtype", "class", "surface", "level" }

local function polygon_features(rows, proj, lo, hi, make_props, tick)
  local feats = {}
  for ri, r in ipairs(rows) do
    if tick and ri % 64 == 0 then tick() end
    local g = r.geometry
    if g and g.kind == "polygon" then
      local props = make_props(r)
      if props then
        local polys, parts = {}, {}
        for _, poly in ipairs(g.polys) do
          local pp = {}
          for ri, ring in ipairs(poly) do
            local c = clip_ring(project(ring, proj), lo, hi)
            if c then pp[#pp + 1] = c; parts[#parts + 1] = c
            elseif ri == 1 then break end
          end
          if #pp > 0 then polys[#polys + 1] = pp end
        end
        if #parts > 0 then feats[#feats + 1] = { type = 3, parts = parts, polys = polys, props = props } end
      end
    end
  end
  return feats
end

local function num(v) return type(v) == "number" and v or nil end

function M.tile(O, tx, ty, opts)
  opts = opts or {}
  local tick = opts.tick or function() end
  local logf = opts.log or function() end
  local lon0, lat0, lon1, lat1 = M.box(tx, ty)
  local proj = proj_fn(tx, ty)
  local lo, hi = -M.MARGIN, 4096 + M.MARGIN
  local lat = fetch.lat_of(ty + 0.5, 14)
  local mpt = 40075016.686 * cos(rad(lat)) / 2 ^ 14 / 4096          -- metres per tile unit
  local layers = {}
  local function L(name) local t = { extent = 4096, features = {} }; layers[name] = t; return t.features end

  -- buildings and their parts
  local brows = O:query("buildings/building", lon0, lat0, lon1, lat1, BUILDING_COLS, tick)
  local bf = L("building")
  local feats = polygon_features(brows, proj, lo, hi, function(r)
    if r.is_underground then return nil end
    return { id = r.id, height = num(r.height), min_height = num(r.min_height), num_floors = num(r.num_floors),
      min_floor = num(r.min_floor), roof_shape = r.roof_shape, roof_height = num(r.roof_height),
      roof_material = r.roof_material, roof_color = r.roof_color, roof_direction = num(r.roof_direction),
      roof_orientation = r.roof_orientation, facade_material = r.facade_material, facade_color = r.facade_color,
      class = r.class, subtype = r.subtype, has_parts = r.has_parts or nil, name = r["names.primary"] }
  end, tick)
  for _, f in ipairs(feats) do bf[#bf + 1] = f end
  tick()
  local prow = O:query("buildings/building_part", lon0, lat0, lon1, lat1, PART_COLS, tick)
  local pf = L("building_part")
  feats = polygon_features(prow, proj, lo, hi, function(r)
    return { building_id = r.building_id, height = num(r.height), min_height = num(r.min_height),
      num_floors = num(r.num_floors), min_floor = num(r.min_floor), roof_shape = r.roof_shape,
      roof_height = num(r.roof_height), roof_material = r.roof_material, roof_color = r.roof_color,
      roof_direction = num(r.roof_direction), roof_orientation = r.roof_orientation,
      facade_material = r.facade_material, facade_color = r.facade_color }
  end, tick)
  for _, f in ipairs(feats) do pf[#pf + 1] = f end
  tick()

  -- building walls (metres, for the street widths) and coverage on an 8 x 8 grid (town or country)
  local segs = {}
  local cover = {}
  for i = 0, 63 do cover[i] = 0 end
  for fi, f in ipairs(bf) do
    if fi % 128 == 0 then tick() end
    for _, poly in ipairs(f.polys) do
      local r = poly[1]
      local a = 0
      for k = 1, #r - 2, 2 do
        segs[#segs + 1] = r[k] * mpt; segs[#segs + 1] = r[k + 1] * mpt
        segs[#segs + 1] = r[k + 2] * mpt; segs[#segs + 1] = r[k + 3] * mpt
        a = a + r[k] * r[k + 3] - r[k + 2] * r[k + 1]
      end
      local x0, y0, x1, y1 = bbox_of({ r })
      local gx, gy = floor((x0 + x1) / 2 / 512), floor((y0 + y1) / 2 / 512)
      if gx >= 0 and gx < 8 and gy >= 0 and gy < 8 then
        cover[gy * 8 + gx] = cover[gy * 8 + gx] + abs(a) / 2
      end
    end
  end
  local cell_area = 512 * 512
  for i = 0, 63 do cover[i] = cover[i] / cell_area end
  local widx = walls_index(segs)
  local function urban_at(x, y)
    local gx, gy = floor(x / 512), floor(y / 512)
    gx = gx < 0 and 0 or (gx > 7 and 7 or gx)
    gy = gy < 0 and 0 or (gy > 7 and 7 or gy)
    return cover[gy * 8 + gx] >= (opts.urban_cover or 0.08)
  end
  tick()

  -- OpenStreetMap's road tags (Layercake), by way id
  local osm = {}
  if opts.osm ~= false then
    -- the file is rebuilt in place about weekly: its footer and blocks are kept per week, and read again from a
    -- fresh footer when what was read does not decode (rebuilt since)
    local week = os.date("!%Y-%W")
    local function read(dir)
      local src = { url = M.LAYERCAKE, dir = dir, tail = M.LAYERCAKE_TAIL }
      local rows = O:query_file(src, lon0, lat0, lon1, lat1, { "id", "lanes", "width", "oneway", "sidewalk", "surface", "highway" }, tick)
      for _, r in ipairs(rows) do if r.id then osm[r.id] = r end end
    end
    local ok, err = pcall(read, "osm/highways/" .. week)
    if not ok then
      O.meta[M.LAYERCAKE] = nil
      ok, err = pcall(read, "osm/highways/" .. week .. "-" .. os.time())
    end
    if not ok then logf("OpenStreetMap road tags not read (widths from the road classes): " .. tostring(err)) end
  end
  local function osm_num(v, lo2, hi2, ft)
    if type(v) ~= "string" then return nil end
    local n = tonumber(v:match("^%s*([0-9]+%.?[0-9]*)"))
    if not n then return nil end
    if ft and (v:find("ft") or v:find("'")) then n = n * 0.3048 end
    if n < lo2 or n > hi2 then return nil end
    return n
  end

  -- roads, paths, rail
  local srows = O:query("transportation/segment", lon0, lat0, lon1, lat1, SEGMENT_COLS, tick)
  local tf = L("transportation")
  local nmeasured = 0
  for si, r in ipairs(srows) do
    if si % 16 == 0 then tick() end
    local g = r.geometry
    local cls = r.class
    if g and g.kind == "line" and cls then
      local sub = r.subtype
      local rec = (r["sources.list.element.record_id"] or {})[1]
      local wid = rec and tonumber(tostring(rec):match("^w(%d+)"))
      local t = wid and osm[wid]
      local surf = (r["road_surface.list.element.value"] or {})[1] or (t and t.surface)
      local props, width
      if sub == "road" then
        local oc = OMT_CLASS[cls]
        if oc and not (t and (t.highway == "construction" or t.highway == "proposed")) then
          local kind = M.surface_kind(cls, surf)
          props = { class = oc, subclass = (cls == "cycleway") and "cycleway" or r.subclass, oclass = cls,
            surface = (kind == "gravel" or kind == "dirt") and "unpaved" or "paved", kind = kind, name = r["names.primary"] }
          if M.STYLE[cls] then
            local rw = (r["width_rules.list.element.value"] or {})[1]
            local rule_w = (num(rw) and rw >= 1 and rw <= 40) and rw or (t and osm_num(t.width, 2, 40, true))
            local lanes = t and osm_num(t.lanes, 1, 12)
            if lanes then lanes = floor(lanes) end
            local ov = t and t.oneway
            local oneway = ov == "yes" or ov == "1" or ov == "-1" or ov == "true"
            local link = r.subclass == "link"
            if not rule_w and link then rule_w = link_width(lanes or (oneway and 1 or 2)) end
            -- town or country: the buildings around its points
            local parts = g.parts[1]
            local pts = project(parts, proj)
            local nu, nn = 0, 0
            for k = 1, #pts, 2 do nn = nn + 1; if urban_at(pts[k], pts[k + 1]) then nu = nu + 1 end end
            local urban = nn > 0 and nu / nn >= 0.5
            width = M.carriageway(cls, kind, urban, rule_w, oneway, lanes)
            local walk
            -- a street walled by buildings: its width between them (roadwidth.py), where the map gives none
            if (kind == "paved" or kind == "cobble") and SIDEWALK_CLASSES[cls] and urban and not rule_w and not lanes then
              local xs, ys = {}, {}
              for k = 1, #pts, 2 do xs[#xs + 1] = pts[k] * mpt; ys[#ys + 1] = pts[k + 1] * mpt end
              local row = M.measure_row(xs, ys, segs, widx)
              if row then
                local cw, wk = M.split_row(row)
                local dflt = M.carriageway(cls, kind, true, nil, oneway, nil)
                local minimum = (cls == "residential" or cls == "living_street" or cls == "unclassified" or cls == "tertiary") and 3.0 or 0.6 * dflt
                if cw and cw >= minimum and cw <= MEASURE_MAX * dflt then width, walk = cw, wk; nmeasured = nmeasured + 1 end
              end
            end
            if (kind == "paved" or kind == "cobble") and SIDEWALK_CLASSES[cls] and urban then
              local sw = t and t.sidewalk
              if sw ~= "no" and sw ~= "none" and sw ~= "separate" then props.walk = walk or SIDEWALK_M end
            end
            props.lanes, props.oneway, props.urban = lanes, oneway or nil, urban or nil
          else
            local rw = t and osm_num(t.width, 0.5, 20, true)
            width = rw or PATH_W[cls] or 2.0
          end
          props.width = width
        end
      elseif sub == "rail" then
        if not RAIL_SKIP[cls] then props = { class = (cls == "tram" or cls == "light_rail") and "transit" or "rail", subclass = cls } end
      end
      if props then
        local ranges = flag_ranges(r["road_flags.list.element.values.list.element"], r["road_flags.list.element.between.list.element"],
          r["level_rules.list.element.value"], r["level_rules.list.element.between.list.element"])
        for _, line in ipairs(g.parts) do
          local p = project(line, proj)
          if #ranges == 0 then
            tf[#tf + 1] = { type = 2, parts = { p }, props = props }
          else
            -- split into the bridge / tunnel pieces and the ground between them
            local pos = 0
            for _, rg in ipairs(ranges) do
              if rg[1] > pos + 1e-6 then
                local q = sub_line(p, pos, rg[1])
                if q then tf[#tf + 1] = { type = 2, parts = { q }, props = props } end
              end
              local q = sub_line(p, max(pos, rg[1]), rg[2])
              if q then
                local pr = {}
                for k, v in pairs(props) do pr[k] = v end
                pr.brunnel = rg[3]
                tf[#tf + 1] = { type = 2, parts = { q }, props = pr }
              end
              if rg[2] > pos then pos = rg[2] end
            end
            if pos < 1 - 1e-6 then
              local q = sub_line(p, pos, 1)
              if q then tf[#tf + 1] = { type = 2, parts = { q }, props = props } end
            end
          end
        end
      end
    end
  end
  tick()

  -- water
  local wrows = O:query("base/water", lon0, lat0, lon1, lat1, WATER_COLS, tick)
  local wf, wl = L("water"), L("waterway")
  for wi, r in ipairs(wrows) do
    if wi % 16 == 0 then tick() end
    local g = r.geometry
    if g and (r.level or 0) >= 0 then
      if g.kind == "polygon" then
        local sea = r.subtype == "ocean" or r.class == "ocean" or r.class == "sea" or r.class == "bay" or r.class == "strait"
        local fs = polygon_features({ r }, proj, lo, hi, function()
          if r.class == "swimming_pool" or r.class == "fountain" then return nil end
          return { class = sea and "ocean" or (r.class or "lake") }
        end)
        for _, f in ipairs(fs) do wf[#wf + 1] = f end
      elseif g.kind == "line" then
        local c = WATERWAY_CLASS[r.class or ""]
        if c then
          for _, line in ipairs(g.parts) do wl[#wl + 1] = { type = 2, parts = { project(line, proj) }, props = { class = c } } end
        end
      end
    end
  end
  tick()

  -- land use
  local lrows = O:query("base/land_use", lon0, lat0, lon1, lat1, LANDUSE_COLS, tick)
  local lf = L("ov_surface")
  local fs = polygon_features(lrows, proj, lo, hi, function(r)
    if (r.level or 0) ~= 0 then return nil end
    local s = LANDUSE[r.class or ""] or LANDUSE[r.subtype or ""]
    if not s then return nil end
    return { surf = s, class = r.class }
  end, tick)
  for _, f in ipairs(fs) do lf[#lf + 1] = f end
  tick()

  -- single trees and tree rows (street trees, trees in gardens and squares)
  local tf2 = L("ov_tree")
  local ok_t, trows = pcall(O.query, O, "base/land", lon0, lat0, lon1, lat1, { "geometry", "subtype", "class", "height",
    "source_tags.key_value.key", "source_tags.key_value.value" }, tick)
  if not ok_t then logf("single trees not read: " .. tostring(trows)); trows = {} end
  for ri, r in ipairs(trows) do
    local g = r.geometry
    if g and (r.class == "tree" or r.class == "tree_row") and (g.kind == "point" or g.kind == "line") then
      for _, part in ipairs(g.parts) do
        local pp = project(part, proj)
        local inside = false
        for i = 1, #pp - 1, 2 do
          if pp[i] >= lo and pp[i] <= hi and pp[i + 1] >= lo and pp[i + 1] <= hi then inside = true; break end
        end
        if inside then
          tf2[#tf2 + 1] = { type = g.kind == "point" and 1 or 2, parts = { pp }, props = { class = r.class, height = num(r.height) } }
        end
      end
    end
    if ri % 256 == 0 then tick() end
  end
  -- woods with their leaf type (OpenStreetMap's leaf_type): which trees grow in them
  local LEAF = { needleleaved = true, broadleaved = true, mixed = true }
  local wrows = {}
  for _, r in ipairs(trows) do
    if r.subtype == "forest" and r.geometry and r.geometry.kind == "polygon" then
      local ks, vs = r["source_tags.key_value.key"], r["source_tags.key_value.value"]
      if type(ks) == "table" and type(vs) == "table" then
        for i, kk in ipairs(ks) do
          if kk == "leaf_type" and LEAF[vs[i]] then r.leaf = vs[i]; wrows[#wrows + 1] = r; break end
        end
      end
    end
  end
  local wf = L("ov_wood")
  for _, f in ipairs(polygon_features(wrows, proj, lo, hi, function(r) return { leaf = r.leaf } end, tick)) do wf[#wf + 1] = f end
  layers.stats = { buildings = #bf, parts = #pf, roads = #tf, water = #wf + #wl, landuse = #lf, trees = #tf2, woods_leaf = #wf, measured = nmeasured,
    osm_ways = (function() local n = 0 for _ in pairs(osm) do n = n + 1 end return n end)() }
  return layers
end

-- ---- a tile's layers on disk (so a place visited before needs no Parquet decoding) ----
local function ser(v, out)
  local t = type(v)
  if t == "number" then
    if v == floor(v) and abs(v) < 1e15 then out[#out + 1] = string.format("%d", v)
    else out[#out + 1] = string.format("%.3f", v) end
  elseif t == "string" then out[#out + 1] = string.format("%q", v)
  elseif t == "boolean" then out[#out + 1] = v and "true" or "false"
  elseif t == "table" then
    out[#out + 1] = "{"
    local n = #v
    for i = 1, n do ser(v[i], out); out[#out + 1] = "," end
    for k, x in pairs(v) do
      if type(k) == "string" then
        out[#out + 1] = "[" .. string.format("%q", k) .. "]="
        ser(x, out); out[#out + 1] = ","
      elseif type(k) == "number" and (k < 1 or k > n or k ~= floor(k)) then
        out[#out + 1] = "[" .. k .. "]="
        ser(x, out); out[#out + 1] = ","
      end
    end
    out[#out + 1] = "}"
  else out[#out + 1] = "nil" end
end
function M.serialize(layers, tick)
  -- features in small functions (a Lua function holds at most 65536 constants)
  local out = { "local L = {}\n" }
  for name, l in pairs(layers) do
    if type(l) == "table" and l.features then
      out[#out + 1] = string.format("L[%q] = { extent = %d, features = {} }\n", name, l.extent)
      local fs = l.features
      for i = 1, #fs, 200 do
        out[#out + 1] = string.format("do local f = L[%q].features; (function() ", name)
        if tick then tick() end
        for j = i, math.min(#fs, i + 199) do
          out[#out + 1] = "f[#f + 1] = "
          ser(fs[j], out)
          out[#out + 1] = "\n"
        end
        out[#out + 1] = "end)() end\n"
      end
    elseif name == "stats" then
      out[#out + 1] = "L.stats = "
      ser(l, out)
      out[#out + 1] = "\n"
    end
  end
  out[#out + 1] = "return L\n"
  return table.concat(out)
end
function M.deserialize(s)
  local f = (loadstring or load or function(c) local r = CompileString(c, "tinyatlas", false); return type(r) == "function" and r or nil end)(s)
  if not f then return nil end
  if setfenv then setfenv(f, {}) end
  local ok, v = pcall(f)
  if ok and type(v) == "table" then return v end
end
function M.cache_path(tx, ty)
  return string.format("ovl/%s-%d/14/%d_%d.lua", ATLAS_REQUIRE("overture").RELEASE, M.VERSION, tx, ty)
end

return M
