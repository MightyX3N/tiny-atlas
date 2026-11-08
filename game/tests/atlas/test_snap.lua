-- Adversarial segment sets through snap rounding + constrained triangulation: expect no failures at all.
dofile((debug.getinfo(1,"S").source:sub(2):match("(.*/)") or "./") .. "common.lua")
local cdt, cell = ATLAS_REQUIRE("cdt"), ATLAS_REQUIRE("cell")
local S = cell.S
math.randomseed(tonumber(arg[1]) or 7)
local rounds, fails, worst = tonumber(arg[2]) or 200, 0, 0
for round = 1, rounds do
  local T = cdt.new(S)
  local SA, SB, keys = {}, {}, {}
  local function seg(x1, y1, x2, y2)
    local p, q = cdt.point(T, x1, y1), cdt.point(T, x2, y2)
    if p == q then return end
    local k = p < q and (p * 1048576 + q) or (q * 1048576 + p)
    if keys[k] then return end
    keys[k] = true; SA[#SA + 1] = p; SB[#SB + 1] = q
  end
  local R = math.random
  local kind = round % 5
  local n = R(20, 600)
  for i = 1, n do
    if kind == 0 then                                    -- slope +-1 lines: crossings on half-integers
      local x, y, L = R(0, S), R(0, S), R(1, 3000)
      local sx = R(0, 1) == 0 and 1 or -1
      seg(x, y, math.max(0, math.min(S, x + L)), math.max(0, math.min(S, y + sx * L)))
    elseif kind == 1 then                                -- nearly parallel long lines, about a unit apart
      local y = R(0, S - 40)
      seg(0, y, S, y + R(0, 40))
    elseif kind == 2 then                                -- tiny segments in a small box
      local x, y = R(4000, 4010), R(4000, 4010)
      seg(x, y, R(4000, 4010), R(4000, 4010))
    elseif kind == 3 then                                -- collinear overlapping pieces on a few lines
      local L = R(1, 5)
      local a, b = R(0, S), R(0, S)
      if L == 1 then seg(a, 100, b, 100) elseif L == 2 then seg(300, a, 300, b)
      else local t1, t2 = R(0, 512), R(0, 512); seg(t1 * 16, t1 * 8, t2 * 16, t2 * 8) end
    else                                                 -- anything
      seg(R(0, S), R(0, S), R(0, S), R(0, S))
    end
  end
  cell._split_all(T, SA, SB, {}, function() end)
  cdt.insert_points(T)
  local f = 0
  for s = 1, #SA do if not cdt.constrain(T, SA[s], SB[s]) then f = f + 1 end end
  local bad = cdt.check(T)
  if f > 0 or #bad > 0 then
    fails = fails + 1
    print("round", round, "kind", kind, "segments", #SA, "constraint failures", f, bad[1] or "")
  end
  if #SA > worst then worst = #SA end
end
print(string.format("%d rounds, %d with failures (largest set %d segments after cutting)", rounds, fails, worst))
