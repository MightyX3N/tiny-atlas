-- A route's height profile for the menus, before any world is built: the GPX file's own heights when it has them,
-- else coarse elevation tiles (AWS Terrarium at zoom 11, about 50 m a pixel: a few tiles cover a whole route).
-- Kept in the cache as a small text file, so a route is looked up once. Shared by every game.
--
--   profile.of(gpx, fetch, tick) -> summary      inside a build job (it yields while downloading)
--     gpx: route.parse_gpx's table;  summary: route.summary's table, with heights
--   profile.cached(gpx, fetch) -> summary or nil  without downloading anything
local route = ATLAS_REQUIRE("route")
local png = ATLAS_REQUIRE("png")
local fetch_lib = ATLAS_REQUIRE("fetch")
local floor = math.floor

local M = {}
M.ZOOM = 11
M.VERSION = 1

-- a short name for a route: its points, hashed
local function key(g)
  local h = 5381
  local P = g.points
  local step = math.max(1, floor(#P / 200))
  for i = 1, #P, step do
    local v = floor(P[i][1] * 1e5) * 31 + floor(P[i][2] * 1e5)
    h = (h * 33 + v) % 4294967296
  end
  return string.format("%08x_%d", h, #P)
end
local function path(F, g) return F.root .. "/profiles/v" .. M.VERSION .. "_" .. key(g) .. ".txt" end

local function decode(text)
  local S = { profile = {}, heights = true }
  for k, v in text:gmatch("(%a+)=([-%d%.]+)") do S[k] = tonumber(v) end
  for d, e in text:gmatch("\n([-%d%.]+) ([-%d%.]+)") do S.profile[#S.profile + 1] = { tonumber(d), tonumber(e) } end
  return S
end
local function encode(S)
  local out = { string.format("length=%.1f climb=%.1f low=%.1f high=%.1f", S.length, S.climb, S.low, S.high) }
  for _, p in ipairs(S.profile) do out[#out + 1] = string.format("%.0f %.1f", p[1], p[2]) end
  return table.concat(out, "\n") .. "\n"
end

function M.cached(g, F)
  if g.points[1][3] then return route.summary(g) end
  local t = F.P.read(path(F, g))
  return t and decode(t) or nil
end

function M.of(g, F, tick)
  local S = M.cached(g, F)
  if S then return S end
  tick = tick or function() end
  -- the tiles the route crosses
  local z, need, order = M.ZOOM, {}, {}
  for _, p in ipairs(g.points) do
    local x, y = fetch_lib.tile_of(p[1], p[2], z)
    local k = x * 65536 + y
    if not need[k] then need[k] = { x = x, y = y }; order[#order + 1] = need[k] end
  end
  local left = #order
  for _, t in ipairs(order) do
    F:get("terrarium", z, t.x, t.y, function(bytes) t.bytes = bytes; left = left - 1 end,
      function(e) t.err = e; left = left - 1 end)
  end
  while left > 0 do coroutine.yield() end
  for _, t in ipairs(order) do
    if t.err then error("elevation tile " .. z .. "/" .. t.x .. "/" .. t.y .. ": " .. tostring(t.err), 0) end
    t.img = png.decode(t.bytes)
    t.bytes = nil
    tick()
  end
  -- every point's height, bilinear inside its tile
  local pts = {}
  for i, p in ipairs(g.points) do
    local x, y, fx, fy = fetch_lib.tile_of(p[1], p[2], z)
    local img = need[x * 65536 + y].img
    local W = img.w
    local px, py = fx * W - 0.5, fy * W - 0.5
    if px < 0 then px = 0 elseif px > W - 1.001 then px = W - 1.001 end
    if py < 0 then py = 0 elseif py > W - 1.001 then py = W - 1.001 end
    local ix, iy = floor(px), floor(py)
    local ax, ay = px - ix, py - iy
    local h00, h10 = png.terrarium(img, ix, iy), png.terrarium(img, ix + 1, iy)
    local h01, h11 = png.terrarium(img, ix, iy + 1), png.terrarium(img, ix + 1, iy + 1)
    pts[i] = { p[1], p[2], (h00 * (1 - ax) + h10 * ax) * (1 - ay) + (h01 * (1 - ax) + h11 * ax) * ay }
    if i % 256 == 0 then tick() end
  end
  S = route.summary({ name = g.name, points = pts })
  F.P.write(path(F, g), encode(S))
  return S
end

return M
