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

-- road centre lines with smoothed heights, and a bucket grid over their segments
local function centrelines(r, H, gx0, gy0, mpu)
  local step = 6 / mpu                              -- sample every 6 m along each line
  local win = 18 / mpu                              -- smooth over +-18 m
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

-- height of the nearest road centre line within its half width (+ slack), or nil
local function road_height(lines, grid, B, x, y, slack)
  local G = grid[floor(y / B) * 4096 + floor(x / B)]
  if not G then return nil end
  local best, bh
  for i = 1, #G, 2 do
    local L, k = lines[G[i]], G[i + 1]
    local ax, ay, bx, by = L.xs[k], L.ys[k], L.xs[k + 1], L.ys[k + 1]
    local dx, dy = bx - ax, by - ay
    local l2 = dx * dx + dy * dy
    local t = l2 > 0 and ((x - ax) * dx + (y - ay) * dy) / l2 or 0
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    local px, py = ax + dx * t, ay + dy * t
    local d = sqrt((x - px) ^ 2 + (y - py) ^ 2)
    if d <= L.half + slack and (not best or d < best) then
      local h0, h1 = L.hs[k], L.hs[k + 1]
      if h0 and h1 then best = d; bh = h0 + (h1 - h0) * t end
    end
  end
  return bh
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
  local r_water = 20 / mpu
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
      seen[t] = true
      while sn > 0 do
        local u = stack[sn]; sn = sn - 1
        local o = 3 * u - 3
        for i = 1, 3 do
          local h = water[V[o + i]]
          if h < lo then lo = h end
          if h > hi then hi = h end
          local w = N[o + i]
          if w and WATER[surf[w]] and not seen[w] then seen[w] = true; sn = sn + 1; stack[sn] = w end
        end
      end
      if hi - lo > worst_water then worst_water = hi - lo end
    end
  end
  stats.water_areas, stats.water_range = regions, worst_water

  local steep, worst_slope = 0, 0
  for t = 1, nt do
    if ROADLIKE[surf[t]] then
      local o = 3 * t - 3
      local a, b, c = V[o + 1], V[o + 2], V[o + 3]
      local ux, uy, uz = (X[b] - X[a]) * mpu, (Y[b] - Y[a]) * mpu, land[b] - land[a]
      local vx, vy, vz = (X[c] - X[a]) * mpu, (Y[c] - Y[a]) * mpu, land[c] - land[a]
      local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
      local horiz = sqrt(nx * nx + ny * ny)
      local slope = abs(nz) > 1e-9 and horiz / abs(nz) or 0
      if slope > worst_slope then worst_slope = slope end
      if slope > 0.35 then steep = steep + 1 end
    end
  end
  stats.road_worst_slope, stats.road_steep_triangles = worst_slope, steep
  if steep > 0 then problems[#problems + 1] = steep .. " road triangles steeper than 35 %" end
  stats.walls = #walls
  return { land = land, water = water, walls = walls, problems = problems, stats = stats }
end

return M
