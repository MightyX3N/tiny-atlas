-- Build cells from cached vector tiles. usage: test_cells.lua tiles.txt [max tiles] [dump dir] [cells per tile]
if os.getenv("JIT_OFF") == "1" then jit.off(); print("JIT off") end
dofile((debug.getinfo(1,"S").source:sub(2):match("(.*/)") or "./") .. "common.lua")
local mvt, cell = ATLAS_REQUIRE("mvt"), ATLAS_REQUIRE("cell")
local list, maxn, dump, per = arg[1], tonumber(arg[2]) or 1e9, arg[3], tonumber(arg[4]) or 64
local n, times, worst, probs = 0, {}, { ms = 0 }, 0
local tot = { ms_collect = 0, ms_split = 0, ms_points = 0, ms_constrain = 0, ms_label = 0, ms_clean = 0 }
for line in io.lines(list) do
  local path, tx, ty = line:match("(%S+) (%d+) (%d+)")
  tx, ty = tonumber(tx), tonumber(ty)
  n = n + 1; if n > maxn then break end
  local L = mvt.decode(readfile(path))
  local lat = math.deg(math.atan(math.sinh(math.pi * (1 - 2 * (ty + 0.5) / 16384))))
  local k = 0
  local RP = tonumber(os.getenv("RASTER_PX") or "0")   -- write one picture per tile: surface index per pixel
  local grid, SURF_ID = nil, { ground=1, building=2, road=3, path=4, rail=5, pier=6, water=7, paved=8, sand=9, wetland=10,
    wood=11, park=12, grass=13, pitch=14, cemetery=15, farmland=16, rock=17, ice=18, residential=19, commercial=20, industrial=21 }
  if RP > 0 then grid = {} for i = 1, (8*RP)*(8*RP) do grid[i] = 0 end end
  for cy = 0, 7 do for cx = 0, 7 do
    k = k + 1
    if per >= 64 or (k * 7919) % 64 < per then
      local ok, r = pcall(cell.build, L, cx, cy, lat)
      if not ok then print("ERROR", tx, ty, cx, cy, r); probs = probs + 1
      else
        local st = r.stats
        times[#times + 1] = st.ms_total
        for key in pairs(tot) do tot[key] = tot[key] + st[key] end
        if st.ms_total > worst.ms then worst = { ms = st.ms_total, id = string.format("%d/%d %d,%d", tx, ty, cx, cy), st = st } end
        if #r.problems > 0 then probs = probs + 1; print("PROBLEM", tx, ty, cx, cy, table.concat(r.problems, "; ")) end
        if grid then
          local W = 8 * RP
          local k2 = RP / r.S
          local V, X, Y = r.V, r.X, r.Y
          for t = 1, r.nt do
            local o = 3 * t - 3
            local x1, y1 = cx*RP + X[V[o+1]]*k2, cy*RP + Y[V[o+1]]*k2
            local x2, y2 = cx*RP + X[V[o+2]]*k2, cy*RP + Y[V[o+2]]*k2
            local x3, y3 = cx*RP + X[V[o+3]]*k2, cy*RP + Y[V[o+3]]*k2
            local id = SURF_ID[r.surf[t]] or 255
            local ya, yb = math.max(0, math.floor(math.min(y1,y2,y3))), math.min(W-1, math.ceil(math.max(y1,y2,y3)))
            for py = ya, yb do
              local yc = py + 0.5
              local lo, hi = 1e9, -1e9
              local function e(ax, ay, bx, by)
                if (ay <= yc and by > yc) or (by <= yc and ay > yc) then
                  local xx = ax + (yc - ay) / (by - ay) * (bx - ax)
                  if xx < lo then lo = xx end
                  if xx > hi then hi = xx end
                end
              end
              e(x1,y1,x2,y2) e(x2,y2,x3,y3) e(x3,y3,x1,y1)
              if lo <= hi then
                for px = math.max(0, math.ceil(lo - 0.5)), math.min(W-1, math.ceil(hi - 0.5) - 1) do grid[py*W+px+1] = id end
              end
            end
          end
        end
        if dump then
          local f = io.open(string.format("%s/%d_%d_%d_%d.txt", dump, tx, ty, cx, cy), "w")
          f:write(string.format("%d %d %.5f\n", r.S, r.nt, r.mpu))
          local V, X, Y = r.V, r.X, r.Y
          for t = 1, r.nt do
            local o = 3 * t - 3
            f:write(X[V[o+1]], " ", Y[V[o+1]], " ", X[V[o+2]], " ", Y[V[o+2]], " ", X[V[o+3]], " ", Y[V[o+3]], " ", r.surf[t],
              " ", r.C[o+1] and 1 or 0, r.C[o+2] and 1 or 0, r.C[o+3] and 1 or 0, "\n")
          end
          f:close()
        end
      end
    end
  end end
  if grid then
    local W = 8 * RP
    local f = io.open(string.format("%s/r_%d_%d.pgm", os.getenv("RASTER_DIR"), tx, ty), "wb")
    f:write("P5\n", W, " ", W, "\n255\n")
    local parts = {}
    for i = 1, W * W, 4096 do parts[#parts+1] = string.char(unpack(grid, i, math.min(W*W, i+4095))) end
    f:write(table.concat(parts)); f:close()
  end
end
table.sort(times)
local sum = 0 for _, v in ipairs(times) do sum = sum + v end
print(string.format("cells %d  mean %.1f ms  median %.1f  p95 %.1f  max %.1f (%s)  cells with problems %d",
  #times, sum / #times, times[math.floor(#times / 2) + 1], times[math.floor(#times * 0.95) + 1], times[#times], worst.id, probs))
local parts = {} for k, v in pairs(tot) do parts[#parts+1] = string.format("%s %.0f%%", k:sub(4), v / sum * 100) end
table.sort(parts) print("time split: " .. table.concat(parts, "  "))
if worst.st then local s = worst.st print(string.format("worst: shapes %d segments %d->%d points %d tris %d regions %d", s.shapes, s.segments_in, s.segments, s.points, s.triangles, s.regions)) end
