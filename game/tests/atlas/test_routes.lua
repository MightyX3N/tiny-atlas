-- Gives every test route its heights from the built ground (the way the game prepares a ride) and checks it.
-- usage: test_routes.lua CACHE_DIR ROUTES_DIR [route ids...]
dofile((debug.getinfo(1,"S").source:sub(2):match("(.*/)") or "./") .. "common.lua")
local fetch, world, route = ATLAS_REQUIRE("fetch"), ATLAS_REQUIRE("world"), ATLAS_REQUIRE("route")
local CACHE, RDIR = arg[1], arg[2]
local ids = {}
for i = 3, #arg do ids[#ids + 1] = arg[i] end
if #ids == 0 then ids = { "amsterdam-city-run", "amsterdam-canal-ring", "copenhagen-lakes-harbour", "alpe-dhuez", "rold-skov" } end
local P = {
  http_get = function(url, ok, err) err("offline test") end,
  read = function(p) local f = io.open(CACHE .. "/" .. p:gsub("^tinyatlas/cache/", ""), "rb"); if not f then return nil end; local s = f:read("*a"); f:close(); return s end,
  write = function() end, time = os.time,
}
local bad = 0
for _, id in ipairs(ids) do
  local g = assert(route.parse_gpx(readfile(RDIR .. "/" .. id .. ".gpx")))
  local W = world.new({ fetch = fetch.new(P), lat = g.points[1][1], lon = g.points[1][2], tile_metres = 3.3, unit = 1,
    make = function() return {} end, free = function() end, log = function(m) print("  " .. m) end })
  local R = route.new(g.points, W)
  local t0 = os.clock()
  local s = W:prepare_route(R, function() end)
  print(string.format("%-26s %6.2f km  %3d cells (%d failed)  %.1f s  climb %4.0f m  worst grade %5.1f %% at %.2f km  >25%%: %.0f m  water gaps %d (%.0f m, longest %.0f m)",
    id, s.length / 1000, s.cells, s.failed, os.clock() - t0, s.climb, s.worst_grade, s.worst_at / 1000, s.steep_m, s.gaps, s.gap_m, s.longest_gap))
  if os.getenv("PROFILE_DIR") then
    local f = io.open(os.getenv("PROFILE_DIR") .. "/" .. id .. ".txt", "w")
    for k = 1, R.n do f:write(string.format("%.1f %.3f %.2f %s\n", R.S[k], R.Z[k], R.G[k], tostring(R.surf[k]))) end
    f:close()
  end
  if s.failed > 0 or math.abs(s.worst_grade) > 25 then bad = bad + 1 end
end
print(bad == 0 and "OK" or (bad .. " routes with problems"))
