-- Constrained Delaunay triangulation on integer coordinates, in plain Lua. Shared by every game.
--
-- Points are integers in [0, S] (S <= 16384), so orientation tests are exact in doubles. The triangulation
-- starts as the square [0,S]^2 (two triangles); points are inserted one by one (walk + split + Lawson flips),
-- then constraint segments are forced in by edge flipping (Sloan 1993) and Delaunay is restored around them.
--
--   local T = cdt.new(S)
--   local id = cdt.point(T, x, y)          -- id of the (deduplicated) point; does not insert it yet
--   cdt.insert_points(T)                   -- triangulate all points added so far (spatially sorted)
--   local ok = cdt.constrain(T, a, b)      -- force segment a-b in; false if it conflicts with a constraint
--
-- Storage: triangle t has vertices V[3t-2..3t] (counter-clockwise); edge i runs from vertex i to vertex i+1;
-- N[3t-3+i] is the triangle across edge i (false at the square's border); C[3t-3+i] marks a constraint.
local floor = math.floor

local M = {}

local function orient(ax, ay, bx, by, cx, cy)
  return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
end
M.orient = orient

-- > 0 when d lies inside the circle through counter-clockwise a, b, c
local function incircle(ax, ay, bx, by, cx, cy, dx, dy)
  local adx, ady, bdx, bdy, cdx, cdy = ax - dx, ay - dy, bx - dx, by - dy, cx - dx, cy - dy
  local ad, bd, cd = adx * adx + ady * ady, bdx * bdx + bdy * bdy, cdx * cdx + cdy * cdy
  return adx * (bdy * cd - bd * cdy) - ady * (bdx * cd - bd * cdx) + ad * (bdx * cdy - bdy * cdx)
end

local NXT = { 2, 3, 1 }
local PRV = { 3, 1, 2 }

function M.new(S)
  local T = { S = S, X = {}, Y = {}, np = 0, key = {}, V = {}, N = {}, C = {}, nt = 0, VT = {},
    pending = {}, last = 1, fails = 0 }
  local c1, c2, c3, c4 = M.point(T, 0, 0), M.point(T, S, 0), M.point(T, S, S), M.point(T, 0, S)
  T.pending = {}
  -- positive orient: 0,0 -> S,0 -> S,S (counter-clockwise with y up; the sign is all that matters)
  T.V = { c1, c2, c3, c1, c3, c4 }
  T.N = { false, false, 2, 1, false, false }
  T.C = { true, true, false, false, true, true }
  T.nt = 2
  T.VT[c1], T.VT[c2], T.VT[c3], T.VT[c4] = 1, 1, 1, 2
  T.inserted = { [c1] = true, [c2] = true, [c3] = true, [c4] = true }
  return T
end

function M.point(T, x, y)
  local k = x * 32768 + y
  local id = T.key[k]
  if id then return id end
  local n = T.np + 1
  T.np = n; T.X[n] = x; T.Y[n] = y; T.key[k] = n
  T.pending[#T.pending + 1] = n
  return n
end

local function set(T, t, a, b, c, na, nb, nc, ca, cb, cc)
  local o = 3 * t - 3
  local V, N, C = T.V, T.N, T.C
  V[o + 1], V[o + 2], V[o + 3] = a, b, c
  N[o + 1], N[o + 2], N[o + 3] = na, nb, nc
  C[o + 1], C[o + 2], C[o + 3] = ca, cb, cc
  T.VT[a], T.VT[b], T.VT[c] = t, t, t
end

-- point the neighbour u's back-reference from `old` to `new`
local function relink(T, u, old, new)
  if not u then return end
  local o = 3 * u - 3
  local N = T.N
  if N[o + 1] == old then N[o + 1] = new elseif N[o + 2] == old then N[o + 2] = new elseif N[o + 3] == old then N[o + 3] = new end
end

-- flip edge i of triangle t; returns the two triangles, t = (a, d, c) and u = (d, b, c), where the old edge was
-- a-b and c, d were the opposite vertices. The new edge c-d is edge 2 of t and edge 3 of u.
local function flip(T, t, i)
  local V, N, C = T.V, T.N, T.C
  local o = 3 * t - 3
  local a, b, c = V[o + i], V[o + NXT[i]], V[o + PRV[i]]
  local u = N[o + i]
  local ou = 3 * u - 3
  local j = (N[ou + 1] == t) and 1 or ((N[ou + 2] == t) and 2 or 3)
  local d = V[ou + PRV[j]]
  local n_bc, c_bc = N[o + NXT[i]], C[o + NXT[i]]
  local n_ca, c_ca = N[o + PRV[i]], C[o + PRV[i]]
  local n_ad, c_ad = N[ou + NXT[j]], C[ou + NXT[j]]
  local n_db, c_db = N[ou + PRV[j]], C[ou + PRV[j]]
  set(T, t, a, d, c, n_ad, u, n_ca, c_ad, false, c_ca)
  set(T, u, d, b, c, n_db, n_bc, t, c_db, c_bc, false)
  relink(T, n_ad, u, t)
  relink(T, n_bc, t, u)
  return t, u
end
M.flip = flip

-- restore Delaunay with a stack of edges (t, i); constrained and border edges are never flipped
local function legalize(T, stack, sn)
  local V, N, C, X, Y = T.V, T.N, T.C, T.X, T.Y
  local guard = 0
  local tick, steps = T.tick, 0
  while sn > 0 do
    steps = steps + 1
    if tick and steps % 512 == 0 then tick() end
    local i = stack[sn]; local t = stack[sn - 1]; sn = sn - 2
    local o = 3 * t - 3
    local u = N[o + i]
    if u and not C[o + i] then
      local a, b, c = V[o + i], V[o + NXT[i]], V[o + PRV[i]]
      local ou = 3 * u - 3
      local j = (N[ou + 1] == t) and 1 or ((N[ou + 2] == t) and 2 or 3)
      local d = V[ou + PRV[j]]
      if incircle(X[a], Y[a], X[b], Y[b], X[c], Y[c], X[d], Y[d]) > 0 then
        guard = guard + 1
        if guard > 1000000 then error("cdt: legalize does not terminate") end
        local t2, u2 = flip(T, t, i)
        -- the edges that might now be illegal are the far sides: a-d (edge 1 of t2) and d-b (edge 1 of u2)
        stack[sn + 1] = t2; stack[sn + 2] = 1
        stack[sn + 3] = u2; stack[sn + 4] = 1
        sn = sn + 4
      end
    end
  end
end

-- find the triangle containing point p by walking from T.last. Returns t, and the edge index if p is on an edge.
local function locate(T, px, py)
  local V, N, X, Y = T.V, T.N, T.X, T.Y
  local t = T.last
  local steps = 0
  while true do
    steps = steps + 1
    if steps > 4 * T.nt + 100 then error("cdt: point location does not terminate") end
    local o = 3 * t - 3
    local moved = false
    local start = (steps % 3) + 1                -- rotate the starting edge so the walk can't cycle
    local on = nil
    for s = 0, 2 do
      local i = (start + s - 1) % 3 + 1
      local a, b = V[o + i], V[o + NXT[i]]
      local d = orient(X[a], Y[a], X[b], Y[b], px, py)
      if d < 0 then
        local u = N[o + i]
        if not u then error("cdt: point outside the square") end
        t = u; moved = true
        break
      elseif d == 0 then
        on = on and -1 or i                       -- -1: on two edges = on a vertex
      end
    end
    if not moved then
      T.last = t
      return t, on
    end
  end
end

local function insert(T, p)
  local X, Y, V, N, C = T.X, T.Y, T.V, T.N, T.C
  local t, on = locate(T, X[p], Y[p])
  if on == -1 then return false end               -- already a vertex (cannot happen: points are deduplicated)
  local o = 3 * t - 3
  local stack = T.stack or {}; T.stack = stack
  if not on then
    local a, b, c = V[o + 1], V[o + 2], V[o + 3]
    local nab, nbc, nca = N[o + 1], N[o + 2], N[o + 3]
    local cab, cbc, cca = C[o + 1], C[o + 2], C[o + 3]
    local t2, t3 = T.nt + 1, T.nt + 2
    T.nt = T.nt + 2
    set(T, t, a, b, p, nab, t2, t3, cab, false, false)
    set(T, t2, b, c, p, nbc, t3, t, cbc, false, false)
    set(T, t3, c, a, p, nca, t, t2, cca, false, false)
    relink(T, nbc, t, t2)
    relink(T, nca, t, t3)
    stack[1], stack[2], stack[3], stack[4], stack[5], stack[6] = t, 1, t2, 1, t3, 1
    legalize(T, stack, 6)
  else
    local i = on
    local a, b, c = V[o + i], V[o + NXT[i]], V[o + PRV[i]]
    local n_bc, c_bc = N[o + NXT[i]], C[o + NXT[i]]
    local n_ca, c_ca = N[o + PRV[i]], C[o + PRV[i]]
    local cab = C[o + i]
    local u = N[o + i]
    local t2 = T.nt + 1
    if u then
      local ou = 3 * u - 3
      local j = (N[ou + 1] == t) and 1 or ((N[ou + 2] == t) and 2 or 3)
      local d = V[ou + PRV[j]]
      local n_ad, c_ad = N[ou + NXT[j]], C[ou + NXT[j]]
      local n_db, c_db = N[ou + PRV[j]], C[ou + PRV[j]]
      local u2 = T.nt + 2
      T.nt = T.nt + 2
      set(T, t, a, p, c, u2, t2, n_ca, cab, false, c_ca)
      set(T, t2, p, b, c, u, n_bc, t, cab, c_bc, false)
      set(T, u, b, p, d, t2, u2, n_db, cab, false, c_db)
      set(T, u2, p, a, d, t, n_ad, u, cab, c_ad, false)
      relink(T, n_bc, t, t2)
      relink(T, n_ad, u, u2)
      stack[1], stack[2], stack[3], stack[4] = t, 3, t2, 2
      stack[5], stack[6], stack[7], stack[8] = u, 3, u2, 2
      legalize(T, stack, 8)
    else
      T.nt = T.nt + 1
      set(T, t, a, p, c, false, t2, n_ca, cab, false, c_ca)
      set(T, t2, p, b, c, false, n_bc, t, cab, c_bc, false)
      relink(T, n_bc, t, t2)
      stack[1], stack[2], stack[3], stack[4] = t, 3, t2, 2
      legalize(T, stack, 4)
    end
  end
  T.inserted[p] = true
  return true
end

-- insert every pending point, in an order that keeps the walks short (rows of 512-unit bands, snaking)
function M.insert_points(T)
  local P, X, Y = T.pending, T.X, T.Y
  local band = 512
  table.sort(P, function(p, q)
    local bp, bq = floor(Y[p] / band), floor(Y[q] / band)
    if bp ~= bq then return bp < bq end
    if bp % 2 == 0 then return X[p] < X[q] end
    return X[p] > X[q]
  end)
  local tick = T.tick
  for k = 1, #P do
    local p = P[k]
    if not T.inserted[p] then insert(T, p) end
    if tick then tick() end
  end
  T.pending = {}
end

-- the triangles around vertex v as (t, index of v in t), clockwise then counter-clockwise from VT[v]
local function around(T, v, fn)
  local V, N = T.V, T.N
  local t0 = T.VT[v]
  local t = t0
  repeat
    local o = 3 * t - 3
    local i = (V[o + 1] == v) and 1 or ((V[o + 2] == v) and 2 or 3)
    if fn(t, i) then return true end
    t = N[o + i]                                   -- across the edge leaving v: the next triangle clockwise
  until not t or t == t0
  if t == t0 then return false end
  t = t0
  while true do
    local o = 3 * t - 3
    local i = (V[o + 1] == v) and 1 or ((V[o + 2] == v) and 2 or 3)
    t = N[o + PRV[i]]                              -- across the edge entering v: counter-clockwise
    if not t then return false end
    o = 3 * t - 3
    i = (V[o + 1] == v) and 1 or ((V[o + 2] == v) and 2 or 3)
    if fn(t, i) then return true end
  end
end
M.around = around

-- the edge a-b as (t, i) with V[t][i] == a and V[t][i+1] == b, or nil
function M.find_edge(T, a, b)
  local V = T.V
  local rt, ri
  around(T, a, function(t, i)
    if V[3 * t - 3 + NXT[i]] == b then rt, ri = t, i; return true end
  end)
  return rt, ri
end

local function mark(T, t, i, val)
  local o = 3 * t - 3
  T.C[o + i] = val
  local u = T.N[o + i]
  if u then
    local ou = 3 * u - 3
    local N = T.N
    local j = (N[ou + 1] == t) and 1 or ((N[ou + 2] == t) and 2 or 3)
    T.C[ou + j] = val
  end
end
M.mark = mark

-- Edges crossed by segment a-b, walking from a. Returns "edge" if a-b already exists, "vertex", c if the segment
-- runs through vertex c, "conflict" if it crosses a constraint, or "cross", list of crossed edges {v1, v2, ...}.
local function crossings(T, a, b)
  local V, N, C, X, Y = T.V, T.N, T.C, T.X, T.Y
  local ax, ay, bx, by = X[a], Y[a], X[b], Y[b]
  local status, hit, ft, fi
  around(T, a, function(t, i)
    local o = 3 * t - 3
    local v1, v2 = V[o + NXT[i]], V[o + PRV[i]]
    if v1 == b or v2 == b then status = "edge"; return true end
    local o1 = orient(ax, ay, X[v1], Y[v1], bx, by)
    local o2 = orient(ax, ay, X[v2], Y[v2], bx, by)
    if o1 == 0 and (X[v1] - ax) * (bx - ax) + (Y[v1] - ay) * (by - ay) > 0 then status = "vertex"; hit = v1; return true end
    if o2 == 0 and (X[v2] - ax) * (bx - ax) + (Y[v2] - ay) * (by - ay) > 0 then status = "vertex"; hit = v2; return true end
    if o1 > 0 and o2 < 0 then ft, fi = t, NXT[i]; return true end   -- crosses the far edge v1-v2
  end)
  if status then return status, hit end
  if not ft then return "conflict" end
  local list = {}
  local t, i = ft, fi
  while true do
    local o = 3 * t - 3
    local v1, v2 = V[o + i], V[o + NXT[i]]
    if C[o + i] then return "conflict" end
    list[#list + 1] = v1; list[#list + 1] = v2
    local u = N[o + i]
    if not u then return "conflict" end
    local ou = 3 * u - 3
    local j = (N[ou + 1] == t) and 1 or ((N[ou + 2] == t) and 2 or 3)
    local w = V[ou + PRV[j]]
    if w == b then return "cross", list end
    local ow = orient(ax, ay, bx, by, X[w], Y[w])
    if ow == 0 then return "vertex", w end
    -- u = (v2, v1, w) from index j; v1 is right of a->b and v2 left. Edge NXT[j] runs v1 -> w and edge
    -- PRV[j] runs w -> v2: the segment leaves through the one whose ends are on opposite sides.
    if ow > 0 then t, i = u, NXT[j] else t, i = u, PRV[j] end
  end
end

local function crosses_strictly(T, a, b, c, d)
  local X, Y = T.X, T.Y
  local o1 = orient(X[a], Y[a], X[b], Y[b], X[c], Y[c])
  local o2 = orient(X[a], Y[a], X[b], Y[b], X[d], Y[d])
  if o1 * o2 >= 0 then return false end
  local o3 = orient(X[c], Y[c], X[d], Y[d], X[a], Y[a])
  local o4 = orient(X[c], Y[c], X[d], Y[d], X[b], Y[b])
  return o3 * o4 < 0
end

-- force segment a-b into the triangulation as a constraint
function M.constrain(T, a, b)
  local work = { a, b }
  local ok = true
  local rounds = 0
  while #work > 0 do
    local bb = table.remove(work); local aa = table.remove(work)
    rounds = rounds + 1
    if rounds > 10000 then return false end
    local status, data = crossings(T, aa, bb)
    if status == "edge" then
      local t, i = M.find_edge(T, aa, bb)
      if not t then t, i = M.find_edge(T, bb, aa) end
      mark(T, t, i, true)
    elseif status == "vertex" then
      work[#work + 1] = aa; work[#work + 1] = data
      work[#work + 1] = data; work[#work + 1] = bb
    elseif status == "conflict" then
      ok = false; T.fails = T.fails + 1
    else
      -- Sloan: flip crossed edges whose quad is convex until none cross; keep the new edges for re-Delaunay
      local q, qh, qt = {}, 1, 0
      for k = 1, #data, 2 do qt = qt + 1; q[qt] = { data[k], data[k + 1] } end
      local fresh = {}
      local X, Y, V = T.X, T.Y, T.V
      local guard = 0
      while qh <= qt do
        guard = guard + 1
        if guard > 200000 then ok = false; T.fails = T.fails + 1; break end
        local e = q[qh]; qh = qh + 1
        local t, i = M.find_edge(T, e[1], e[2])
        if not t then
          -- the edge was flipped away already by an earlier flip in this queue; nothing to do
        else
          local o = 3 * t - 3
          local u = T.N[o + i]
          local ou = 3 * u - 3
          local j = (T.N[ou + 1] == t) and 1 or ((T.N[ou + 2] == t) and 2 or 3)
          local c, d = V[o + PRV[i]], V[ou + PRV[j]]
          local v1, v2 = e[1], e[2]
          local s1 = orient(X[c], Y[c], X[d], Y[d], X[v1], Y[v1])
          local s2 = orient(X[c], Y[c], X[d], Y[d], X[v2], Y[v2])
          if s1 * s2 < 0 then
            flip(T, t, i)
            if crosses_strictly(T, aa, bb, c, d) then
              qt = qt + 1; q[qt] = { c, d }
            else
              fresh[#fresh + 1] = { c, d }
            end
          else
            qt = qt + 1; q[qt] = e
          end
        end
      end
      local t, i = M.find_edge(T, aa, bb)
      if not t then t, i = M.find_edge(T, bb, aa) end
      if t then
        mark(T, t, i, true)
        -- restore Delaunay on the new edges (never the constraint itself)
        local changed, passes = true, 0
        while changed and passes < 50 do
          changed = false; passes = passes + 1
          for k = 1, #fresh do
            local e = fresh[k]
            local et, ei = M.find_edge(T, e[1], e[2])
            if et and not T.C[3 * et - 3 + ei] then
              local o = 3 * et - 3
              local u = T.N[o + ei]
              if u then
                local ou = 3 * u - 3
                local j = (T.N[ou + 1] == et) and 1 or ((T.N[ou + 2] == et) and 2 or 3)
                local pa, pb, pc, pd = V[o + ei], V[o + NXT[ei]], V[o + PRV[ei]], V[ou + PRV[j]]
                if incircle(X[pa], Y[pa], X[pb], Y[pb], X[pc], Y[pc], X[pd], Y[pd]) > 0 then
                  flip(T, et, ei)
                  e[1], e[2] = pc, pd
                  changed = true
                end
              end
            end
          end
        end
      elseif ok then
        ok = false; T.fails = T.fails + 1
      end
    end
  end
  return ok
end

-- Lawson flips over every unconstrained edge until the triangulation is (constrained) Delaunay again
function M.delaunay(T)
  local stack, sn = {}, 0
  for t = 1, T.nt do
    for i = 1, 3 do stack[sn + 1] = t; stack[sn + 2] = i; sn = sn + 2 end
  end
  legalize(T, stack, sn)
end

-- structural self-check: counter-clockwise triangles, symmetric neighbours, area adds up to the square
function M.check(T)
  local V, N, C, X, Y = T.V, T.N, T.C, T.X, T.Y
  local area2, bad = 0, {}
  for t = 1, T.nt do
    if T.tick and t % 512 == 0 then T.tick() end
    local o = 3 * t - 3
    local a, b, c = V[o + 1], V[o + 2], V[o + 3]
    local d = orient(X[a], Y[a], X[b], Y[b], X[c], Y[c])
    if d <= 0 then bad[#bad + 1] = "triangle " .. t .. " not counter-clockwise" end
    area2 = area2 + d
    for i = 1, 3 do
      local u = N[o + i]
      if u then
        local ou = 3 * u - 3
        local j = (N[ou + 1] == t) and 1 or ((N[ou + 2] == t) and 2 or ((N[ou + 3] == t) and 3 or nil))
        if not j then bad[#bad + 1] = "neighbour of " .. t .. " does not point back"
        elseif V[ou + j] ~= V[o + NXT[i]] or V[ou + NXT[j]] ~= V[o + i] then bad[#bad + 1] = "shared edge of " .. t .. " mismatched"
        elseif C[ou + j] ~= C[o + i] then bad[#bad + 1] = "constraint flag of " .. t .. " not symmetric" end
      end
    end
  end
  if area2 ~= 2 * T.S * T.S then bad[#bad + 1] = string.format("area %.0f, expected %.0f", area2 / 2, T.S * T.S) end
  return bad
end

return M
