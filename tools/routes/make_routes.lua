-- Makes the test routes (GPX) by routing along OpenStreetMap roads and paths from the cached vector tiles.
-- usage: luajit.py make_routes.lua CACHE_DIR OUT_DIR
-- Each route is a list of waypoints; between waypoints the shortest path on the road network is taken, with
-- road classes weighted per route (a road ride avoids footpaths, a forest loop likes tracks).
local here = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
dofile(here .. "../../game/tests/atlas/common.lua")
local mvt = ATLAS_REQUIRE("mvt")
local CACHE, OUT = arg[1], arg[2]

local ROUTES = {
  { id = "amsterdam-canal-ring", name = "Amsterdam canal ring", cost = "city", loop = true, wp = {
    { 52.3808, 4.8878 }, { 52.3740, 4.8835 }, { 52.3650, 4.8830 }, { 52.3590, 4.8850 }, { 52.3618, 4.8880 }, { 52.3607, 4.8967 },
    { 52.3618, 4.9030 }, { 52.3665, 4.8995 }, { 52.3672, 4.8915 }, { 52.3700, 4.8870 }, { 52.3760, 4.8860 },
    { 52.3800, 4.8900 }, { 52.3785, 4.9000 }, { 52.3720, 4.8930 }, { 52.3808, 4.8878 } } },
  { id = "copenhagen-lakes-harbour", name = "Copenhagen lakes and harbour", cost = "city", loop = true, wp = {
    { 55.6873, 12.5617 }, { 55.6957, 12.5755 }, { 55.6915, 12.5810 }, { 55.6870, 12.5750 }, { 55.6798, 12.5890 },
    { 55.6730, 12.5915 }, { 55.6640, 12.5780 }, { 55.6700, 12.5760 }, { 55.6770, 12.5500 }, { 55.6830, 12.5600 },
    { 55.6873, 12.5617 } } },
  { id = "alpe-dhuez", name = "Alpe d'Huez climb (to the village)", cost = "road", wp = { { 45.0560, 6.0310 }, { 45.0860, 6.0610 } } },
  { id = "rold-skov", name = "Rold Skov countryside loop", cost = "country", loop = true, wp = {
    { 56.8355, 9.8915 }, { 56.8000, 9.8600 }, { 56.7900, 9.8350 }, { 56.8150, 9.8200 },
    { 56.8350, 9.8300 }, { 56.8355, 9.8915 } } },
}

-- cost per metre by road class; nil = not allowed
local COST = {
  city = { primary = 1.3, secondary = 1.2, tertiary = 1.1, minor = 1, service = 1.2, cycleway = 0.8, path = 1.6, track = 2 },
  road = { primary = 1, secondary = 1, tertiary = 1.1, minor = 3, service = 3, cycleway = 2, path = 12, track = 12 },
  country = { primary = 2, secondary = 1.4, tertiary = 1.1, minor = 1, service = 1.3, cycleway = 1, path = 1.6, track = 1 },
}
local function kind(p)
  local c = p.class
  if c == "motorway" or c == "trunk" or c == "rail" or c == "transit" or c == "ferry" or c == "aerialway" then return nil end
  if p.subclass == "steps" then return nil end
  if c == "path" then return (p.subclass == "cycleway") and "cycleway" or "path" end
  if c == "primary" or c == "secondary" or c == "tertiary" or c == "minor" or c == "service" or c == "track" then return c end
  return nil
end

local function tile_of(lat, lon)
  local n = 2 ^ 14
  local fx = (lon + 180) / 360 * n
  local lr = math.rad(lat)
  local fy = (1 - math.log(math.tan(lr) + 1 / math.cos(lr)) / math.pi) / 2 * n
  return fx * 65536, fy * 65536                    -- global units
end
local function latlon(gx, gy)
  local n = 2 ^ 14 * 65536
  return math.deg(math.atan(math.sinh(math.pi * (1 - 2 * gy / n)))), gx / n * 360 - 180
end
local function exists(p) local f = io.open(p, "rb"); if f then f:close(); return true end end

local function build_graph(r)
  local x0, y0, x1, y1 = 1e18, 1e18, -1e18, -1e18
  for _, w in ipairs(r.wp) do
    local gx, gy = tile_of(w[1], w[2])
    x0, x1, y0, y1 = math.min(x0, gx), math.max(x1, gx), math.min(y0, gy), math.max(y1, gy)
  end
  local tx0, tx1 = math.floor(x0 / 65536) - 1, math.floor(x1 / 65536) + 1
  local ty0, ty1 = math.floor(y0 / 65536) - 1, math.floor(y1 / 65536) + 1
  local ox, oy = tx0 * 65536, ty0 * 65536
  local nodes, adj, nn = {}, {}, 0
  local NX, NY = {}, {}
  local cost = COST[r.cost]
  local function node(gx, gy)
    gx, gy = math.floor(gx + 0.5), math.floor(gy + 0.5)
    local key = (gx - ox) * 4194304 + (gy - oy)
    local i = nodes[key]
    if not i then nn = nn + 1; i = nn; nodes[key] = i; NX[i], NY[i] = gx, gy; adj[i] = {} end
    return i
  end
  -- all segments first; junctions in the tiles are not always shared points (lines are simplified), so
  -- crossings and line ends that stop on another line are found geometrically
  local SA, SB, SC, ns = {}, {}, {}, 0           -- SA/SB: {x, y}; SC: cost per unit
  local tiles = 0
  for tx = tx0, tx1 do for ty = ty0, ty1 do
    local p = CACHE .. "/omt/14/" .. tx .. "_" .. ty .. ".dat"
    if exists(p) then
      tiles = tiles + 1
      local L = mvt.decode(readfile(p)).transportation
      for _, f in ipairs(L and L.features or {}) do
        local kd = f.type == 2 and kind(f.props)
        local c = kd and cost[kd]
        if c then
          for _, part in ipairs(f.parts) do
            for k = 3, #part, 2 do
              local ax, ay = tx * 65536 + part[k - 2] * 16, ty * 65536 + part[k - 1] * 16
              local bx, by = tx * 65536 + part[k] * 16, ty * 65536 + part[k + 1] * 16
              if ax ~= bx or ay ~= by then
                ns = ns + 1; SA[ns] = { ax, ay }; SB[ns] = { bx, by }; SC[ns] = c
              end
            end
          end
        end
      end
    end
  end end
  local B = 512
  local grid = {}
  for i = 1, ns do
    local a, b = SA[i], SB[i]
    for gy = math.floor((math.min(a[2], b[2]) - 64) / B), math.floor((math.max(a[2], b[2]) + 64) / B) do
      for gx = math.floor((math.min(a[1], b[1]) - 64) / B), math.floor((math.max(a[1], b[1]) + 64) / B) do
        local key = gx * 1000003 + gy
        local L = grid[key]; if not L then L = {}; grid[key] = L end
        L[#L + 1] = i
      end
    end
  end
  local cuts = {}                                -- per segment: list of t in (0, 1)
  for i = 1, ns do cuts[i] = {} end
  local SNAP = 40                                -- global units (about 1 m): line ends this close join a line
  local function ptseg(px, py, a, b)
    local dx, dy = b[1] - a[1], b[2] - a[2]
    local l2 = dx * dx + dy * dy
    local t = ((px - a[1]) * dx + (py - a[2]) * dy) / l2
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    local qx, qy = a[1] + dx * t, a[2] + dy * t
    return math.sqrt((px - qx) ^ 2 + (py - qy) ^ 2), t
  end
  for _, L in pairs(grid) do
    for x = 1, #L do
      local i = L[x]
      local a, b = SA[i], SB[i]
      for y = x + 1, #L do
        local j = L[y]
        local c, d = SA[j], SB[j]
        local rx, ry = b[1] - a[1], b[2] - a[2]
        local sx, sy = d[1] - c[1], d[2] - c[2]
        local den = rx * sy - ry * sx
        if den ~= 0 then
          local t = ((c[1] - a[1]) * sy - (c[2] - a[2]) * sx) / den
          local u = ((c[1] - a[1]) * ry - (c[2] - a[2]) * rx) / den
          if t > 0 and t < 1 and u > 0 and u < 1 then
            local ci, cj = cuts[i], cuts[j]
            ci[#ci + 1] = t; cj[#cj + 1] = u
          end
        end
        -- T-junctions: an end of one segment lying on the other
        for _, e in ipairs({ { a, j, c, d }, { b, j, c, d }, { c, i, a, b }, { d, i, a, b } }) do
          local dd, t = ptseg(e[1][1], e[1][2], e[3], e[4])
          if dd < SNAP and t > 0 and t < 1 then local cs = cuts[e[2]]; cs[#cs + 1] = t end
        end
      end
    end
  end
  local edges = {}
  for i = 1, ns do
    local a, b, c = SA[i], SB[i], SC[i]
    local ts = cuts[i]
    table.sort(ts)
    local prev = node(a[1], a[2])
    local list = {}
    for _, t in ipairs(ts) do list[#list + 1] = t end
    list[#list + 1] = 1
    for _, t in ipairs(list) do
      local cur = node(a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t)
      if cur ~= prev then
        local key = math.min(prev, cur) * 4194304 + math.max(prev, cur)
        if not edges[key] then
          edges[key] = true
          local dd = math.sqrt((NX[cur] - NX[prev]) ^ 2 + (NY[cur] - NY[prev]) ^ 2)
          local A, Bb = adj[prev], adj[cur]
          A[#A + 1] = cur; A[#A + 1] = dd * c
          Bb[#Bb + 1] = prev; Bb[#Bb + 1] = dd * c
        end
      end
      prev = cur
    end
  end
  return { NX = NX, NY = NY, adj = adj, n = nn, tiles = tiles }
end

local function nearest(G, gx, gy)
  if not G.comp then
    -- connected parts of the network; waypoints snap to the biggest one only
    local comp, sizes, nc = {}, {}, 0
    for i = 1, G.n do
      if not comp[i] then
        nc = nc + 1
        local st, sn, sz = { i }, 1, 0
        comp[i] = nc
        while sn > 0 do
          local u = st[sn]; sn = sn - 1; sz = sz + 1
          local a = G.adj[u]
          for k = 1, #a, 2 do if not comp[a[k]] then comp[a[k]] = nc; sn = sn + 1; st[sn] = a[k] end end
        end
        sizes[nc] = sz
      end
    end
    local big = 1
    for c = 2, nc do if sizes[c] > sizes[big] then big = c end end
    G.comp, G.big = comp, big
  end
  local best, bd
  for i = 1, G.n do
    if G.comp[i] == G.big then
      local d = (G.NX[i] - gx) ^ 2 + (G.NY[i] - gy) ^ 2
      if not bd or d < bd then best, bd = i, d end
    end
  end
  return best, math.sqrt(bd)
end

local function dijkstra(G, s, t)
  local dist, prev, done = { [s] = 0 }, {}, {}
  local heap, hn = { s }, 1
  local function push(i)
    hn = hn + 1; heap[hn] = i
    local c = hn
    while c > 1 do
      local p = math.floor(c / 2)
      if dist[heap[p]] <= dist[heap[c]] then break end
      heap[p], heap[c] = heap[c], heap[p]; c = p
    end
  end
  local function pop()
    local top = heap[1]
    heap[1] = heap[hn]; heap[hn] = nil; hn = hn - 1
    local c = 1
    while true do
      local l, r, m = 2 * c, 2 * c + 1, c
      if l <= hn and dist[heap[l]] < dist[heap[m]] then m = l end
      if r <= hn and dist[heap[r]] < dist[heap[m]] then m = r end
      if m == c then break end
      heap[m], heap[c] = heap[c], heap[m]; c = m
    end
    return top
  end
  while hn > 0 do
    local u = pop()
    if not done[u] then
      done[u] = true
      if u == t then break end
      local a = G.adj[u]
      for k = 1, #a, 2 do
        local v, w = a[k], a[k + 1]
        local nd = dist[u] + w
        if not dist[v] or nd < dist[v] then dist[v] = nd; prev[v] = u; push(v) end
      end
    end
  end
  if not dist[t] then return nil end
  local path, u = {}, t
  while u do table.insert(path, 1, u); u = prev[u] end
  return path
end

for _, r in ipairs(ROUTES) do
  local G = build_graph(r)
  local pts = {}
  local mpu = 40075016.686 * math.cos(math.rad(r.wp[1][1])) / (2 ^ 14 * 65536)
  for i = 1, #r.wp - 1 do
    local a, da = nearest(G, tile_of(r.wp[i][1], r.wp[i][2]))
    local b, db = nearest(G, tile_of(r.wp[i + 1][1], r.wp[i + 1][2]))
    if da * mpu > 150 or db * mpu > 150 then print(string.format("  waypoint %d is %.0f m / %d is %.0f m from a road", i, da * mpu, i + 1, db * mpu)) end
    local path = assert(dijkstra(G, a, b), r.id .. ": no path between waypoints " .. i .. " and " .. (i + 1))
    for k, n in ipairs(path) do if k > 1 or #pts == 0 then pts[#pts + 1] = n end end
  end
  local len = 0
  for k = 2, #pts do len = len + math.sqrt((G.NX[pts[k]] - G.NX[pts[k - 1]]) ^ 2 + (G.NY[pts[k]] - G.NY[pts[k - 1]]) ^ 2) * mpu end
  local out = { '<?xml version="1.0" encoding="UTF-8"?>',
    '<gpx version="1.1" creator="Tiny Atlas test routes (tools/routes/make_routes.lua), map data OpenStreetMap contributors" xmlns="http://www.topografix.com/GPX/1/1">',
    "  <trk><name>" .. r.name .. "</name><trkseg>" }
  for _, n in ipairs(pts) do
    local lat, lon = latlon(G.NX[n], G.NY[n])
    out[#out + 1] = string.format('    <trkpt lat="%.7f" lon="%.7f"/>', lat, lon)
  end
  out[#out + 1] = "  </trkseg></trk>"
  out[#out + 1] = "</gpx>"
  local f = assert(io.open(OUT .. "/" .. r.id .. ".gpx", "w"))
  f:write(table.concat(out, "\n") .. "\n"); f:close()
  print(string.format("%-28s %5d points  %6.2f km  (%d tiles, %d nodes)", r.id, #pts, len / 1000, G.tiles, G.n))
end
