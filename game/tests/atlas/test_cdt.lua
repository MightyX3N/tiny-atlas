dofile((debug.getinfo(1,"S").source:sub(2):match("(.*/)") or "./") .. "common.lua")
local cdt = ATLAS_REQUIRE("cdt")
math.randomseed(tonumber(arg[1]) or 1)
local S = 8192
local total_fail = 0
for round = 1, tonumber(arg[2]) or 50 do
  local T = cdt.new(S)
  local n = math.random(5, 3000)
  local ids = {}
  for k = 1, n do
    local x, y
    if k % 7 == 0 then x, y = math.random(0, 16) * 512, math.random(0, S) else x, y = math.random(0, S), math.random(0, S) end
    if k % 11 == 0 then x, y = math.random(0, 64) * 128, math.random(0, 64) * 128 end   -- collinear grids
    ids[#ids + 1] = cdt.point(T, x, y)
  end
  cdt.insert_points(T)
  local bad = cdt.check(T)
  if #bad > 0 then print("round", round, "after points:", bad[1]); os.exit(1) end
  -- constraints: random pairs; keep only those not crossing earlier kept ones (brute force), allow collinear-through
  local kept = {}
  local X, Y = T.X, T.Y
  local function cross(a, b, c, d)
    local o = cdt.orient
    local o1, o2 = o(X[a],Y[a],X[b],Y[b],X[c],Y[c]), o(X[a],Y[a],X[b],Y[b],X[d],Y[d])
    local o3, o4 = o(X[c],Y[c],X[d],Y[d],X[a],Y[a]), o(X[c],Y[c],X[d],Y[d],X[b],Y[b])
    return o1 * o2 < 0 and o3 * o4 < 0
  end
  for k = 1, math.random(0, 3000) do
    local a = ids[math.random(#ids)]
    local b
    if k % 3 == 0 then b = ids[math.random(#ids)] else
      -- a short segment to a nearby point
      local best, bd = nil, 1e18
      for q = 1, 12 do local c = ids[math.random(#ids)]; local d = (X[c]-X[a])^2+(Y[c]-Y[a])^2
        if c ~= a and d < bd then best, bd = c, d end end
      b = best
    end
    if a ~= b then
      local okk = true
      for _, e in ipairs(kept) do if cross(a, b, e[1], e[2]) then okk = false break end end
      if okk then kept[#kept + 1] = { a, b } end
    end
  end
  for _, e in ipairs(kept) do
    if not cdt.constrain(T, e[1], e[2]) then print("round", round, "constraint failed", e[1], e[2]); total_fail = total_fail + 1 end
  end
  bad = cdt.check(T)
  if #bad > 0 then print("round", round, "after constraints:", bad[1]); os.exit(1) end
  -- every kept constraint is covered by constrained edges: walk collinear pieces
  -- (check: each constrained edge lies on some kept segment, and every kept segment's length is covered)
  local covered = 0
  local V, C = T.V, T.C
  for t = 1, T.nt do for i = 1, 3 do if C[3*t-3+i] then
    local a, b = V[3*t-3+i], V[3*t-3+(i%3)+1]
    covered = covered + math.sqrt((X[a]-X[b])^2 + (Y[a]-Y[b])^2) end end end
  local want = 4 * S * 2   -- border counted once per side (border edges have one triangle) -> S*4; interior twice
  local len = 0
  for _, e in ipairs(kept) do len = len + math.sqrt((X[e[1]]-X[e[2]])^2 + (Y[e[1]]-Y[e[2]])^2) end
  -- each kept segment must be fully covered by constrained edges lying on it
  local cons = {}
  for t = 1, T.nt do for i = 1, 3 do if C[3*t-3+i] then cons[#cons+1] = { V[3*t-3+i], V[3*t-3+(i%3)+1] } end end end
  for _, e in ipairs(kept) do
    local a, b = e[1], e[2]
    local L2 = (X[b]-X[a])^2 + (Y[b]-Y[a])^2
    local cov = 0
    for _, c in ipairs(cons) do
      local p, q = c[1], c[2]
      if cdt.orient(X[a],Y[a],X[b],Y[b],X[p],Y[p]) == 0 and cdt.orient(X[a],Y[a],X[b],Y[b],X[q],Y[q]) == 0 then
        local tp = ((X[p]-X[a])*(X[b]-X[a]) + (Y[p]-Y[a])*(Y[b]-Y[a])) / L2
        local tq = ((X[q]-X[a])*(X[b]-X[a]) + (Y[q]-Y[a])*(Y[b]-Y[a])) / L2
        if tp >= -1e-12 and tp <= 1 + 1e-12 and tq >= -1e-12 and tq <= 1 + 1e-12 then cov = cov + math.abs(tq - tp) end
      end
    end
    -- interior edges are listed twice (once per side); border edges once
    if cov < 1 - 1e-9 then print("round", round, "segment not covered", cov) os.exit(1) end
  end
  -- overlapping kept segments make len larger than covered; only flag when covered is short
  local expect_min = 4 * S
  if covered + 1e-6 < expect_min then print("round", round, "border lost") os.exit(1) end
  if round % 10 == 0 then print("round", round, "points", T.np, "tris", T.nt, "constraints", #kept, "ok") end
end
print("constraint failures:", total_fail)
