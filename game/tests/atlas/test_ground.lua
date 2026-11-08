-- Build cells with heights from the test-data cache. usage: test_ground.lua CACHE_DIR "x y" ... [env RASTER_DIR]
dofile((debug.getinfo(1,"S").source:sub(2):match("(.*/)") or "./") .. "common.lua")
local mvt, cell, height, ground = ATLAS_REQUIRE("mvt"), ATLAS_REQUIRE("cell"), ATLAS_REQUIRE("height"), ATLAS_REQUIRE("ground")
local CACHE = arg[1]
local function exists(p) local f = io.open(p, "rb"); if f then f:close() return true end end
local RD = os.getenv("RASTER_DIR")
local tot = { cells = 0, ms = 0, problems = 0, worst_water = 0, worst_slope = 0, steep = 0, walls = 0 }
for i = 2, #arg do
  local tx, ty = arg[i]:match("(%d+)%D+(%d+)")
  tx, ty = tonumber(tx), tonumber(ty)
  -- tiles at the edge of the test data lack elevation around them: they are not tested
  local all = true
  for dx = -1, 1 do for dy = -1, 1 do
    if not exists(CACHE .. "/terrarium/14/" .. (tx + dx) .. "_" .. (ty + dy) .. ".dat") then all = false end
  end end
  if not all then tot.edge = (tot.edge or 0) + 1; goto continue end
  local L = mvt.decode(readfile(CACHE .. "/omt/14/" .. tx .. "_" .. ty .. ".dat"))
  local H = height.new()
  for dx = -1, 1 do for dy = -1, 1 do
    local p = CACHE .. "/mapterhorn/14/" .. (tx + dx) .. "_" .. (ty + dy) .. ".dat"
    if os.getenv("NO_MAPTERHORN") or not exists(p) then p = CACHE .. "/terrarium/14/" .. (tx + dx) .. "_" .. (ty + dy) .. ".dat" end
    if exists(p) then H:add(tx + dx, ty + dy, readfile(p)) end
  end end
  local lat = math.deg(math.atan(math.sinh(math.pi * (1 - 2 * (ty + 0.5) / 16384))))
  local W = 512
  local img = RD and {} or nil
  for cy = 0, 7 do for cx = 0, 7 do
    local t0 = os.clock()
    local r = cell.build(L, cx, cy, lat)
    local gx0, gy0 = (tx * 8 + cx) * 8192, (ty * 8 + cy) * 8192
    local g = ground.heights(r, H, gx0, gy0)
    local ms = (os.clock() - t0) * 1000
    tot.cells = tot.cells + 1; tot.ms = tot.ms + ms
    tot.worst_water = math.max(tot.worst_water, g.stats.water_range)
    tot.worst_slope = math.max(tot.worst_slope, g.stats.road_worst_slope)
    tot.steep = tot.steep + g.stats.road_steep_triangles
    tot.walls = tot.walls + g.stats.walls
    local probs = {}
    for _, p in ipairs(r.problems) do probs[#probs + 1] = p end
    for _, p in ipairs(g.problems) do probs[#probs + 1] = p end
    if #probs > 0 then tot.problems = tot.problems + 1; print("PROBLEM", tx, ty, cx, cy, table.concat(probs, "; ")) end
    if img then
      -- write triangles with heights for the picture tool: x y h per corner + surface
      local f = io.open(string.format("%s/%d_%d_%d_%d.txt", RD, tx, ty, cx, cy), "w")
      f:write(r.S, " ", r.nt, " ", r.mpu, "\n")
      local V, X, Y = r.V, r.X, r.Y
      for t = 1, r.nt do
        local o = 3 * t - 3
        local wet = cell.WATER[r.surf[t]]
        local parts = {}
        for k = 1, 3 do
          local v = V[o + k]
          parts[#parts + 1] = string.format("%d %d %.4f", X[v], Y[v], wet and g.water[v] or g.land[v])
        end
        f:write(table.concat(parts, " "), " ", r.surf[t], "\n")
      end
      f:close()
    end
  end end
  ::continue::
end
if tot.edge then print(tot.edge .. " tiles at the edge of the test data skipped (no elevation around them)") end
print(string.format("cells %d  mean %.1f ms (cut + heights)  cells with problems %d  water range max %.2f m  road slope max %.0f %%  steep road triangles %d  wall edges %d",
  tot.cells, tot.ms / tot.cells, tot.problems, tot.worst_water, tot.worst_slope * 100, tot.steep, tot.walls))
