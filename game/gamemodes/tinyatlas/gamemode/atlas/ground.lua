-- Heights for a built cell: terrain from the elevation tiles, roads flattened across their width, water level.
-- Shared by every game.
--
--   ground.heights(r, H, gx0, gy0, opts) -> g
--   r        cell.build result (points, triangles, surfaces, shapes)
--   H        height.lua instance holding the elevation tiles around the cell
--   gx0, gy0 the cell's origin in global units
--   g = { land = { [v] = metres }, water = { [v] = metres, only where the point touches water },
--         walls = { {a, b} edges between water and land, land side on the left }, problems, stats }
local cell = ATLAS_REQUIRE("cell")
local floor, sqrt, min, max, abs = math.floor, math.sqrt, math.min, math.max, math.abs

local M = {}

local ROADLIKE, WATER = cell.ROADLIKE, cell.WATER
local NXT = { 2, 3, 1 }
local MAX_GRADE = { road = 0.18, cycleway = 0.18, road_unpaved = 0.25, rail = 0.06, track = 0.3, path = 0.4,
  path_unpaved = 0.4 }

-- road centre lines with smoothed heights, and a bucket grid over their segments
local function centrelines(r, H, gx0, gy0, mpu)
  local step = 6 / mpu                              -- sample every 6 m along each line
  local win = 25 / mpu                              -- smooth over +-25 m
  local S = r.S
  local lines = {}
  for _, sh in ipairs(r.shapes) do
    if sh.lines and ROADLIKE[sh.surf] then
      -- only the parts of the line that can matter for this cell: within half width + slack + one sample + the
      -- smoothing window of it. Runs start at the line's own vertices, so the neighbouring cell samples the same
      -- places and computes the same heights for the points both share.
      local m = sh.width / 2 + (1.5 + 6 + 25 + 6) / mpu       -- sh.width is in cell units
      for _, L in ipairs(sh.lines) do
        local k = 1
        while k < L.n do
          -- skip segments far from the cell
          while k < L.n do
            local ax, ay, bx, by = L.xs[k], L.ys[k], L.xs[k + 1], L.ys[k + 1]
            if max(ax, bx) >= -m and min(ax, bx) <= S + m and max(ay, by) >= -m and min(ay, by) <= S + m then break end
            k = k + 1
          end
          if k >= L.n then break end
          local k0 = k
          while k < L.n do
            local ax, ay, bx, by = L.xs[k], L.ys[k], L.xs[k + 1], L.ys[k + 1]
            if not (max(ax, bx) >= -m and min(ax, bx) <= S + m and max(ay, by) >= -m and min(ay, by) <= S + m) then break end
            k = k + 1
          end
          local k1 = k                                -- segments k0 .. k1 - 1, vertices k0 .. k1
        -- densify, keeping the distance along the line
        local xs, ys, ds, hs = {}, {}, {}, {}
        local n, d = 1, 0
        xs[1], ys[1], ds[1] = L.xs[k0], L.ys[k0], 0
        for j = k0 + 1, k1 do
          local dx, dy = L.xs[j] - L.xs[j - 1], L.ys[j] - L.ys[j - 1]
          local len = sqrt(dx * dx + dy * dy)
          local parts = max(1, floor(len / step))
          for p = 1, parts do
            local t = p / parts
            n = n + 1
            xs[n], ys[n] = L.xs[j - 1] + dx * t, L.ys[j - 1] + dy * t
            ds[n] = d + len * t
          end
          d = d + len
        end
        for j = 1, n do hs[j] = H:at(gx0 + xs[j], gy0 + ys[j]) end
        -- fill dips shorter than about 40 m along the road (a closing: highest within +-20 m, then lowest of that):
        -- the elevation data is bare earth, so under a bridge that is not mapped as one it shows the gap below
        local cw = 20 / mpu
        local function window_pass(src, pick)
          local out = {}
          local lo2 = 1
          for j = 1, n do
            while ds[lo2] < ds[j] - cw do lo2 = lo2 + 1 end
            local v = src[j]
            local q = lo2
            while q <= n and ds[q] <= ds[j] + cw do
              local h = src[q]
              if h and (not v or pick(h, v)) then v = h end
              q = q + 1
            end
            out[j] = v
          end
          return out
        end
        hs = window_pass(window_pass(hs, function(a, b) return a > b end), function(a, b) return a < b end)
        -- smoothing over the distance window (two pointers): a straight-line fit through the window's heights,
        -- so a steady slope stays exact up to the very end of a line (a plain average would bend it there)
        local sm = {}
        local lo, hi, c, sd, sdd, sh_, sdh = 1, 0, 0, 0, 0, 0, 0
        for j = 1, n do
          while hi < n and ds[hi + 1] <= ds[j] + win do
            hi = hi + 1
            local h = hs[hi]
            if h then local d = ds[hi]; c = c + 1; sd = sd + d; sdd = sdd + d * d; sh_ = sh_ + h; sdh = sdh + d * h end
          end
          while ds[lo] < ds[j] - win do
            local h = hs[lo]
            if h then local d = ds[lo]; c = c - 1; sd = sd - d; sdd = sdd - d * d; sh_ = sh_ - h; sdh = sdh - d * h end
            lo = lo + 1
          end
          if c >= 3 then
            local md, mh = sd / c, sh_ / c
            local var = sdd / c - md * md
            local slope = var > 1e-6 and (sdh / c - md * mh) / var or 0
            sm[j] = mh + slope * (ds[j] - md)
          elseif c > 0 then sm[j] = sh_ / c
          else sm[j] = hs[j] end
        end
        lines[#lines + 1] = { xs = xs, ys = ys, hs = sm, n = n, half = sh.width / 2, start = k0 == 1, stop = k1 == L.n }
        end
      end
    end
  end
  -- bucket grid over the segments, only over the cell itself (queries are points of the cell), each segment
  -- padded by its half width plus the slack road_height allows
  local B = 1024
  local slack = 1.5 / mpu
  local nb = floor(S / B)
  local grid = {}
  for li, L in ipairs(lines) do
    local pad = L.half + slack
    for k = 1, L.n - 1 do
      local ax, ay, bx, by = L.xs[k], L.ys[k], L.xs[k + 1], L.ys[k + 1]
      local x0, x1 = floor((min(ax, bx) - pad) / B), floor((max(ax, bx) + pad) / B)
      local y0, y1 = floor((min(ay, by) - pad) / B), floor((max(ay, by) + pad) / B)
      if x0 < 0 then x0 = 0 end
      if y0 < 0 then y0 = 0 end
      if x1 > nb then x1 = nb end
      if y1 > nb then y1 = nb end
      for yb = y0, y1 do
        for xb = x0, x1 do
          local kk = yb * 64 + xb
          local G = grid[kk]
          if not G then G = { n = 0 }; grid[kk] = G end
          local n = G.n
          G[n + 1] = li; G[n + 2] = k
          G.n = n + 2
        end
      end
    end
  end
  -- which lines meet (a junction): their centre lines cross, or one ends on the other. Lines that are only close
  -- (the two legs of a hairpin) do not meet, so their heights are not mixed.
  local conn = {}
  for i = 1, #lines do conn[i] = { [i] = true } end
  local tol = 1.5 / mpu
  local function seg_dist(px, py, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local l2 = dx * dx + dy * dy
    local t = l2 > 0 and ((px - ax) * dx + (py - ay) * dy) / l2 or 0
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    return sqrt((px - ax - dx * t) ^ 2 + (py - ay - dy * t) ^ 2)
  end
  for _, G in pairs(grid) do
    for a = 1, G.n, 2 do
      local li, k = G[a], G[a + 1]
      local L = lines[li]
      local ax, ay, bx, by = L.xs[k], L.ys[k], L.xs[k + 1], L.ys[k + 1]
      for b = a + 2, G.n, 2 do
        local lj, m = G[b], G[b + 1]
        if lj ~= li and not conn[li][lj] then
          local K = lines[lj]
          local cx, cy, dx, dy = K.xs[m], K.ys[m], K.xs[m + 1], K.ys[m + 1]
          local meet = false
          local rx, ry, sx, sy = bx - ax, by - ay, dx - cx, dy - cy
          local den = rx * sy - ry * sx
          if den ~= 0 then
            local t = ((cx - ax) * sy - (cy - ay) * sx) / den
            local u = ((cx - ax) * ry - (cy - ay) * rx) / den
            meet = t >= 0 and t <= 1 and u >= 0 and u <= 1
          end
          if not meet then
            -- line ends (only the real ends of a line, not where a run was cut off)
            if (k == 1 and L.start) or (k + 1 == L.n and L.stop) then
              local px, py = k == 1 and ax or bx, k == 1 and ay or by
              meet = seg_dist(px, py, cx, cy, dx, dy) < tol
            end
            if not meet and ((m == 1 and K.start) or (m + 1 == K.n and K.stop)) then
              local px, py = m == 1 and cx or dx, m == 1 and cy or dy
              meet = seg_dist(px, py, ax, ay, bx, by) < tol
            end
          end
          if meet then conn[li][lj] = true; conn[lj][li] = true end
        end
      end
    end
  end
  lines.conn = conn
  return lines, grid, B
end

-- road height at a point: the heights of every road centre line within its half width (+ slack), blended by
-- distance, so roads that meet at a junction share their heights there; nil if no road is near
local function road_height(lines, grid, B, x, y, slack)
  local G = grid[floor(y / B) * 64 + floor(x / B)]
  if not G then return nil end
  local sw, sh = 0, 0
  local seen = {}
  for i = 1, G.n, 2 do
    local li, k = G[i], G[i + 1]
    local L = lines[li]
    local ax, ay, bx, by = L.xs[k], L.ys[k], L.xs[k + 1], L.ys[k + 1]
    local dx, dy = bx - ax, by - ay
    local l2 = dx * dx + dy * dy
    local t = l2 > 0 and ((x - ax) * dx + (y - ay) * dy) / l2 or 0
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    local px, py = ax + dx * t, ay + dy * t
    local d = sqrt((x - px) ^ 2 + (y - py) ^ 2)
    if d <= L.half + slack then
      local h0, h1 = L.hs[k], L.hs[k + 1]
      if h0 and h1 then
        -- one contribution per line: its nearest segment
        local prev = seen[li]
        if not prev or d < prev[1] then
          seen[li] = { d, h0 + (h1 - h0) * t }
        end
      end
    end
  end
  -- the nearest line decides; lines that meet it (a junction) are blended in, so roads that join share heights.
  -- Lines that are only close (the other leg of a hairpin) are left out.
  local best, bl
  for li, e in pairs(seen) do if not best or e[1] < best[1] then best, bl = e, li end end
  if not best then return nil end
  local meets = lines.conn[bl]
  for li, e in pairs(seen) do
    if meets[li] then
      local w = 1 / (e[1] + 1)
      sw = sw + w; sh = sh + w * e[2]
    end
  end
  if sw == 0 then return nil end
  if M.debug then M.debug.last = { seen = seen, best = bl } end
  return sh / sw
end

-- level of a lake, pond, canal or river polygon: a low percentile of the elevation inside it, found once per map
-- feature (by its OSM id, so every cell and every tile that has a piece of it uses the same level). Polygons whose
-- elevation spreads a lot run downhill (rivers in the mountains): those are "flowing" and get local levels.
local function own_level(f, H, tgx, tgy, mpu)
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
  local x0, y0, x1, y1 = bb[1], bb[2], bb[3], bb[4]
  local tu = 16 * mpu                                 -- metres per tile unit
  local step = max((x1 - x0) / 32, (y1 - y0) / 32, 4 / tu)
  local vals, nv = {}, 0
  local xs = {}
  for row = 0, floor((y1 - y0) / step) do
    local y = y0 + (row + 0.5) * step
    if y > y1 then break end
    local nx = 0
    for _, part in ipairs(f.parts) do
      local n = #part
      for k = 1, n - 2, 2 do
        local ax, ay, bx, by = part[k], part[k + 1], part[k + 2], part[k + 3]
        if (ay > y) ~= (by > y) then
          nx = nx + 1
          xs[nx] = ax + (y - ay) / (by - ay) * (bx - ax)
        end
      end
      -- rings may or may not repeat their first point; close them
      local ax, ay, bx, by = part[n - 1], part[n], part[1], part[2]
      if (ax ~= bx or ay ~= by) and (ay > y) ~= (by > y) then
        nx = nx + 1
        xs[nx] = ax + (y - ay) / (by - ay) * (bx - ax)
      end
    end
    for k = nx + 1, #xs do xs[k] = nil end
    table.sort(xs)
    for k = 1, nx - 1, 2 do
      local a, b = xs[k], xs[k + 1]
      local c0 = math.ceil((a - x0) / step - 0.5)
      for col = c0, floor((b - x0) / step - 0.5) do
        local x = x0 + (col + 0.5) * step
        local h = H:at(tgx + x * 16, tgy + y * 16)
        if h then nv = nv + 1; vals[nv] = h end
      end
    end
  end
  if nv == 0 then return nil end
  table.sort(vals)
  local lo, hi = vals[floor(nv * 0.15) + 1], vals[floor(nv * 0.85) + 1]
  return { level = lo - 0.2, flowing = hi - lo > 2.5, samples = nv }
end

-- Water polygons of one tile that share a corner are one body of water (OSM splits big water areas into pieces):
-- every standing piece of a group gets the group's lowest level. Done once per tile; levels are remembered per
-- feature id for the whole session, so cells of other tiles reuse them.
local function tile_levels(layer, H, tgx, tgy, mpu)
  local cache = H.levels
  if not cache then cache = {}; H.levels = cache end
  if layer._levels_done then return cache end
  layer._levels_done = true
  local feats = {}
  for _, f in ipairs(layer.features) do
    if f.type == 3 and f.props.class ~= "ocean" and f.props.brunnel ~= "tunnel" then feats[#feats + 1] = f end
  end
  local parent = {}
  local function find(i) while parent[i] ~= i do parent[i] = parent[parent[i]]; i = parent[i] end return i end
  local at = {}
  for i, f in ipairs(feats) do
    parent[i] = i
    for _, part in ipairs(f.parts) do
      for k = 1, #part, 2 do
        local key = part[k] * 65536 + part[k + 1]
        local j = at[key]
        if j then local a, b = find(i), find(j); if a ~= b then parent[a] = b end
        else at[key] = i end
      end
    end
  end
  local own, low = {}, {}
  for i, f in ipairs(feats) do
    local key = f.props.id or f
    if cache[key] == nil then
      own[i] = own_level(f, H, tgx, tgy, mpu) or false
      local o = own[i]
      if o and not o.flowing then
        local g = find(i)
        if not low[g] or o.level < low[g] then low[g] = o.level end
      end
    end
  end
  for i, f in ipairs(feats) do
    local key = f.props.id or f
    local o = own[i]
    if o ~= nil then
      if o and not o.flowing then o.level = low[find(i)] end
      cache[key] = o
    end
  end
  return cache
end

local function feature_level(f, levels)
  local v = levels[f.props.id or f]
  return v or nil
end

function M.heights(r, H, gx0, gy0, opts)
  opts = opts or {}
  local tick = opts.tick or function() end
  local X, Y, V, N, surf, nt = r.X, r.Y, r.V, r.N, r.surf, r.nt
  local mpu = r.mpu
  local problems, stats = {}, {}

  -- which points touch water, which touch a road; the level each water triangle wants
  local tgx, tgy = gx0 - r.cx * 8192, gy0 - r.cy * 8192   -- the zoom-14 tile's origin, for its features
  local r_water = 50 / mpu
  local wet, roady, used, tri_level, flowing_tri = {}, {}, {}, {}, {}
  local levels = r.water_layer and tile_levels(r.water_layer, H, tgx, tgy, mpu) or {}
  for t = 1, nt do
    local o = 3 * t - 3
    local s = surf[t]
    if WATER[s] then
      if s == "sea" then tri_level[t] = 0
      elseif s == "water" then
        local a, b, c = V[o + 1], V[o + 2], V[o + 3]
        -- overlapping polygons (a basin mapped inside a canal): the lowest level wins
        local lv, flow
        for _, sh in ipairs(r.water_shapes_at((X[a] + X[b] + X[c]) / 3, (Y[a] + Y[b] + Y[c]) / 3)) do
          local info = feature_level(sh.feature, levels)
          if not info or info.flowing then flow = true
          elseif not lv or info.level < lv then lv = info.level end
        end
        if lv and not flow then tri_level[t] = lv else flowing_tri[t] = true end
      else flowing_tri[t] = true end
    end
    for i = 1, 3 do
      local v = V[o + i]
      used[v] = true
      if WATER[s] then
        local lv = tri_level[t]
        if lv then
          local cur = wet[v]
          if cur == nil or cur == true or lv < cur then wet[v] = lv end
        elseif wet[v] == nil then wet[v] = true            -- local level (streams, rivers that run downhill)
        end
      end
      if ROADLIKE[s] then roady[v] = true end
    end
  end

  local lines, grid, B = centrelines(r, H, gx0, gy0, mpu)
  tick()
  local land, water = {}, {}
  local missing = 0
  local n = 0
  for v in pairs(used) do
    n = n + 1
    if n % 64 == 0 then tick() end
    local gx, gy = gx0 + X[v], gy0 + Y[v]
    local h = H:at(gx, gy)
    if not h then missing = missing + 1; h = 0 end
    if roady[v] then
      local rh = road_height(lines, grid, B, X[v], Y[v], 1.5 / mpu)
      if M.debug and rh then M.debug[v] = M.debug.last; M.debug.lines = lines end
      if rh then h = rh end
    end
    if wet[v] ~= nil then
      local lvl = wet[v]
      if lvl == true then lvl = (H:water_level(gx, gy, r_water) or h) - 0.3 end
      water[v] = lvl
      if h < lvl + 0.3 then h = lvl + 0.3 end            -- banks stay above the water
    end
    land[v] = h
  end
  if missing > 0 then problems[#problems + 1] = missing .. " points without elevation data" end

  -- smooth road heights along the road surface: removes steps where roads with slightly different heights meet
  -- and where a point at a road's edge fell back to the terrain
  local nbr = {}
  local S = r.S
  -- points on the cell's border are never moved: the neighbouring cell computes the same height for them
  local function border(v) local x, y = X[v], Y[v]; return x == 0 or y == 0 or x == S or y == S end
  for t = 1, nt do
    if ROADLIKE[surf[t]] then
      local o = 3 * t - 3
      for i = 1, 3 do
        local a, b = V[o + i], V[o + NXT[i]]
        if roady[a] and roady[b] and wet[a] == nil and wet[b] == nil and not border(a) and not border(b) then
          local L = nbr[a]; if not L then L = {}; nbr[a] = L end
          L[#L + 1] = b
          local Lb = nbr[b]; if not Lb then Lb = {}; nbr[b] = Lb end
          Lb[#Lb + 1] = a
        end
      end
    end
  end
  local before = {}
  for v in pairs(nbr) do before[v] = land[v] end
  for _ = 1, 8 do
    tick()
    local nh = {}
    for v, L in pairs(nbr) do
      local sw, sh = 0, 0
      for k = 1, #L do
        local u = L[k]
        local d = sqrt((X[u] - X[v]) ^ 2 + (Y[u] - Y[v]) ^ 2) * mpu
        local w = 1 / (d + 0.5)
        sw = sw + w; sh = sh + w * land[u]
      end
      nh[v] = 0.5 * land[v] + 0.5 * sh / sw
    end
    for v, h in pairs(nh) do land[v] = h end
  end
  -- smoothing may move a point only a little: points on the cell border never move, so a large move would leave
  -- a step against the neighbouring cell
  for v, h0 in pairs(before) do
    local h = land[v]
    if h > h0 + 0.25 then land[v] = h0 + 0.25 elseif h < h0 - 0.25 then land[v] = h0 - 0.25 end
  end

  -- quay walls / banks: edges where a water triangle meets a land triangle (the cell border is not a wall)
  local walls = {}
  for t = 1, nt do
    if not WATER[surf[t]] then
      local o = 3 * t - 3
      for i = 1, 3 do
        local u = N[o + i]
        if u and WATER[surf[u]] then
          walls[#walls + 1] = { V[o + i], V[o + NXT[i]] }   -- land triangle's edge: water is on its right
        end
      end
    end
  end

  -- checks: water level steadiness per connected water area, road slopes
  local seen, worst_water, regions = {}, 0, 0
  for t = 1, nt do
    if WATER[surf[t]] and not seen[t] then
      regions = regions + 1
      local lo, hi, stack, sn = 1e9, -1e9, { t }, 1
      local flowing = false
      seen[t] = true
      while sn > 0 do
        local u = stack[sn]; sn = sn - 1
        local o = 3 * u - 3
        if flowing_tri[u] then flowing = true end
        for i = 1, 3 do
          local h = water[V[o + i]]
          if h < lo then lo = h end
          if h > hi then hi = h end
          local w = N[o + i]
          if w and WATER[surf[w]] and not seen[w] then seen[w] = true; sn = sn + 1; stack[sn] = w end
        end
      end
      -- streams and mountain rivers run downhill; lakes, canals and the sea should be level within the cell
      if not flowing and hi - lo > worst_water then worst_water = hi - lo end
    end
  end
  stats.water_areas, stats.water_range = regions, worst_water
  if worst_water > 1.5 then problems[#problems + 1] = string.format("standing water not level (%.1f m)", worst_water) end

  -- roads a car or bike uses must stay under 30 %; paths and tracks may be steep (hiking trails), rail is not ridden
  local LIMIT = { road = 0.30, road_unpaved = 0.30, cycleway = 0.30 }
  local steep, worst_slope, steep_area, road_area = 0, 0, 0, 0
  for t = 1, nt do
    if LIMIT[surf[t]] then
      local o = 3 * t - 3
      local a, b, c = V[o + 1], V[o + 2], V[o + 3]
      local ux, uy, uz = (X[b] - X[a]) * mpu, (Y[b] - Y[a]) * mpu, land[b] - land[a]
      local vx, vy, vz = (X[c] - X[a]) * mpu, (Y[c] - Y[a]) * mpu, land[c] - land[a]
      local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
      local horiz = sqrt(nx * nx + ny * ny)
      local slope = abs(nz) > 1e-9 and horiz / abs(nz) or 0
      -- |n_z| is twice the triangle's area in square metres; small slivers say nothing about the ride
      road_area = road_area + abs(nz) / 2
      if abs(nz) > 4.0 then
        if slope > worst_slope then worst_slope = slope end
        if slope > LIMIT[surf[t]] then steep = steep + 1; steep_area = steep_area + abs(nz) / 2 end
      end
    end
  end
  stats.road_worst_slope, stats.road_steep_triangles = worst_slope, steep
  -- hairpin inner edges are really that steep; flag the cell only when much of its road is
  stats.road_steep_share = road_area > 0 and steep_area / road_area or 0
  stats.road_steep_area = steep_area
  -- a few square metres where a path beside the road sits lower on the slope are not a problem
  if stats.road_steep_share > 0.05 and steep_area > 60 then
    problems[#problems + 1] = string.format("%.0f %% of the road area (%.0f m2) steeper than allowed", stats.road_steep_share * 100, steep_area)
  end
  stats.walls = #walls
  return { land = land, water = water, walls = walls, problems = problems, stats = stats }
end

return M
