-- Puts a route onto the map's roads and paths (map matching), so the rider rides on a road or path of the right
-- width instead of wherever the GPS track happened to wander. Shared by every game.
--
-- The method is the hidden Markov model map matching of Newson & Krumm ("Hidden Markov Map Matching Through Noise
-- and Sparseness", 2009), the one OSRM and Valhalla's Meili use: every route point has candidates (the nearest point
-- on each road or path near it, plus "off the map"); how likely each is comes from its distance to the GPS point
-- and its heading; moving from one candidate to the next costs more the more the step on the map differs from the
-- step along the route (a jump to a parallel road costs a lot, staying on one road costs nothing). Viterbi picks the
-- cheapest chain. It runs ahead of the rider as the map tiles come in, and settles each point once the route is
-- 150 m past it.
--
-- Then the rider is put in a sensible place on what was matched: the middle of a path, cycleway or track; on a
-- road, the middle of the lane on their side (right, or left where traffic keeps left). Where the route leaves the
-- mapped roads and paths, a path of path width is added to the map under it, so there is always ground under the
-- rider.
--
--   local MT = match.new(R, W)      R: route.lua route (raw GPX positions), W: world.lua
--   MT:advance(s, tick)             match the route up to s metres (waits for map tiles; call inside a build job)
--   MT:finish(tick)                 match the whole route
--   R.way[k]                        what point k is on: { kind = "road" | "path" | "off", width = m, class = ... }
local M = {}
local floor, sqrt, abs, max, min, exp = math.floor, math.sqrt, math.abs, math.max, math.min, math.exp

M.SEARCH = 30          -- m: roads and paths farther than this from a GPS point are not candidates
M.SIGMA = 6            -- m: GPS error (emission: distance^2 / (2 sigma^2)); widened for a sloppy track (below)
M.SIGMA_MAX = 14       -- m: the most it is widened to
M.OFF = 3              -- "off the map" costs as much as a road this many sigmas away
M.IN_BUILDING = 25     -- extra cost of being off the map inside a building (no one rides through one: the GPS is off)
M.HEADING = 6          -- cost of a road at right angles to the route's heading (scaled by 1 - |cos|)
M.BETA = 2             -- m: transition: |step on the map - step along the route| / BETA
M.SWITCH = 2.0         -- extra cost of changing from one road or path to another
M.ONOFF = 3.0          -- cost of leaving or rejoining the mapped roads
M.LAG = 75             -- points (150 m) a point waits before it is settled
M.PATH_WIDTH = 2.5     -- m: the path added where the route leaves the map
M.EDGE = 1.0           -- m: the rider keeps at least this far from a road's edge
M.LANE = 3.5           -- m: widest lane offset
M.HASH = 16            -- m: segment grid
M.JOIN = 1.5           -- m: two roads or paths connect where one comes this close to the other (a junction)
M.STEP_MAX = 3.0       -- m: a turn onto another road that moves the rider farther than this in one step goes through the junction
M.REVERSE = 12         -- cost of a step against the route's heading
M.BREAK = 60           -- cost of moving between roads or paths that do not connect there (a GPS jump)

local TILE = 65536
local NOT_ROAD = { rail = true, transit = true, ferry = true, aerialway = true, pier = true }
local PATHLIKE = { path = true, track = true, cycleway = true, footway = true, bridleway = true, steps = true, pedestrian = true }

-- countries where traffic keeps left (rough boxes, lon0, lat0, lon1, lat1); the rider rides on the left there
local KEEP_LEFT = {
  { -10.7, 49.8, 1.9, 61.0 },       -- Great Britain and Ireland
  { 122.9, 24.0, 146.0, 45.6 },     -- Japan
  { 112.9, -43.7, 153.7, -10.6 },   -- Australia
  { 166.4, -47.4, 178.6, -34.3 },   -- New Zealand
  { 16.4, -35.0, 33.0, -22.1 },     -- South Africa and neighbours
  { 68.1, 6.7, 97.4, 35.7 },        -- India, Nepal, Bangladesh
  { 79.6, 5.9, 81.9, 9.9 },         -- Sri Lanka
  { 97.3, -11.0, 141.0, 20.5 },     -- Thailand, Malaysia, Singapore, Indonesia
  { 113.8, 22.1, 114.5, 22.6 },     -- Hong Kong
  { 33.9, -4.8, 41.9, 5.0 },        -- Kenya
  { 29.3, -11.8, 40.5, -0.9 },      -- Tanzania, Uganda
  { 32.2, 34.5, 34.7, 35.8 },       -- Cyprus
  { 14.1, 35.8, 14.6, 36.1 },       -- Malta
}

local function keeps_left(lat, lon)
  for _, b in ipairs(KEEP_LEFT) do
    if lon >= b[1] and lon <= b[3] and lat >= b[2] and lat <= b[4] then return true end
  end
  return false
end

function M.new(R, W, opts)
  opts = opts or {}
  local MT = setmetatable({ R = R, W = W, log = W.log or print, next = 1, settled = 0, tiles = {}, grid = {}, ways = {},
    C = {}, cost = {}, back = {}, P = {}, way = {}, raw = {}, extra = {}, jn = {}, cand = {}, turns = {}, bgrid = {}, err = {}, sigma = M.SIGMA }, { __index = M })
  R.way = MT.way
  -- the raw GPX positions (metres) and headings, kept: the route's own positions get moved as points are settled
  local n = R.n
  for k = 1, n do MT.raw[k] = { R.X[k], R.Y[k] } end
  MT.hx, MT.hy = {}, {}
  for k = 1, n do
    local a, b = max(1, k - 5), min(n, k + 5)
    local dx, dy = R.X[b] - R.X[a], R.Y[b] - R.Y[a]
    local l = sqrt(dx * dx + dy * dy)
    MT.hx[k], MT.hy[k] = l > 0 and dx / l or 1, l > 0 and dy / l or 0
  end
  local lat, lon = opts.lat or W.o.lat, opts.lon or W.o.lon
  MT.left = keeps_left(lat, lon)
  return MT
end

-- ---- the roads and paths of a map tile, as segments in metres on a grid ----
local function add_tile(self, tx, ty, tick)
  local key = tx * 65536 + ty
  if self.tiles[key] then return end
  self.tiles[key] = true
  local layers = self.W:tile_layers(tx, ty, tick)
  local W, H, grid = self.W, M.HASH, self.grid
  -- buildings (outer rings, metres) on a coarse grid: off the map inside one is not believable
  local B = layers and layers.building
  if B then
    for _, f in ipairs(B.features) do
      if f.type == 3 then
        for _, ring in ipairs(f.parts) do
          local poly, x0, y0, x1, y1 = {}, 1e18, 1e18, -1e18, -1e18
          for i = 1, #ring, 2 do
            local x, y = W:metres_of(tx * TILE + ring[i] * 16, ty * TILE + ring[i + 1] * 16)
            poly[#poly + 1] = x; poly[#poly + 1] = y
            x0, y0, x1, y1 = min(x0, x), min(y0, y), max(x1, x), max(y1, y)
          end
          local b = { poly = poly, x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
          for gx = floor(x0 / 32), floor(x1 / 32) do
            for gy = floor(y0 / 32), floor(y1 / 32) do
              local gk = gx * 1048576 + gy
              local list = self.bgrid[gk]
              if not list then list = {}; self.bgrid[gk] = list end
              list[#list + 1] = b
            end
          end
        end
      end
      if tick then tick() end
    end
  end
  local L = layers and layers.transportation
  if not L then return end
  for _, f in ipairs(L.features) do
    local p = f.props or {}
    if f.type == 2 and not NOT_ROAD[p.class] and not p.synthetic then
      local w = p.width or 0
      if w == 0 then w = (PATHLIKE[p.class] or PATHLIKE[p.subclass]) and 2.5 or 6 end
      for _, part in ipairs(f.parts) do
        -- one way per line (distances along it are measured along it)
        local way = { class = p.class, subclass = p.subclass, width = w, oneway = p.oneway and p.oneway ~= 0 and p.oneway ~= false,
          kind = (PATHLIKE[p.class] or PATHLIKE[p.subclass]) and "path" or "road", brunnel = p.brunnel, id = #self.ways + 1, verts = {} }
        self.ways[way.id] = way
        local px, py
        local m = 0
        for i = 1, #part, 2 do
          local x, y = W:metres_of(tx * TILE + part[i] * 16, ty * TILE + part[i + 1] * 16)
          if px then
            local seg = { px, py, x, y, way, m }
            m = m + sqrt((x - px) ^ 2 + (y - py) ^ 2)
            local a0, a1 = floor(min(px, x) / H), floor(max(px, x) / H)
            local b0, b1 = floor(min(py, y) / H), floor(max(py, y) / H)
            for gx = a0, a1 do
              for gy = b0, b1 do
                local gk = gx * 1048576 + gy
                local list = grid[gk]
                if not list then list = {}; grid[gk] = list end
                list[#list + 1] = seg
              end
            end
          end
          way.verts[#way.verts + 1] = x; way.verts[#way.verts + 1] = y
          way.vm = way.vm or {}
          way.vm[#way.vm + 1] = m
          px, py = x, y
        end
        if tick then tick() end
      end
    end
  end
end

-- the map tiles within SEARCH of a point
local function need_tiles(self, x, y, tick)
  local W = self.W
  for _, d in ipairs({ { 0, 0 }, { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
    local gx, gy = W:global_of_metres(x + d[1] * M.SEARCH, y + d[2] * M.SEARCH)
    add_tile(self, floor(gx / TILE), floor(gy / TILE), tick)
  end
end

-- inside a building? (even-odd over all rings: holes count as outside)
local function in_building(self, x, y)
  local list = self.bgrid[floor(x / 32) * 1048576 + floor(y / 32)]
  if not list then return false end
  local inside = false
  for _, b in ipairs(list) do
    if x >= b.x0 and x <= b.x1 and y >= b.y0 and y <= b.y1 then
      local p, n = b.poly, #b.poly
      local j = n - 1
      for i = 1, n, 2 do
        local xi, yi, xj, yj = p[i], p[i + 1], p[j], p[j + 1]
        if (yi > y) ~= (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi then inside = not inside end
        j = i
      end
    end
  end
  return inside
end

-- candidates of point k: the nearest point on each road or path within SEARCH, and "off the map" (index 1)
local function candidates(self, k)
  local x, y = self.raw[k][1], self.raw[k][2]
  local hx, hy = self.hx[k], self.hy[k]
  local H, grid = M.HASH, self.grid
  local best = {}          -- way -> list of candidates on it (more than one where it passes by more than once)
  local r = M.SEARCH
  for gx = floor((x - r) / H), floor((x + r) / H) do
    for gy = floor((y - r) / H), floor((y + r) / H) do
      local list = grid[gx * 1048576 + gy]
      if list then
        for _, s in ipairs(list) do
          local ax, ay, bx, by = s[1], s[2], s[3], s[4]
          local dx, dy = bx - ax, by - ay
          local l2 = dx * dx + dy * dy
          if l2 > 1e-6 then
            local t = ((x - ax) * dx + (y - ay) * dy) / l2
            if t < 0 then t = 0 elseif t > 1 then t = 1 end
            local px, py = ax + dx * t, ay + dy * t
            local d = sqrt((x - px) ^ 2 + (y - py) ^ 2)
            local way = s[5]
            if d <= r then
              local l = sqrt(l2)
              local m = s[6] + l * t
              local list = best[way]
              if not list then list = {}; best[way] = list end
              local near
              for _, c in ipairs(list) do if abs(c.m - m) < 15 then near = c; break end end
              if not near then list[#list + 1] = { way = way, x = px, y = py, d = d, ux = dx / l, uy = dy / l, m = m }
              elseif d < near.d then near.x, near.y, near.d, near.ux, near.uy, near.m = px, py, d, dx / l, dy / l, m end
            end
          end
        end
      end
    end
  end
  -- how far off this track's GPS is: the typical distance from its points to the nearest road or path so far
  local nearest = 1e18
  for _, list in pairs(best) do for _, c in ipairs(list) do if c.d < nearest then nearest = c.d end end end
  if nearest < 1e18 then
    local E = self.err
    E[#E + 1] = nearest
    if #E > 400 then table.remove(E, 1) end
    if #E % 20 == 0 or #E < 20 then
      local s = {}
      for i = 1, #E do s[i] = E[i] end
      table.sort(s)
      -- the median distance of a GPS fix to its road is about 0.7 sigma
      self.sigma = max(M.SIGMA, min(M.SIGMA_MAX, s[floor(#s / 2) + 1] / 0.7))
    end
  end
  local sg = self.sigma
  local off_e = M.OFF * M.OFF / 2
  if in_building(self, x, y) then off_e = off_e + M.IN_BUILDING end
  local C = { { off = true, x = x, y = y, e = off_e } }
  for _, list in pairs(best) do
    for _, c in ipairs(list) do
      local cosang = abs(c.ux * hx + c.uy * hy)
      c.e = c.d * c.d / (2 * sg * sg) + M.HEADING * (1 - cosang)
      C[#C + 1] = c
    end
  end
  return C
end

-- where two roads or paths connect: points where a vertex of one lies within JOIN of the other (shared junction
-- nodes, a path ending on a road, or the same road cut in two at a map tile's edge)
local function joins_of(self, A, B, list)
  local H, grid, r = M.HASH, self.grid, M.JOIN
  local v = A.verts
  for i = 1, #v, 2 do
    local x, y = v[i], v[i + 1]
    local cl = grid[floor(x / H) * 1048576 + floor(y / H)]
    if cl then
      for _, s in ipairs(cl) do
        if s[5] == B then
          local ax, ay, dx, dy = s[1], s[2], s[3] - s[1], s[4] - s[2]
          local l2 = dx * dx + dy * dy
          local t = l2 > 0 and ((x - ax) * dx + (y - ay) * dy) / l2 or 0
          if t < 0 then t = 0 elseif t > 1 then t = 1 end
          if (x - ax - dx * t) ^ 2 + (y - ay - dy * t) ^ 2 <= r * r then list[#list + 1] = { x, y }; break end
        end
      end
    end
  end
end
local function junctions(self, A, B)
  local key = A.id < B.id and A.id * 1048576 + B.id or B.id * 1048576 + A.id
  local J = self.jn[key]
  if J then return J end
  J = {}
  joins_of(self, A, B, J)
  joins_of(self, B, A, J)
  self.jn[key] = J
  return J
end

-- the cost of going from candidate a to candidate b in one step: how much the way on the map (through the junction
-- where they connect, if they are different roads) differs from the step along the route
local function transition(self, a, b, step, hx, hy, sk)
  if a.off and b.off then return 0 end
  if b.off then return M.ONOFF + abs(sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) - step) / M.BETA end
  if a.off then
    local cost = M.ONOFF + abs(sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) - step) / M.BETA
    -- rejoining: as far along the map from where the rider left it as they rode off it (a spell off the map is no
    -- shortcut to another leg of the same hairpin)
    local f = a.from
    if f then
      local rode = sk - f.s
      local d
      if f.way == b.way then d = abs(b.m - f.m)
      else
        local J = junctions(self, f.way, b.way)
        for _, j in ipairs(J) do
          local v = sqrt((f.x - j[1]) ^ 2 + (f.y - j[2]) ^ 2) + sqrt((b.x - j[1]) ^ 2 + (b.y - j[2]) ^ 2)
          if not d or v < d then d = v end
        end
      end
      if d and d > rode + 2 * step then cost = cost + (d - rode) / M.BETA end
    end
    return cost
  end
  local d, tx, ty
  if a.way == b.way then
    d = abs(a.m - b.m)
    -- the direction the rider moves along the road
    if d > 0.5 then local sg = b.m > a.m and 1 or -1; tx, ty = b.ux * sg, b.uy * sg end
  else
    local J = junctions(self, a.way, b.way)
    if #J == 0 then return M.BREAK end
    d = 1e18
    local bj
    for _, j in ipairs(J) do
      local v = sqrt((a.x - j[1]) ^ 2 + (a.y - j[2]) ^ 2) + sqrt((b.x - j[1]) ^ 2 + (b.y - j[2]) ^ 2)
      if v < d then d, bj = v, j end
    end
    local ex, ey = b.x - bj[1], b.y - bj[2]
    local el = sqrt(ex * ex + ey * ey)
    if el > 1 then tx, ty = ex / el, ey / el end
  end
  local cost = abs(d - step) / M.BETA + (a.way ~= b.way and M.SWITCH or 0)
  -- riding against the route's own heading (the GPS cutting across to the next leg of a hairpin) costs a lot
  if tx and tx * hx + ty * hy < -0.3 then cost = cost + M.REVERSE end
  return cost
end

-- where the rider rides on a candidate: the middle of a path; on a road, the middle of their lane
local function ride_point(self, c, k)
  if c.off then return c.x, c.y end
  local way = c.way
  if way.kind == "path" then return c.x, c.y end
  local w = way.width
  local off
  if way.oneway then off = w / 2 - M.LANE / 2 else off = w / 4 end
  off = min(off, M.LANE, w / 2 - M.EDGE)
  if off <= 0 then return c.x, c.y end
  -- the road's direction the way the rider goes, and its right-hand side (x east, y north)
  local sgn = (c.ux * self.hx[k] + c.uy * self.hy[k]) >= 0 and 1 or -1
  local tx, ty = c.ux * sgn, c.uy * sgn
  local rx, ry = ty, -tx
  if self.left then rx, ry = -rx, -ry end
  return c.x + rx * off, c.y + ry * off
end

-- settle points settled+1 .. upto from the cheapest chain ending at the newest point
local function settle(self, upto, tick)
  local last = self.next - 1
  if upto > last then upto = last end
  if upto <= self.settled then return end
  -- backtrack from the cheapest candidate of the newest point
  local cost = self.cost[last]
  local bi, bc = 1, cost[1]
  for i = 2, #cost do if cost[i] < bc then bi, bc = i, cost[i] end end
  local chain = {}
  local i = bi
  for k = last, self.settled + 1, -1 do
    chain[k] = i
    if k > self.settled + 1 then i = self.back[k][i] end
  end
  for k = self.settled + 1, upto do
    local c = self.C[k][chain[k]]
    local px, py = ride_point(self, c, k)
    -- the middle of what the rider is on, and how far from it they may be (half its width, less a margin)
    local half = c.off and M.PATH_WIDTH / 2 or c.way.width / 2
    self.P[k] = { px, py, c.x, c.y, max(0.3, half - M.EDGE * 0.6) }
    self.way[k] = c.off and { kind = "off", width = M.PATH_WIDTH } or { kind = c.way.kind, width = c.way.width, class = c.way.class, brunnel = c.way.brunnel, id = c.way.id, m = c.m }
    self.cand[k] = c
    -- turning from one road or path onto another: remembered, to be taken through the junction where they meet
    if k > 1 and not c.off and self.cand[k - 1] and not self.cand[k - 1].off and self.cand[k - 1].way ~= c.way then
      local a = self.cand[k - 1]
      local best, bd
      for _, j in ipairs(junctions(self, a.way, c.way)) do
        local v = sqrt((a.x - j[1]) ^ 2 + (a.y - j[2]) ^ 2) + sqrt((c.x - j[1]) ^ 2 + (c.y - j[2]) ^ 2)
        if not bd or v < bd then best, bd = j, v end
      end
      if best and sqrt((self.P[k][1] - self.P[k - 1][1]) ^ 2 + (self.P[k][2] - self.P[k - 1][2]) ^ 2) > M.STEP_MAX then
        self.turns[#self.turns + 1] = { k, { best } }
      end
    end
    -- a skip along the same road (the GPS cutting a tight bend): through the road's own points in between
    if k > 1 and not c.off and self.cand[k - 1] and self.cand[k - 1].way == c.way and abs(c.m - self.cand[k - 1].m) > M.STEP_MAX then
      local a, way = self.cand[k - 1], c.way
      local via = {}
      local lo, hi = min(a.m, c.m), max(a.m, c.m)
      for i = 1, #way.vm do
        if way.vm[i] > lo and way.vm[i] < hi then via[#via + 1] = { way.verts[2 * i - 1], way.verts[2 * i], way.vm[i] } end
      end
      if c.m < a.m then table.sort(via, function(p, q) return p[3] > q[3] end) else table.sort(via, function(p, q) return p[3] < q[3] end) end
      if #via > 0 then self.turns[#self.turns + 1] = { k, via } end
    end
    if tick then tick() end
  end
  local s0 = self.settled
  local smooth_from = s0
  self.settled = upto
  -- turns whose points either side are settled: those points spread evenly along the way through the junction
  local keep = {}
  for _, tr in ipairs(self.turns) do
    local k, j = tr[1], tr[2]
    if k + 2 <= upto then
      local a0, b1 = max(1, k - 3), k + 2
      local line = {}
      for i = a0, k - 1 do line[#line + 1] = { self.P[i][1], self.P[i][2] } end
      for _, v in ipairs(j) do line[#line + 1] = { v[1], v[2] } end
      for i = k, b1 do line[#line + 1] = { self.P[i][1], self.P[i][2] } end
      local cum = { 0 }
      for i = 2, #line do cum[i] = cum[i - 1] + sqrt((line[i][1] - line[i - 1][1]) ^ 2 + (line[i][2] - line[i - 1][2]) ^ 2) end
      local total, cnt = cum[#line], b1 - a0
      local seg = 1
      for i = a0 + 1, b1 - 1 do
        local want = total * (i - a0) / cnt
        while seg < #line - 1 and cum[seg + 1] < want do seg = seg + 1 end
        local f = (cum[seg + 1] - cum[seg]) > 0 and (want - cum[seg]) / (cum[seg + 1] - cum[seg]) or 0
        local x = line[seg][1] + (line[seg + 1][1] - line[seg][1]) * f
        local y = line[seg][2] + (line[seg + 1][2] - line[seg][2]) * f
        local P = self.P[i]
        P[1], P[2], P[3], P[4] = x, y, x, y
      end
      smooth_from = min(smooth_from, a0 - 1)
    else keep[#keep + 1] = tr end
  end
  self.turns = keep
  -- the route's positions: settled points smoothed a little (lane changes and joins ease in over a few metres)
  local R, W = self.R, self.W
  local from = max(1, smooth_from - 4)
  for k = from, upto - 3 do
    local ax, ay, ws = 0, 0, 0
    local wk = self.way[k]
    for j = max(1, k - 3), min(upto, k + 3) do
      local wj = exp(-0.5 * ((j - k) / 1.5) ^ 2)
      -- on a narrow path, only its own points (blending with a neighbouring path would put the rider between them)
      if wk.kind ~= "road" and self.way[j].class ~= wk.class then wj = wj * 0.15 end
      ax = ax + self.P[j][1] * wj; ay = ay + self.P[j][2] * wj; ws = ws + wj
    end
    local x, y = ax / ws, ay / ws
    -- never eased off what the rider is on: kept within its width
    local Pk = self.P[k]
    local dx, dy = x - Pk[3], y - Pk[4]
    local d = sqrt(dx * dx + dy * dy)
    if d > Pk[5] then x, y = Pk[3] + dx / d * Pk[5], Pk[4] + dy / d * Pk[5] end
    local gx, gy = W:global_of_metres(x, y)
    W:move_route_point(k, gx, gy)
  end
  if upto == R.n then
    for k = max(1, upto - 2), upto do
      local gx, gy = W:global_of_metres(self.P[k][1], self.P[k][2])
      W:move_route_point(k, gx, gy)
    end
  end
  -- stretches off the map (followed across settles): a path under each, once it ends
  for k = s0 + 1, upto do
    if self.way[k].kind == "off" then
      if not self.off_from then self.off_from = k end
    elseif self.off_from then
      self:off_stretch(self.off_from, k - 1, k)
      self.off_from = nil
    end
  end
  if upto == R.n and self.off_from then
    self:off_stretch(self.off_from, R.n, nil)
    self.off_from = nil
  end
end

-- a stretch off the map, points a..b (back on the map at point `after`, if any): it keeps the GPS track's shape but
-- is shifted so it starts where the rider leaves the road and ends where they rejoin one (no jump sideways), and gets
-- a path under it
function M:off_stretch(a, b, after)
  local W, P, raw = self.W, self.P, self.raw
  local before = a > 1 and a - 1 or nil
  local e0x, e0y, e1x, e1y = 0, 0, 0, 0
  if before then e0x, e0y = P[before][1] - raw[before][1], P[before][2] - raw[before][2] end
  if after then e1x, e1y = P[after][1] - raw[after][1], P[after][2] - raw[after][2] else e1x, e1y = e0x, e0y end
  if not before then e0x, e0y = e1x, e1y end
  local n = b - a + 2
  for j = a, b do
    local f = (j - a + 1) / n
    local x = raw[j][1] + e0x + (e1x - e0x) * f
    local y = raw[j][2] + e0y + (e1y - e0y) * f
    P[j] = { x, y, x, y, max(0.3, M.PATH_WIDTH / 2 - M.EDGE * 0.6) }
  end
  -- a short hop between two roads or paths the map does not connect: the points from a little before to where the
  -- rider rejoins spread evenly along it (no sudden leap)
  if before and after then
    local s0, s1 = max(1, before - 2), after
    local line, cum = {}, { 0 }
    for i = s0, s1 do line[#line + 1] = { P[i][1], P[i][2] } end
    for i = 2, #line do cum[i] = cum[i - 1] + sqrt((line[i][1] - line[i - 1][1]) ^ 2 + (line[i][2] - line[i - 1][2]) ^ 2) end
    local total, cnt = cum[#line], s1 - s0
    if cnt > 0 and total / cnt > M.STEP_MAX * 0.8 then
      local seg = 1
      for i = s0 + 1, s1 - 1 do
        local want = total * (i - s0) / cnt
        while seg < #line - 1 and cum[seg + 1] < want do seg = seg + 1 end
        local f = (cum[seg + 1] - cum[seg]) > 0 and (want - cum[seg]) / (cum[seg + 1] - cum[seg]) or 0
        local x = line[seg][1] + (line[seg + 1][1] - line[seg][1]) * f
        local y = line[seg][2] + (line[seg + 1][2] - line[seg][2]) * f
        P[i] = { x, y, x, y, P[i][5] }
      end
    end
  end
  for j = before and max(1, before - 2) or a, b do
    local gx, gy = W:global_of_metres(P[j][1], P[j][2])
    W:move_route_point(j, gx, gy)
  end
  -- a path under it: always between two roads (it is the connection), at the route's ends from 3 points (6 m)
  if (before and after) or b - a + 1 >= 3 then self:add_path(before and max(1, before - 2) or a, after or b) end
end

-- a path along route points k0..k1 (where the rider rides), added to the map tiles it crosses
function M:add_path(k0, k1)
  local W = self.W
  local gpts = {}
  for k = k0, k1 do
    local gx, gy = W:global_of_metres(self.P[k][1], self.P[k][2])
    gpts[#gpts + 1] = gx; gpts[#gpts + 1] = gy
  end
  local tiles = {}
  for i = 1, #gpts, 2 do
    for dx = -1, 1 do for dy = -1, 1 do
      local tx, ty = floor((gpts[i] + dx * 200) / TILE), floor((gpts[i + 1] + dy * 200) / TILE)
      tiles[tx * 65536 + ty] = { tx, ty }
    end end
  end
  for _, t in pairs(tiles) do
    local part = {}
    for i = 1, #gpts, 2 do
      -- whole tile units, like the map's own features (the ground builder works in exact integers)
      part[#part + 1] = floor((gpts[i] - t[1] * TILE) / 16 + 0.5)
      part[#part + 1] = floor((gpts[i + 1] - t[2] * TILE) / 16 + 0.5)
    end
    W:add_feature(t[1], t[2], { type = 2, parts = { part }, props = { class = "path", width = M.PATH_WIDTH, synthetic = true } })
  end
  self.paths = (self.paths or 0) + 1
  self.off_m = (self.off_m or 0) + (k1 - k0) * 2
end

-- match the route up to s metres along it
function M:advance(s, tick)
  local R = self.R
  local upto = min(R.n, floor(s / 2) + 1)
  while self.next <= upto do
    local k = self.next
    need_tiles(self, self.raw[k][1], self.raw[k][2], tick)
    local C = candidates(self, k)
    local cost, back = {}, {}
    if k == 1 or k == self.settled + 1 and not self.cost[k - 1] then
      for i, c in ipairs(C) do cost[i] = c.e end
    else
      local PC, pcost = self.C[k - 1], self.cost[k - 1]
      local step = R.S[k] - R.S[k - 1]
      for i, c in ipairs(C) do
        local bc, bj = 1e18, 1
        for j, p in ipairs(PC) do
          local v = pcost[j] + transition(self, p, c, step, self.hx[k], self.hy[k], R.S[k])
          if v < bc then bc, bj = v, j end
        end
        cost[i], back[i] = bc + c.e, bj
        -- off the map: where the rider left it
        if c.off then
          local p = PC[bj]
          c.from = p.off and p.from or (not p.off and { way = p.way, m = p.m, x = p.x, y = p.y, s = R.S[k - 1] }) or nil
        end
      end
    end
    -- keep the numbers small
    local m = 1e18
    for i = 1, #cost do if cost[i] < m then m = cost[i] end end
    for i = 1, #cost do cost[i] = cost[i] - m end
    self.C[k], self.cost[k], self.back[k] = C, cost, back
    self.next = k + 1
    if k - self.settled > M.LAG then
      settle(self, k - M.LAG, tick)
      -- forget what is settled (keep the last one: the chain starts from it)
      for j = self.settled - 1, max(1, self.settled - M.LAG), -1 do
        if not self.C[j] then break end
        self.C[j], self.cost[j], self.back[j] = nil, nil, nil
      end
    end
    if tick then tick() end
  end
  if upto == R.n then settle(self, R.n, tick) end
end

function M:finish(tick) self:advance(self.R.length + 2, tick) end

-- metres of the route that are settled
function M:settled_m() return (self.settled - 1) * 2 end

return M
