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
  local lines = {}
  for _, sh in ipairs(r.shapes) do
    if sh.lines and ROADLIKE[sh.surf] then
      for _, L in ipairs(sh.lines) do
        -- densify, keeping the distance along the line
        local xs, ys, ds, hs = {}, {}, {}, {}
        local n, d = 0, 0
        for k = 1, L.n do
          if k > 1 then
            local dx, dy = L.xs[k] - L.xs[k - 1], L.ys[k] - L.ys[k - 1]
            local len = sqrt(dx * dx + dy * dy)
            local parts = max(1, floor(len / step))
            for p = 1, parts do
              local t = p / parts
              n = n + 1
              xs[n], ys[n] = L.xs[k - 1] + dx * t, L.ys[k - 1] + dy * t
              ds[n] = d + len * t
            end
            d = d + len
          else
            n = 1; xs[1], ys[1], ds[1] = L.xs[1], L.ys[1], 0
          end
        end
        for k = 1, n do hs[k] = H:at(gx0 + xs[k], gy0 + ys[k]) end
        -- moving average over the distance window (two pointers)
        local sm = {}
        local lo, hi, sum, cnt = 1, 0, 0, 0
        for k = 1, n do
          while hi < n and ds[hi + 1] <= ds[k] + win do
            hi = hi + 1
            if hs[hi] then sum = sum + hs[hi]; cnt = cnt + 1 end
          end
          while ds[lo] < ds[k] - win do
            if hs[lo] then sum = sum - hs[lo]; cnt = cnt - 1 end
            lo = lo + 1
          end
          sm[k] = cnt > 0 and sum / cnt or hs[k]
        end
        lines[#lines + 1] = { xs = xs, ys = ys, hs = sm, n = n, half = sh.width / mpu / 2 }
      end
    end
  end
  local B = 512
  local grid = {}
  for li, L in ipairs(lines) do
    for k = 1, L.n - 1 do
      local x0, x1 = min(L.xs[k], L.xs[k + 1]) - L.half, max(L.xs[k], L.xs[k + 1]) + L.half
      local y0, y1 = min(L.ys[k], L.ys[k + 1]) - L.half, max(L.ys[k], L.ys[k + 1]) + L.half
      for by = floor(y0 / B), floor(y1 / B) do
        for bx = floor(x0 / B), floor(x1 / B) do
          local kk = by * 4096 + bx
          local G = grid[kk]
          if not G then G = {}; grid[kk] = G end
          G[#G + 1] = li; G[#G + 1] = k
        end
      end
    end
  end
  return lines, grid, B
end

-- road height at a point: the heights of every road centre line within its half width (+ slack), blended by
-- distance, so roads that meet at a junction share their heights there; nil if no road is near
local function road_height(lines, grid, B, x, y, slack)
  local G = grid[floor(y / B) * 4096 + floor(x / B)]
  if not G then return nil end
  local sw, sh = 0, 0
  local seen = {}
  for i = 1, #G, 2 do
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
  for _, e in pairs(seen) do
    local w = 1 / (e[1] + 1)
    sw = sw + w; sh = sh + w * e[2]
  end
  if sw == 0 then return nil end
  return sh / sw
end

function M.heights(r, H, gx0, gy0, opts)
  opts = opts or {}
  local tick = opts.tick or function() end
  local X, Y, V, N, surf, nt = r.X, r.Y, r.V, r.N, r.surf, r.nt
  local mpu = r.mpu
  local problems, stats = {}, {}

  -- which points touch water, which touch a road
  local wet, roady, used = {}, {}, {}
  for t = 1, nt do
    local o = 3 * t - 3
    local s = surf[t]
    for i = 1, 3 do
      local v = V[o + i]
      used[v] = true
      if WATER[s] then wet[v] = s end
      if ROADLIKE[s] then roady[v] = true end
    end
  end

  local lines, grid, B = centrelines(r, H, gx0, gy0, mpu)
  tick()
  local land, water = {}, {}
  local missing = 0
  local r_water = 50 / mpu
  local n = 0
  for v in pairs(used) do
    n = n + 1
    if n % 64 == 0 then tick() end
    local gx, gy = gx0 + X[v], gy0 + Y[v]
    local h = H:at(gx, gy)
    if not h then missing = missing + 1; h = 0 end
    if roady[v] then
      local rh = road_height(lines, grid, B, X[v], Y[v], 1.5 / mpu)
      if rh then h = rh end
    end
    if wet[v] then
      local lvl
      if wet[v] == "sea" then lvl = 0
      else lvl = (H:min_around(gx, gy, r_water) or h) - 0.3 end
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
        if roady[a] and roady[b] and not wet[a] and not wet[b] and not border(a) and not border(b) then
          local L = nbr[a]; if not L then L = {}; nbr[a] = L end
          L[#L + 1] = b
          local Lb = nbr[b]; if not Lb then Lb = {}; nbr[b] = Lb end
          Lb[#Lb + 1] = a
        end
      end
    end
  end
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
        if surf[u] == "stream" then flowing = true end
        for i = 1, 3 do
          local h = water[V[o + i]]
          if h < lo then lo = h end
          if h > hi then hi = h end
          local w = N[o + i]
          if w and WATER[surf[w]] and not seen[w] then seen[w] = true; sn = sn + 1; stack[sn] = w end
        end
      end
      -- streams run downhill; lakes, canals and the sea should be level within the cell
      if not flowing and hi - lo > worst_water then worst_water = hi - lo end
    end
  end
  stats.water_areas, stats.water_range = regions, worst_water
  if worst_water > 1.5 then problems[#problems + 1] = string.format("standing water not level (%.1f m)", worst_water) end

  -- roads a car or bike uses must stay under 30 %; paths and tracks may be steep (hiking trails)
  local LIMIT = { road = 0.30, road_unpaved = 0.30, cycleway = 0.30, rail = 0.10 }
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
  if stats.road_steep_share > 0.05 then
    problems[#problems + 1] = string.format("%.0f %% of the road area steeper than allowed", stats.road_steep_share * 100)
  end
  stats.walls = #walls
  return { land = land, water = water, walls = walls, problems = problems, stats = stats }
end

return M
