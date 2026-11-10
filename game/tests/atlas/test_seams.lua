-- Checks that the drawn ground is one closed surface: no holes, nothing lying on top of anything else.
-- Builds every cell along each test route (and the ring of cells around it, what a rider sees), turns each into
-- the real draw lists (mesh.build) and checks the triangles themselves:
--   holes      a triangle edge inside a cell with no triangle on the other side (you see through the ground)
--   overlaps   two triangles covering the same ground (one edge used twice the same way round, or a flipped
--              triangle), or the cell's triangles adding up to more or less than the cell's area
--   cracks     two triangles sharing an edge at different heights with no wall closing the gap (land / water)
--   seams      the edge between two neighbouring cells at different heights on each side
-- usage: test_seams.lua CACHE_DIR ROUTES_DIR [route ids...]      env SEAM_LIST=file: every problem with its place
dofile((debug.getinfo(1,"S").source:sub(2):match("(.*/)") or "./") .. "common.lua")
local fetch, world, route, mesh = ATLAS_REQUIRE("fetch"), ATLAS_REQUIRE("world"), ATLAS_REQUIRE("route"), ATLAS_REQUIRE("mesh")
local CACHE, RDIR = arg[1], arg[2]
local ids = {}
for i = 3, #arg do ids[#ids + 1] = arg[i] end
if #ids == 0 then ids = { "amsterdam-city-run", "amsterdam-canal-ring", "copenhagen-lakes-harbour", "alpe-dhuez", "rold-skov" } end
local P = {
  http_get = function(url, ok, err) err("offline test") end,
  read = function(p) local f = io.open(CACHE .. "/" .. p:gsub("^tinyatlas/cache/", ""), "rb"); if not f then return nil end; local s = f:read("*a"); f:close(); return s end,
  write = function() end, time = os.time,
}
local CELL = 8192
local TOL = 0.02                 -- metres: heights closer than this count as the same
local abs, floor, min, max = math.abs, math.floor, math.min, math.max
local LIST = os.getenv("SEAM_LIST") and io.open(os.getenv("SEAM_LIST"), "w")

local function latlon(gx, gy)
  local n = 2 ^ 17 * CELL
  local lon = gx / n * 360 - 180
  local lat = math.deg(math.atan(math.sinh(math.pi * (1 - 2 * gy / n))))
  return lat, lon
end

-- one cell's triangles -> checks inside the cell; returns its border: per side, list of { pos, z } segments
local function check_cell(cx, cy, r, g, tot, route_id)
  local groups = mesh.build(r, g, { k = 1, unit = 1, tile_metres = 3.3 })
  local function where(x, y, what, amount)
    local lat, lon = latlon(cx * CELL + x, cy * CELL + y)
    tot[what] = tot[what] + 1
    tot[what .. "_cells"][cx * 1048576 + cy] = true
    if LIST then LIST:write(string.format("%s %s %.6f %.6f %.2f cell %d/%d\n", route_id, what, lat, lon, amount or 0, cx, cy)) end
  end
  local tris, walls, skirts = {}, {}, {}
  for _, G in ipairs(groups) do
    local d = G.d
    for i = 0, G.n - 1, 3 do
      local o = i * 8
      -- cell units, y south (as in cell.lua) so positions are exact integers
      local x1, y1, z1 = d[o + 1], -d[o + 2], d[o + 3]
      local x2, y2, z2 = d[o + 9], -d[o + 10], d[o + 11]
      local x3, y3, z3 = d[o + 17], -d[o + 18], d[o + 19]
      local a2 = (x2 - x1) * (y3 - y1) - (x3 - x1) * (y2 - y1)
      if x1 == x2 and y1 == y2 or x2 == x3 and y2 == y3 or x1 == x3 and y1 == y3 then
        local onside = (x1 == x2 and x2 == x3 and (x1 == 0 or x1 == CELL)) or (y1 == y2 and y2 == y3 and (y1 == 0 or y1 == CELL))
        if onside then
          -- a skirt under a border edge: lowest point it reaches at each end of that edge
          local pts = { { x1, y1, z1 }, { x2, y2, z2 }, { x3, y3, z3 } }
          local A, B
          for _, q in ipairs(pts) do
            if not A then A = q elseif (q[1] ~= A[1] or q[2] ~= A[2]) then B = q end
          end
          local ka, kb = A[1] * 65536 + A[2], B[1] * 65536 + B[2]
          local key = ka < kb and (ka .. ":" .. kb) or (kb .. ":" .. ka)
          local sk = skirts[key]
          if not sk then sk = {}; skirts[key] = sk end
          for _, q in ipairs(pts) do
            local kq = q[1] * 65536 + q[2]
            sk[kq] = min(sk[kq] or 1e9, q[3])
          end
        else
          walls[#walls + 1] = { x1, y1, z1 }; walls[#walls + 1] = { x2, y2, z2 }; walls[#walls + 1] = { x3, y3, z3 }
        end
      else
        tris[#tris + 1] = { x1, y1, z1, x2, y2, z2, x3, y3, z3, a2 }
      end
    end
  end
  -- wall cover: for an edge a-b, the height range the walls close at each end
  local wcover = {}
  local function vk(x, y) return x * 65536 + y end
  for _, w in ipairs(walls) do
    local k = vk(w[1], w[2])
    local c = wcover[k]
    if not c then wcover[k] = { w[3], w[3] } else c[1] = min(c[1], w[3]); c[2] = max(c[2], w[3]) end
  end
  -- edges: in cell.lua's frame (y south) counter-clockwise triangles have negative a2 here; all must agree
  local area = 0
  local edges = {}
  local sign
  for _, t in ipairs(tris) do
    local s = t[10] > 0 and 1 or -1
    sign = sign or s
    area = area + abs(t[10]) / 2
    if s ~= sign then where((t[1] + t[4] + t[7]) / 3, (t[2] + t[5] + t[8]) / 3, "flipped") end
    local P = { { t[1], t[2], t[3] }, { t[4], t[5], t[6] }, { t[7], t[8], t[9] } }
    for i = 1, 3 do
      local a, b = P[i], P[i % 3 + 1]
      local ka, kb = vk(a[1], a[2]), vk(b[1], b[2])
      local key = ka < kb and (ka .. ":" .. kb) or (kb .. ":" .. ka)
      local e = edges[key]
      if not e then e = { a = a, b = b, n = 0, fwd = 0 }; edges[key] = e end
      e.n = e.n + 1
      if ka < kb then e.fwd = e.fwd + 1 end
      -- heights at each end, by end position
      e[#e + 1] = { ka, a[3], kb, b[3] }
    end
  end
  -- hairlines: a thin triangle of one surface between other surfaces on both its long sides shows as a line of
  -- the wrong colour (a crack in the road, a stripe of grass through a yard)
  do
    local X, Y, V, Nb, surf = r.X, r.Y, r.V, r.N, r.surf
    for t = 1, r.nt do
      local o = 3 * t - 3
      local P = { V[o + 1], V[o + 2], V[o + 3] }
      local L = {}
      for i = 1, 3 do
        local a, b = P[i], P[i % 3 + 1]
        L[i] = math.sqrt((X[b] - X[a]) ^ 2 + (Y[b] - Y[a]) ^ 2)
      end
      local long = max(L[1], L[2], L[3])
      local a, b, c = P[1], P[2], P[3]
      local area2 = abs((X[b] - X[a]) * (Y[c] - Y[a]) - (X[c] - X[a]) * (Y[b] - Y[a]))
      if long * r.mpu > 1 and area2 / long * r.mpu < 0.3 then
        -- the two longer edges
        local short = (L[1] <= L[2] and L[1] <= L[3]) and 1 or (L[2] <= L[3] and 2 or 3)
        local diff, ns = 0, {}
        for i = 1, 3 do
          if i ~= short then
            local u = Nb[o + i]
            if u and surf[u] ~= surf[t] then diff = diff + 1; ns[#ns + 1] = surf[u] end
          end
        end
        if diff == 2 then
          where((X[a] + X[b] + X[c]) / 3, (Y[a] + Y[b] + Y[c]) / 3, "hairlines", long * r.mpu)
          if LIST then LIST:write(string.format("   hairline %s between %s %s  %.2f m long %.2f m thick  (%d,%d)\n", surf[t], ns[1], ns[2], long * r.mpu, area2 / long * r.mpu, X[a], Y[a])) end
        end
      end
    end
  end
  local cellarea = CELL * CELL
  if abs(area - cellarea) > 2 then
    tot.area_bad = tot.area_bad + 1
    if LIST then LIST:write(string.format("%s area cell %d/%d %.0f of %.0f\n", route_id, cx, cy, area, cellarea)) end
  end
  local border = { {}, {}, {}, {} }   -- west, east, north, south: segments { p0, z0, p1, z1 }
  for _, e in pairs(edges) do
    local a, b = e.a, e.b
    local mx, my = (a[1] + b[1]) / 2, (a[2] + b[2]) / 2
    local onb = (a[1] == 0 and b[1] == 0) or (a[1] == CELL and b[1] == CELL) or (a[2] == 0 and b[2] == 0) or (a[2] == CELL and b[2] == CELL)
    if e.n == 1 then
      if onb then
        local side = (a[1] == 0 and b[1] == 0) and 1 or (a[1] == CELL and b[1] == CELL) and 2 or (a[2] == 0 and b[2] == 0) and 3 or 4
        local pa, pb = side <= 2 and a[2] or a[1], side <= 2 and b[2] or b[1]
        local L = border[side]
        local ka, kb = vk(a[1], a[2]), vk(b[1], b[2])
        local sk = skirts[ka < kb and (ka .. ":" .. kb) or (kb .. ":" .. ka)]
        L[#L + 1] = { pa, a[3], pb, b[3], sk and sk[ka], sk and sk[kb] }
      else
        where(mx, my, "holes")
      end
    elseif e.n == 2 then
      if e.fwd ~= 1 then where(mx, my, "overlaps") end
      -- cracks: compare heights at each end
      local h1, h2 = e[1], e[2]
      local function zat(h, k) return h[1] == k and h[2] or h[4] end
      local ka = vk(a[1], a[2]); local kb = vk(b[1], b[2])
      local worst = 0
      for _, k in ipairs({ ka, kb }) do
        local z1, z2 = zat(h1, k), zat(h2, k)
        local gap = abs(z1 - z2)
        if gap > TOL then
          local c = wcover[k]
          if not (c and c[1] <= min(z1, z2) + TOL and c[2] >= max(z1, z2) - TOL) then worst = max(worst, gap) end
        end
      end
      if worst > 0 then where(mx, my, "cracks", worst); tot.crack_worst = max(tot.crack_worst, worst) end
    else
      where(mx, my, "overlaps")
    end
  end
  for _, L in ipairs(border) do table.sort(L, function(p, q) return min(p[1], p[3]) < min(q[1], q[3]) end) end
  -- the border must be covered exactly once all along each side
  for side, L in ipairs(border) do
    local at = 0
    for _, s in ipairs(L) do
      local lo, hi = min(s[1], s[3]), max(s[1], s[3])
      if lo ~= at then
        local x, y = side == 1 and 0 or side == 2 and CELL or at, side == 3 and 0 or side == 4 and CELL or at
        where(x, y, lo > at and "holes" or "overlaps")
      end
      at = max(at, hi)
    end
    if at ~= CELL then where(0, 0, "holes") end
  end
  return border
end

-- the segment of a border side under position m (strictly inside it), and its height at p
local function seg_at(L, m)
  for _, s in ipairs(L) do
    local lo, hi = min(s[1], s[3]), max(s[1], s[3])
    if m > lo and m < hi then return s end
  end
end
local function z_of(s, p)
  local t = (p - s[1]) / (s[3] - s[1])
  return s[2] + (s[4] - s[2]) * t
end
local function seam(A, B, cxA, cyA, vertical, tot, route_id)
  -- every point on either side must have the same height on the other side, on the same piece of ground
  local worst, bad = 0, 0
  for pass = 1, 2 do
    local S, O = pass == 1 and A or B, pass == 1 and B or A
    for _, s in ipairs(S) do
      for _, e in ipairs({ { s[1], s[2], s[3] }, { s[3], s[4], s[1] } }) do
        -- the other side's segment just inside this one from this end
        local o = seg_at(O, e[1] + (e[3] > e[1] and 0.001 or -0.001))
        local z = o and z_of(o, e[1])
        if z then
          local gap = abs(z - e[2])
          if gap > TOL then
            tot.raw = tot.raw + 1; tot.raw_worst = max(tot.raw_worst, gap)
          end
          -- the higher side's skirt must reach down to the lower side's ground
          local bottom
          local mine = (e[1] == s[1]) and s[5] or s[6]
          local theirs = o[5] and o[6] and o[5] + (o[6] - o[5]) * (e[1] - o[1]) / (o[3] - o[1]) or nil
          if e[2] > z then bottom = mine else bottom = theirs end
          local open = gap > TOL and not (bottom and bottom <= min(z, e[2]) + TOL)
          if open then
            bad = bad + 1; worst = max(worst, gap)
            if LIST then
              local gx = vertical and (cxA + 1) * CELL or cxA * CELL + e[1]
              local gy = vertical and cyA * CELL + e[1] or (cyA + 1) * CELL
              local lat, lon = latlon(gx, gy)
              LIST:write(string.format("%s seams %.6f %.6f %.2f cell %d/%d %s pos %d  %.2f vs %.2f\n", route_id, lat, lon, gap, cxA, cyA, vertical and "E" or "S", e[1], e[2], z))
            end
          end
        end
      end
    end
  end
  if bad > 0 then tot.seams = tot.seams + bad; tot.seam_edges = tot.seam_edges + 1; tot.seam_worst = max(tot.seam_worst, worst) end
end

local grand = 0
for _, id in ipairs(ids) do
  local gp = assert(route.parse_gpx(readfile(RDIR .. "/" .. id .. ".gpx")))
  local W = world.new({ fetch = fetch.new(P), lat = gp.points[1][1], lon = gp.points[1][2], tile_metres = 3.3, unit = 1,
    make = function() return {} end, free = function() end, log = function() end })
  local R = route.new(gp.points, W)
  local want, list = {}, {}
  for _, c in ipairs(R:cells()) do
    for dx = -1, 1 do for dy = -1, 1 do
      local k = (c[1] + dx) * 1048576 + (c[2] + dy)
      if not want[k] then want[k] = true; list[#list + 1] = { c[1] + dx, c[2] + dy } end
    end end
  end
  local tot = { hairlines = 0, hairlines_cells = {}, raw = 0, raw_worst = 0, holes = 0, overlaps = 0, flipped = 0, cracks = 0, seams = 0, seam_edges = 0, area_bad = 0,
    crack_worst = 0, seam_worst = 0, holes_cells = {}, overlaps_cells = {}, flipped_cells = {}, cracks_cells = {} }
  local borders, built = {}, 0
  local t0 = os.clock()
  for _, c in ipairs(list) do
    local ok, r, g = pcall(W.build_cell, W, c[1], c[2])
    if ok and r then
      built = built + 1
      W:pin_cell({}, c[1], c[2], r, g)
      borders[c[1] * 1048576 + c[2]] = check_cell(c[1], c[2], r, g, tot, id)
    end
  end
  for _, c in ipairs(list) do
    local A = borders[c[1] * 1048576 + c[2]]
    if A then
      local E = borders[(c[1] + 1) * 1048576 + c[2]]
      if E then seam(A[2], E[1], c[1], c[2], true, tot, id) end
      local S = borders[c[1] * 1048576 + c[2] + 1]
      if S then seam(A[4], S[3], c[1], c[2], false, tot, id) end
    end
  end
  local function nc(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
  print(string.format("%-26s %3d cells  height differences at cell borders %d (worst %.2f m)  OPEN: holes %d (%d cells)  overlaps %d (%d cells)  flipped %d  area wrong %d  cracks %d (%d cells, worst %.2f m)  seams %d points on %d cell edges (worst %.2f m)  hairlines %d (%d cells)  %.0f s",
    id, built, tot.raw, tot.raw_worst, tot.holes, nc(tot.holes_cells), tot.overlaps, nc(tot.overlaps_cells), tot.flipped, tot.area_bad,
    tot.cracks, nc(tot.cracks_cells), tot.crack_worst, tot.seams, tot.seam_edges, tot.seam_worst, tot.hairlines, nc(tot.hairlines_cells), os.clock() - t0))
  grand = grand + tot.hairlines + tot.holes + tot.overlaps + tot.flipped + tot.area_bad + tot.cracks + tot.seams
end
if LIST then LIST:close() end
print(grand == 0 and "OK: the ground is closed everywhere" or (grand .. " problems"))
