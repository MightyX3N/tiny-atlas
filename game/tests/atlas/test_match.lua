-- Puts routes onto the map's roads (match.lua) the way the game does, and checks where the rider ends up: on a road
-- or path (not on grass, pavement, a building or water), away from its edges, and the climbs unchanged. Compares
-- with the raw GPX positions. Downloads map data into CACHE_DIR the first time (curl).
-- usage: test_match.lua CACHE_DIR GPX [GPX ...]    env: NOISE=m (add GPS-like drift), KM=n (first n km only),
--        OVERTURE=0 (roads from the vector tiles only), RAW=1 (also run without matching, to compare)
dofile((debug.getinfo(1,"S").source:sub(2):match("(.*/)") or "./") .. "common.lua")
local fetch, world, route, cell, mesh, match = ATLAS_REQUIRE("fetch"), ATLAS_REQUIRE("world"), ATLAS_REQUIRE("route"),
  ATLAS_REQUIRE("cell"), ATLAS_REQUIRE("mesh"), ATLAS_REQUIRE("match")
local CACHE = arg[1]
if os.getenv("HOOK") then dofile(os.getenv("HOOK")) end
local NOISE, KM = tonumber(os.getenv("NOISE") or "0"), tonumber(os.getenv("KM") or "0")
local floor, sqrt, abs = math.floor, math.sqrt, math.abs

local function sh(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local P = {
  http_get = function(url, ok, err, range)
    local tmp = os.tmpname()
    local cmd = "curl -s -f -L --max-time 120 " .. (range and ("-H " .. sh("Range: " .. range) .. " ") or "") .. "-o " .. tmp .. " " .. sh(url)
    local rc = os.execute(cmd)
    local f = io.open(tmp, "rb")
    local body = f and f:read("*a"); if f then f:close() end
    os.remove(tmp)
    if (rc == 0 or rc == true) and body then ok(body) else err("download failed: " .. url) end
  end,
  read = function(p) local f = io.open(CACHE .. "/" .. p:gsub("^tinyatlas/cache/", ""), "rb"); if not f then return nil end; local s = f:read("*a"); f:close(); return s end,
  write = function(p, s)
    local full = CACHE .. "/" .. p:gsub("^tinyatlas/cache/", "")
    os.execute("mkdir -p " .. sh(full:match("(.*)/")))
    local f = io.open(full, "wb"); if f then f:write(s); f:close() end
  end,
  time = os.time,
}

-- GPS-like drift: a slowly wandering offset of about NOISE metres (correlated over ~60 m), plus a little jitter
local function drift(points, metres)
  if metres <= 0 then return points end
  local out, ox, oy = {}, 0, 0
  math.randomseed(7)
  local function g() return (math.random() + math.random() + math.random() - 1.5) * 2 end
  for i, p in ipairs(points) do
    ox = ox * 0.97 + g() * metres * 0.25; oy = oy * 0.97 + g() * metres * 0.25
    local k = 111320 * math.cos(math.rad(p[1]))
    out[i] = { p[1] + (oy + g() * 0.5) / 110540, p[2] + (ox + g() * 0.5) / k }
  end
  return out
end

local function cut(points, km)
  if km <= 0 then return points end
  local out, d = { points[1] }, 0
  for i = 2, #points do
    local a, b = points[i - 1], points[i]
    d = d + sqrt(((b[1] - a[1]) * 110540) ^ 2 + ((b[2] - a[2]) * 111320 * math.cos(math.rad(a[1]))) ^ 2)
    out[#out + 1] = b
    if d > km * 1000 then break end
  end
  return out
end

local function run(points, use_match)
  local saved = match.new
  if not use_match then
    match.new = function(R) R.way = {}; return { advance = function() end, finish = function() end, settled_m = function() return 0 end } end
  end
  local W = world.new({ fetch = fetch.new(P), lat = points[1][1], lon = points[1][2], tile_metres = 3.3, unit = 1,
    overture = os.getenv("OVERTURE") ~= "0",
    make = function() return {} end, free = function() end, log = function(m) if m:match("FAILED") then print("  " .. m) end end })
  local built = {}
  local bc = W.build_cell
  W.build_cell = function(self, cx, cy, tick)
    local r, g, l = bc(self, cx, cy, tick)
    if r then built[cx * 1048576 + cy] = { r, g } end
    return r, g, l
  end
  local R = route.new(points, W)
  local t0 = os.clock()
  local sum = W:prepare_route(R, function() end)
  match.new = saved
  -- where the rider is, every 2 m: the surface there and 0.6 m to either side
  local CELL = 8192
  local function surf_at(gx, gy)
    local cx, cy = floor(gx / CELL), floor(gy / CELL)
    local c = built[cx * 1048576 + cy]
    if not c then return nil end
    local _, s = mesh.height_at(c[1], c[2], gx - cx * CELL, gy - cy * CELL)
    return s
  end
  local on, edge, off, bridge, offroad = 0, 0, 0, 0, 0
  local kinds = {}
  local worst = {}
  for k = 1, R.n do
    local s = R.surf[k]
    local fx, fy = R:dir(R.S[k], 3)
    local nx, ny = fy, -fx
    local ok_mid = s and cell.ROADLIKE[s]
    if s == "bridge" or s == "tunnel" then bridge = bridge + 1
    elseif ok_mid then
      local a = surf_at(W:global_of_metres(R.X[k] + nx * 0.6, R.Y[k] + ny * 0.6))
      local b = surf_at(W:global_of_metres(R.X[k] - nx * 0.6, R.Y[k] - ny * 0.6))
      if (a and not cell.ROADLIKE[a]) or (b and not cell.ROADLIKE[b]) then edge = edge + 1 else on = on + 1 end
    else
      off = off + 1
      kinds[tostring(s)] = (kinds[tostring(s)] or 0) + 1
      if #worst < 6 and (k == 1 or (R.surf[k - 1] and cell.ROADLIKE[R.surf[k - 1]])) then worst[#worst + 1] = string.format("%.2f km (%s)", R.S[k] / 1000, tostring(s)) end
    end
    if R.way[k] and R.way[k].kind == "off" then offroad = offroad + 1 end
  end
  local dbg = os.getenv("DEBUG")
  if dbg and use_match then
    local a, b = dbg:match("([%d.]+)-([%d.]+)")
    for k = 1, R.n do
      if R.S[k] >= a * 1000 and R.S[k] <= b * 1000 then
        local w = R.way[k] or {}
        local rx, ry = W:metres_of(W:global_of(points[1][1], points[1][2]))
        print(string.format("    %.3f km  %-5s %-10s w %4.1f %-7s surf %-12s", R.S[k] / 1000, tostring(w.kind), tostring(w.class), w.width or 0, tostring(w.brunnel), tostring(R.surf[k])))
      end
    end
  end
  -- sideways jumps: the rider moving across more than 1 m in one 2 m step
  local jumps, worst_j, worst_js = 0, 0, 0
  for k = 2, R.n - 1 do
    local dx1, dy1 = R.X[k] - R.X[k - 1], R.Y[k] - R.Y[k - 1]
    local dx2, dy2 = R.X[k + 1] - R.X[k], R.Y[k + 1] - R.Y[k]
    local l1 = sqrt(dx1 * dx1 + dy1 * dy1)
    if l1 > 0 then
      local side = abs((dx2 * dy1 - dy2 * dx1) / l1)          -- how far the next step goes across the last one
      if side > 1.0 then jumps = jumps + 1 end
      if side > worst_j then worst_j, worst_js = side, R.S[k] end
    end
  end
  local n = R.n
  local ks = {}
  for k, v in pairs(kinds) do ks[#ks + 1] = string.format("%s %.0f m", k, v * 2) end
  table.sort(ks)
  return string.format("%s  on a road/path %.1f %%, near its edge %.1f %%, NOT on one %.1f %% (%s), bridges/tunnels %.1f %%, added path %.0f m, sideways jumps %d (worst %.1f m at %.2f km)  | climb %.0f m, worst %.1f %%  (%.0f s)%s",
    use_match and "matched" or "raw    ", on / n * 100, edge / n * 100, off / n * 100, table.concat(ks, ", "), bridge / n * 100,
    offroad * 2, jumps, worst_j, worst_js / 1000, sum.climb, sum.worst_grade, os.clock() - t0, #worst > 0 and ("\n          first off-road spots: " .. table.concat(worst, ", ")) or ""), off / n
end

local bad = 0
for i = 2, #arg do
  local g = assert(route.parse_gpx(readfile(arg[i])))
  local pts = drift(cut(g.points, KM), NOISE)
  print(string.format("%s%s%s", arg[i]:match("[^/]*$"), KM > 0 and (" first " .. KM .. " km") or "", NOISE > 0 and (" with " .. NOISE .. " m GPS drift") or ""))
  if os.getenv("RAW") == "1" then print("  " .. run(pts, false)) end
  local line, offshare = run(pts, true)
  print("  " .. line)
  if offshare > 0.01 then bad = bad + 1 end
end
print(bad == 0 and "OK" or (bad .. " routes with the rider off the road more than 1 % of the way"))
