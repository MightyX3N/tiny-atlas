-- Builds the ground of one cell: every point gets exactly one surface (road, water, building, grass, ...).
-- Shared by every game.
--
-- A cell is one zoom-17 tile, i.e. an 8 x 8 part of a zoom-14 vector tile (about 300 m at the equator, 175 m at
-- 55 degrees north). Coordinates inside a cell are integers 0..8192 (1/16 of a vector tile unit, ~2-4 cm).
--
-- Steps: collect shapes from the vector tile (polygons as they are; roads as quads along each segment with
-- bevelled joints) -> cut all their edges against each other (splitting at crossings, snapped to the grid)
-- -> constrained triangulation -> label each region (the area between constraint edges) with the
-- highest-priority shape covering it -> drop edges between equal surfaces and restore Delaunay.
--
--   cell.build(layers, cx, cy, lat, opts) -> result
--   result = { S, X, Y, V (3 per triangle), nt, surf (per triangle: surface name), stats, problems }
local cdt = ATLAS_REQUIRE("cdt")
local floor, sqrt, abs, min, max = math.floor, math.sqrt, math.abs, math.min, math.max

local M = {}

local S = 8192          -- cell size in cell units
local SCALE = 16        -- cell units per vector tile unit
M.S = S

-- surfaces a rider can be on (roads are flattened across their width)
M.ROADLIKE = { road = true, road_unpaved = true, cycleway = true, path = true, path_unpaved = true, track = true,
  rail = true }
M.WATER = { water = true, sea = true }

-- surfaces and their priority (higher wins where shapes overlap)
M.PRIORITY = {
  building = 90, road = 80, road_unpaved = 79, cycleway = 78, path = 77, path_unpaved = 77, rail = 76, track = 75,
  pier = 74, water = 70, sea = 70, paved = 60,
  sand = 45, wetland = 44, wood = 40, park = 32, grass = 30, pitch = 34, cemetery = 26, farmland = 20,
  rock = 18, ice = 18, residential = 10, commercial = 12, industrial = 12, ground = 0,
}

-- road widths in metres by OpenMapTiles transportation class
local ROAD_W = { motorway = 22, trunk = 18, primary = 14, secondary = 12, tertiary = 10, minor = 8, service = 5,
  track = 3, path = 2.5, raceway = 10, busway = 7, bus_guideway = 4, motorway_construction = 0 }
local WATERWAY_W = { river = 10, canal = 8, stream = 2, ditch = 1.5, drain = 1.5 }

local LANDCOVER = { wood = "wood", grass = "grass", farmland = "farmland", wetland = "wetland", sand = "sand",
  rock = "rock", ice = "ice" }
local LANDUSE = { residential = "residential", commercial = "commercial", retail = "commercial", industrial = "industrial",
  cemetery = "cemetery", pitch = "pitch", playground = "park", stadium = "pitch", garages = "paved",
  railway = "industrial", school = "residential", university = "residential", hospital = "residential",
  quarry = "rock", military = "grass", kindergarten = "residential", college = "residential" }

-- metres per cell unit at latitude lat (zoom-14 tile = 4096 vector units)
function M.metres_per_unit(lat)
  return 40075016.686 * math.cos(math.rad(lat)) / 16384 / 4096 / SCALE
end

---------------------------------------------------------------------------------------------------------------
-- shapes

-- shape = { surf, prio, kind = "evenodd" | "union", rings = { flat arrays in cell units }, x0, y0, x1, y1 }
local function new_shape(surf, kind)
  return { surf = surf, prio = M.PRIORITY[surf] or 0, kind = kind, rings = {}, x0 = 1e18, y0 = 1e18, x1 = -1e18, y1 = -1e18 }
end

-- Sutherland-Hodgman clip of a closed ring to the box [lo, hi]^2. For points inside the box, being inside the
-- clipped ring is the same as being inside the original, so far-away parts of big polygons can be dropped.
local function clip_ring(r, lo, hi)
  local inside = true
  for k = 1, #r, 2 do
    local x, y = r[k], r[k + 1]
    if x < lo or x > hi or y < lo or y > hi then inside = false; break end
  end
  if inside then return r end
  local pts = {}
  for k = 1, #r - 2, 2 do pts[#pts + 1] = r[k]; pts[#pts + 1] = r[k + 1] end    -- open ring
  local function pass(P, inside_fn, cut)
    local out = {}
    local n = #P
    if n == 0 then return out end
    local sx, sy = P[n - 1], P[n]
    local sin = inside_fn(sx, sy)
    for k = 1, n, 2 do
      local ex, ey = P[k], P[k + 1]
      local ein = inside_fn(ex, ey)
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
  local function cutx(v) return function(ax, ay, bx, by) local t = (v - ax) / (bx - ax); return v, ay + t * (by - ay) end end
  local function cuty(v) return function(ax, ay, bx, by) local t = (v - ay) / (by - ay); return ax + t * (bx - ax), v end end
  pts = pass(pts, function(x) return x >= lo end, cutx(lo))
  pts = pass(pts, function(x) return x <= hi end, cutx(hi))
  pts = pass(pts, function(_, y) return y >= lo end, cuty(lo))
  pts = pass(pts, function(_, y) return y <= hi end, cuty(hi))
  if #pts < 6 then return nil end
  pts[#pts + 1] = pts[1]; pts[#pts + 1] = pts[2]
  return pts
end

local function add_ring(sh, r)
  r = clip_ring(r, -16, S + 16)
  if not r then return end
  sh.rings[#sh.rings + 1] = r
  for k = 1, #r, 2 do
    local x, y = r[k], r[k + 1]
    if x < sh.x0 then sh.x0 = x end
    if x > sh.x1 then sh.x1 = x end
    if y < sh.y0 then sh.y0 = y end
    if y > sh.y1 then sh.y1 = y end
  end
end

-- polygon feature (tile units) -> shape in cell units, snapped to the grid
local function polygon_shape(f, surf, ox, oy)
  local sh = new_shape(surf, "evenodd")
  for _, part in ipairs(f.parts) do
    local r = {}
    for k = 1, #part, 2 do
      r[k] = floor((part[k] - ox) * SCALE + 0.5)
      r[k + 1] = floor((part[k + 1] - oy) * SCALE + 0.5)
    end
    if #r >= 8 then add_ring(sh, r) end
  end
  return sh
end

-- line feature -> union of quads (one per segment) and bevel triangles at the joints, width w in cell units
local function line_shape(f, surf, ox, oy, w)
  local sh = new_shape(surf, "union")
  sh.lines, sh.width = {}, w
  local h = w / 2
  for _, part in ipairs(f.parts) do
    local xs, ys, n = {}, {}, 0
    for k = 1, #part, 2 do
      local x, y = (part[k] - ox) * SCALE, (part[k + 1] - oy) * SCALE
      if n == 0 or abs(x - xs[n]) + abs(y - ys[n]) > 0.5 then n = n + 1; xs[n] = x; ys[n] = y end
    end
    if n >= 2 then sh.lines[#sh.lines + 1] = { xs = xs, ys = ys, n = n } end
    local pnx, pny
    for k = 1, n - 1 do
      local dx, dy = xs[k + 1] - xs[k], ys[k + 1] - ys[k]
      local L = sqrt(dx * dx + dy * dy)
      local nx, ny = -dy / L * h, dx / L * h
      local q = {
        floor(xs[k] + nx + 0.5), floor(ys[k] + ny + 0.5), floor(xs[k + 1] + nx + 0.5), floor(ys[k + 1] + ny + 0.5),
        floor(xs[k + 1] - nx + 0.5), floor(ys[k + 1] - ny + 0.5), floor(xs[k] - nx + 0.5), floor(ys[k] - ny + 0.5),
      }
      q[9], q[10] = q[1], q[2]
      add_ring(sh, q)
      if pnx then
        -- bevel: triangle between the previous segment's end edge and this segment's start edge, on the outer side
        local cross = pnx * ny - pny * nx
        if abs(cross) > 1e-9 * h * h then
          local sgn = cross > 0 and -1 or 1
          local t = {
            floor(xs[k] + 0.5), floor(ys[k] + 0.5),
            floor(xs[k] + sgn * pnx + 0.5), floor(ys[k] + sgn * pny + 0.5),
            floor(xs[k] + sgn * nx + 0.5), floor(ys[k] + sgn * ny + 0.5),
          }
          t[7], t[8] = t[1], t[2]
          add_ring(sh, t)
        end
      end
      pnx, pny = nx, ny
    end
  end
  return sh
end

-- which surface a vector tile feature makes, or nil
local function classify(layer, p, ftype)
  if layer == "water" then
    if p.brunnel == "tunnel" then return nil end
    if p.class == "swimming_pool" then return nil end
    return p.class == "ocean" and "sea" or "water", "poly"
  elseif layer == "building" then
    return "building", "poly"
  elseif layer == "landcover" then
    return LANDCOVER[p.class] or (p.subclass == "park" and "park") or nil, "poly"
  elseif layer == "landuse" then
    return LANDUSE[p.class], "poly"
  elseif layer == "park" then
    return "park", "poly"
  elseif layer == "aeroway" then
    if ftype == 3 then return "paved", "poly" end
    return nil
  elseif layer == "transportation" then
    if p.brunnel == "tunnel" or p.brunnel == "bridge" then return nil end   -- bridges are built separately
    if ftype == 3 then
      if p.class == "pier" then return "pier", "poly" end
      return nil
    end
    local c = p.class
    if c == "rail" or c == "transit" then
      if p.subclass == "subway" then return nil end
      return "rail", "line", 3
    end
    if c == "ferry" or c == "aerialway" then return nil end
    local w = ROAD_W[c]
    if not w or w == 0 then return nil end
    local unpaved = p.surface == "unpaved"
    if c == "path" then
      if p.subclass == "cycleway" then return "cycleway", "line", w end
      return unpaved and "path_unpaved" or "path", "line", w
    end
    if c == "track" then return "track", "line", w end
    return unpaved and "road_unpaved" or "road", "line", w
  elseif layer == "waterway" then
    if p.brunnel == "tunnel" then return nil end
    local w = WATERWAY_W[p.class]
    if w then return "water", "line", w end
  end
  return nil
end

local LAYERS = { "water", "waterway", "landcover", "landuse", "park", "aeroway", "building", "transportation" }

local function collect(layers, cx, cy, mpu, tick)
  local ox, oy = cx * 512, cy * 512              -- cell origin in tile units
  local m0, m1 = -64, S + 64                    -- keep shapes that come near the cell
  local shapes = {}
  for _, lname in ipairs(LAYERS) do
    local L = layers[lname]
    if L then
      if L.extent ~= 4096 then error("cell: unexpected vector tile extent " .. tostring(L.extent)) end
      for _, f in ipairs(L.features) do
        tick()
        local surf, how, wm = classify(lname, f.props, f.type)
        if surf and (f.type == 3 or how == "line") then
          -- quick reject on the feature's bounding box (computed once per tile, kept on the feature)
          local bb = f.bbox
          if not bb then
            local a0, b0, a1, b1 = 1e18, 1e18, -1e18, -1e18
            for _, part in ipairs(f.parts) do
              for k = 1, #part, 2 do
                local x, y = part[k], part[k + 1]
                if x < a0 then a0 = x end
                if x > a1 then a1 = x end
                if y < b0 then b0 = y end
                if y > b1 then b1 = y end
              end
            end
            bb = { a0, b0, a1, b1 }; f.bbox = bb
          end
          local x0, y0 = (bb[1] - ox) * SCALE, (bb[2] - oy) * SCALE
          local x1, y1 = (bb[3] - ox) * SCALE, (bb[4] - oy) * SCALE
          local pad = how == "line" and (wm / mpu) or 0
          if x1 + pad >= m0 and x0 - pad <= m1 and y1 + pad >= m0 and y0 - pad <= m1 then
            local sh
            if how == "poly" then sh = polygon_shape(f, surf, ox, oy)
            elseif f.type == 2 then sh = line_shape(f, surf, ox, oy, wm / mpu) end
            if sh and #sh.rings > 0 then shapes[#shapes + 1] = sh end
          end
        end
      end
    end
  end
  return shapes
end

---------------------------------------------------------------------------------------------------------------
-- segments: clip to the cell, snap, split at crossings and touching points

-- Liang-Barsky clip of segment to [0, S]^2
local function clip(x1, y1, x2, y2)
  local t0, t1 = 0, 1
  local dx, dy = x2 - x1, y2 - y1
  local p = { -dx, dx, -dy, dy }
  local q = { x1, S - x1, y1, S - y1 }
  for i = 1, 4 do
    if p[i] == 0 then
      if q[i] < 0 then return nil end
    else
      local r = q[i] / p[i]
      if p[i] < 0 then if r > t1 then return nil elseif r > t0 then t0 = r end
      else if r < t0 then return nil elseif r < t1 then t1 = r end end
    end
  end
  return x1 + t0 * dx, y1 + t0 * dy, x1 + t1 * dx, y1 + t1 * dy
end

local function snap(v)
  v = floor(v + 0.5)
  if v < 0 then return 0 elseif v > S then return S end
  return v
end

local orient = cdt.orient

-- round n / d to the nearest integer (halves up), exactly, for integers |n|, |d| < 2^52; clamp to the cell
local function snap_ratio(n, d)
  if d < 0 then n, d = -n, -d end
  local nn, dd = 2 * n + d, 2 * d                  -- floor((2n + d) / 2d) = floor(n / d + 1/2)
  local q = floor(nn / dd)
  if q * dd > nn then q = q - 1 elseif (q + 1) * dd <= nn then q = q + 1 end
  if q < 0 then return 0 elseif q > S then return S end
  return q
end

-- Snap rounding (Hobby): crossings of the input segments become grid points; every point owns the unit square
-- around it (a "hot pixel"), and each segment is routed through every hot pixel it passes. The result has no
-- crossings left: edges only meet at shared points, or coincide (and duplicates are dropped).
local function split_all(T, SA, SB, problems, tick)
  local X, Y = T.X, T.Y
  local B = 256
  local NB = S / B
  local ns = #SA
  -- 1. crossings
  local buckets = {}
  for s = 1, ns do
    local a, b = SA[s], SB[s]
    local bx0, bx1 = floor(min(X[a], X[b]) / B), min(NB - 1, floor(max(X[a], X[b]) / B))
    local by0, by1 = floor(min(Y[a], Y[b]) / B), min(NB - 1, floor(max(Y[a], Y[b]) / B))
    for by = by0, by1 do
      for bx = bx0, bx1 do
        local k = by * NB + bx
        local L = buckets[k]
        if not L then L = {}; buckets[k] = L end
        L[#L + 1] = s
      end
    end
  end
  local seen, ncross = {}, 0
  for _, L in pairs(buckets) do
    tick()
    local n = #L
    for i = 1, n - 1 do
      local s = L[i]
      local a, b = SA[s], SB[s]
      local ax, ay, bx, by = X[a], Y[a], X[b], Y[b]
      local sx0, sx1, sy0, sy1 = min(ax, bx), max(ax, bx), min(ay, by), max(ay, by)
      for j = i + 1, n do
        local r = L[j]
        local c, d = SA[r], SB[r]
        local cx, cy, dx, dy = X[c], Y[c], X[d], Y[d]
        if max(cx, dx) >= sx0 and min(cx, dx) <= sx1 and max(cy, dy) >= sy0 and min(cy, dy) <= sy1 then
          local pk = s < r and (s * 1048576 + r) or (r * 1048576 + s)
          if not seen[pk] then
            seen[pk] = true
            local o1 = orient(ax, ay, bx, by, cx, cy)
            local o2 = orient(ax, ay, bx, by, dx, dy)
            if o1 * o2 < 0 then
              local o3 = orient(cx, cy, dx, dy, ax, ay)
              local o4 = orient(cx, cy, dx, dy, bx, by)
              if o3 * o4 < 0 then
                -- the crossing is (ax + o3 (bx - ax) / D, ...) with D = o3 - o4: round it exactly in integers, so
                -- a crossing on a pixel edge lands in the hot pixel that the half-open squares assign it to
                local D = o3 - o4
                cdt.point(T, snap_ratio(ax * D + o3 * (bx - ax), D), snap_ratio(ay * D + o3 * (by - ay), D))
                ncross = ncross + 1
              end
            end
          end
        end
      end
    end
  end
  -- 2. hot pixels, bucketed
  local H = 64
  local NH = S / H
  local hb = {}
  for p = 1, T.np do
    local k = min(NH - 1, floor(Y[p] / H)) * NH + min(NH - 1, floor(X[p] / H))
    local L = hb[k]
    if not L then L = {}; hb[k] = L end
    L[#L + 1] = p
  end
  local NA, NBs, keys = {}, {}, {}
  local function emit(p, q)
    if p == q then return end
    local k = p < q and (p * 1048576 + q) or (q * 1048576 + p)
    if keys[k] then return end
    keys[k] = true
    NA[#NA + 1] = p; NBs[#NBs + 1] = q
  end
  local hits, tpar = {}, {}
  local HI = 0.5 - 1e-7                          -- upper edge of a hot pixel, excluded (see below)
  for s = 1, ns do
    tick()
    local a, b = SA[s], SB[s]
    local ax, ay = X[a], Y[a]
    local dx, dy = X[b] - ax, Y[b] - ay
    local nh = 0
    local gx0, gx1 = max(0, floor((min(ax, ax + dx) - 1) / H)), min(NH - 1, floor((max(ax, ax + dx) + 1) / H))
    local gy0, gy1 = max(0, floor((min(ay, ay + dy) - 1) / H)), min(NH - 1, floor((max(ay, ay + dy) + 1) / H))
    for gy = gy0, gy1 do
      for gx = gx0, gx1 do
        local L = hb[gy * NH + gx]
        if L then
          for k = 1, #L do
            local p = L[k]
            if p ~= a and p ~= b then
              -- Liang-Barsky against the half-open square [x-0.5, x+0.5) x [y-0.5, y+0.5): every point of the
              -- plane belongs to exactly one hot pixel, matching snap(); closed squares let a segment through a
              -- shared corner visit up to four pixels and zigzag across other routed segments
              local px, py = X[p], Y[p]
              local t0, t1 = 0, 1
              local okp = true
              if dx == 0 then
                if ax < px - 0.5 or ax > px + HI then okp = false end
              else
                local ta, tb = (px - 0.5 - ax) / dx, (px + HI - ax) / dx
                if ta > tb then ta, tb = tb, ta end
                if ta > t0 then t0 = ta end
                if tb < t1 then t1 = tb end
              end
              if okp then
                if dy == 0 then
                  if ay < py - 0.5 or ay > py + HI then okp = false end
                else
                  local ta, tb = (py - 0.5 - ay) / dy, (py + HI - ay) / dy
                  if ta > tb then ta, tb = tb, ta end
                  if ta > t0 then t0 = ta end
                  if tb < t1 then t1 = tb end
                end
              end
              if okp and t0 <= t1 + 1e-12 then           -- slack for rounding where intervals meet at a corner
                nh = nh + 1; hits[nh] = p; tpar[p] = t0 + t1
              end
            end
          end
        end
      end
    end
    if nh == 0 then
      emit(a, b)
    else
      for k = nh + 1, #hits do hits[k] = nil end
      table.sort(hits, function(p, q) return tpar[p] < tpar[q] end)
      local prev = a
      for k = 1, nh do emit(prev, hits[k]); prev = hits[k] end
      emit(prev, b)
    end
  end
  for k = #SA, 1, -1 do SA[k] = nil; SB[k] = nil end
  for k = 1, #NA do SA[k] = NA[k]; SB[k] = NBs[k] end
  return ncross
end

---------------------------------------------------------------------------------------------------------------
-- point in shape

local function in_ring(r, x, y)
  local inside = false
  local n = #r
  local jx, jy = r[n - 1], r[n]
  for k = 1, n - 1, 2 do
    local ix, iy = r[k], r[k + 1]
    if (iy > y) ~= (jy > y) and x < (jx - ix) * (y - iy) / (jy - iy) + ix then inside = not inside end
    jx, jy = ix, iy
  end
  return inside
end

local function in_shape(sh, x, y)
  if x < sh.x0 or x > sh.x1 or y < sh.y0 or y > sh.y1 then return false end
  if sh.kind == "evenodd" then
    local inside = false
    for _, r in ipairs(sh.rings) do if in_ring(r, x, y) then inside = not inside end end
    return inside
  end
  for _, r in ipairs(sh.rings) do if in_ring(r, x, y) then return true end end
  return false
end

---------------------------------------------------------------------------------------------------------------

function M.build(layers, cx, cy, lat, opts)
  opts = opts or {}
  local clock = opts.clock or os.clock
  local stats, problems = {}, {}
  local t0 = clock()
  local mpu = M.metres_per_unit(lat)

  local tick = opts.tick or function() end
  local shapes = collect(layers, cx, cy, mpu, tick)
  table.sort(shapes, function(a, b) return a.prio > b.prio end)
  stats.shapes = #shapes
  local t1 = clock(); stats.ms_collect = (t1 - t0) * 1000

  -- segments from every ring, clipped and snapped; the cell border is a segment too
  local T = cdt.new(S)
  local SA, SB, keys = {}, {}, {}
  local function seg(x1, y1, x2, y2)
    local a, b, c, d = clip(x1, y1, x2, y2)
    if not a then return end
    local p, q = cdt.point(T, snap(a), snap(b)), cdt.point(T, snap(c), snap(d))
    if p == q then return end
    local k = p < q and (p * 1048576 + q) or (q * 1048576 + p)
    if keys[k] then return end
    keys[k] = true
    SA[#SA + 1] = p; SB[#SB + 1] = q
  end
  for _, sh in ipairs(shapes) do
    for _, r in ipairs(sh.rings) do
      for k = 1, #r - 3, 2 do seg(r[k], r[k + 1], r[k + 2], r[k + 3]) end
    end
  end
  stats.segments_in = #SA
  stats.crossings = split_all(T, SA, SB, problems, tick)
  stats.segments = #SA
  local t2 = clock(); stats.ms_split = (t2 - t1) * 1000

  T.tick = tick
  cdt.insert_points(T)
  local t3 = clock(); stats.ms_points = (t3 - t2) * 1000
  local fails = 0
  for s = 1, #SA do
    tick()
    if not cdt.constrain(T, SA[s], SB[s]) then fails = fails + 1 end
  end
  if fails > 0 then problems[#problems + 1] = fails .. " edges could not be forced into the triangulation" end
  stats.constraint_fails = fails
  local t4 = clock(); stats.ms_constrain = (t4 - t3) * 1000

  -- regions: flood fill across unconstrained edges; label each from its largest triangle's centroid
  local V, N, C, X, Y = T.V, T.N, T.C, T.X, T.Y
  local region, nreg = {}, 0
  local surf = {}
  local stack = {}
  -- bucket grid over shapes for the point queries
  local GB = 512
  local grid = {}
  for si, sh in ipairs(shapes) do
    for gy = max(0, floor(sh.y0 / GB)), min(S / GB - 1, floor(sh.y1 / GB)) do
      for gx = max(0, floor(sh.x0 / GB)), min(S / GB - 1, floor(sh.x1 / GB)) do
        local k = gy * 64 + gx
        local L = grid[k]
        if not L then L = {}; grid[k] = L end
        L[#L + 1] = si                             -- shapes are sorted by priority, so lists stay sorted
      end
    end
  end
  local function query(x, y)
    local gx, gy = min(S / GB - 1, max(0, floor(x / GB))), min(S / GB - 1, max(0, floor(y / GB)))
    local L = grid[gy * 64 + gx]
    if L then
      for _, si in ipairs(L) do
        local sh = shapes[si]
        if in_shape(sh, x, y) then return sh.surf end
      end
    end
    return "ground"
  end
  for t = 1, T.nt do
    tick()
    if not region[t] then
      nreg = nreg + 1
      local best, barea = t, -1
      local members, nm = {}, 0
      stack[1] = t; local sn = 1
      region[t] = nreg
      while sn > 0 do
        local u = stack[sn]; sn = sn - 1
        nm = nm + 1; members[nm] = u
        local o = 3 * u - 3
        local a, b, c = V[o + 1], V[o + 2], V[o + 3]
        local ar = orient(X[a], Y[a], X[b], Y[b], X[c], Y[c])
        if ar > barea then best, barea = u, ar end
        for i = 1, 3 do
          local w = N[o + i]
          if w and not C[o + i] and not region[w] then region[w] = nreg; sn = sn + 1; stack[sn] = w end
        end
      end
      local o = 3 * best - 3
      local a, b, c = V[o + 1], V[o + 2], V[o + 3]
      local s = query((X[a] + X[b] + X[c]) / 3, (Y[a] + Y[b] + Y[c]) / 3)
      for k = 1, nm do surf[members[k]] = s end
    end
  end
  stats.regions = nreg
  local t5 = clock(); stats.ms_label = (t5 - t4) * 1000

  -- drop constraints between equal surfaces (keep the cell border) and restore Delaunay
  if not opts.keep_edges then
    for t = 1, T.nt do
      local o = 3 * t - 3
      for i = 1, 3 do
        local u = N[o + i]
        if u and C[o + i] and surf[u] == surf[t] then C[o + i] = false end
      end
    end
    -- flips move triangles between regions only within one surface, so labels stay valid: a flip happens only
    -- across an unconstrained edge, whose two triangles have the same surface
    cdt.delaunay(T)
  end
  local t6 = clock(); stats.ms_clean = (t6 - t5) * 1000
  stats.ms_total = (t6 - t0) * 1000
  stats.points = T.np
  stats.triangles = T.nt

  for _, msg in ipairs(cdt.check(T)) do problems[#problems + 1] = msg end
  for t = 1, T.nt do
    if not surf[t] then problems[#problems + 1] = "triangle without a surface"; break end
  end
  return { S = S, X = X, Y = Y, V = V, C = C, N = T.N, nt = T.nt, np = T.np, surf = surf, stats = stats,
    problems = problems, mpu = mpu, shapes = shapes, cx = cx, cy = cy }
end

M._split_all = split_all          -- for tests
return M
