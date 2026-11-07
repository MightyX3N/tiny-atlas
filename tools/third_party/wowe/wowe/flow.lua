-- The water's surfaces and how they flow.
--
-- Every painted surface pixel is measured once per mask:
--   ds     distance to its shore (on the ground: seen from the side, a step
--          up or down the screen is twice as far)
--   up     surface px straight above it before the ground (bank shade)
--   dSink  how far the water still has to go to a lip (where a fall
--          starts right under the surface), and which lip
--   dSrc   how far it has come from a landing (where a fall hits it)
--   e, ry  how far from the landing (rings) and the landing right above
--          (the fall's reflection)
-- Distances to lips and landings run inside the water (round islands and
-- along bends), a Dijkstra search over the surface.
--
-- From them the flow: toward the lips, away from the landings. Where a
-- surface has neither, rivers run their own way (the river's direction) and
-- still water lies still, unless a drift is set. The direction is the way the
-- distances fall fastest (on the ground), smoothed. Guide rods (Guide), when
-- on, turn the water near them to run along them. "Lanes" are a noise
-- smeared along the flow, the same down a streamline and different across
-- it, so streaks and foam follow the water's curves.

local G = ... or _WOWE

local Noise = G.require("noise")
local Mask  = G.require("mask")
local Guide = G.require("guide")

local Flow = {}

local floor, sqrt, exp, log, min, max, abs = math.floor, math.sqrt, math.exp, math.log,
  math.min, math.max, math.abs

local RATIO = 0.5
local VY = 1 / RATIO
local DIAG = sqrt(1 + VY * VY)
Flow.RATIO = RATIO

local NB = {
  { 1, 0, 1 }, { -1, 0, 1 }, { 0, 1, VY }, { 0, -1, VY },
  { 1, 1, DIAG }, { -1, 1, DIAG }, { 1, -1, DIAG }, { -1, -1, DIAG },
}

-- A dial's way (degrees, 0 = right, 90 = down) as a unit vector, exactly
-- 0 where it should be (cos 90 is not quite 0: the clock would come out a
-- hair under 0 on the top row and the loop would not close there).
local function way(deg)
  local a = (deg or 0) * math.pi / 180
  local c, s = math.cos(a), math.sin(a)
  if abs(c) < 1e-9 then c = 0 end
  if abs(s) < 1e-9 then s = 0 end
  return c, s
end

-- Distance over the water from the seeds ({ k, label }), on the ground,
-- and the label of the seed each pixel is nearest to. Within `fast` (the
-- mouths: the water right at an edge) a step down or up the screen costs
-- little, so the water there goes straight over its own edge instead of
-- sliding along it.
local MOUTH_V = 0.6
local MOUTH_D = sqrt(1 + MOUTH_V * MOUTH_V)
local function search(B, seeds, step, fast)
  local w, h, kind = B.w, B.h, B.kind
  local dist, lab, done = {}, {}, {}
  local hd, hk, n = {}, {}, 0
  local function push(d, k)
    n = n + 1
    local i = n
    while i > 1 do
      local p = i // 2
      if hd[p] <= d then break end
      hd[i], hk[i] = hd[p], hk[p]
      i = p
    end
    hd[i], hk[i] = d, k
  end
  local function pop()
    local d, k = hd[1], hk[1]
    local ld, lk = hd[n], hk[n]
    hd[n], hk[n] = nil, nil
    n = n - 1
    if n > 0 then
      local i = 1
      while true do
        local c = i * 2
        if c > n then break end
        if c < n and hd[c + 1] < hd[c] then c = c + 1 end
        if hd[c] >= ld then break end
        hd[i], hk[i] = hd[c], hk[c]
        i = c
      end
      hd[i], hk[i] = ld, lk
    end
    return d, k
  end
  for _, s in ipairs(seeds) do
    local k = s[1]
    if kind[k] == 2 and dist[k] == nil then
      dist[k], lab[k] = 0, s[2]
      push(0, k)
    end
  end
  local count = 0
  while n > 0 do
    local d, k = pop()
    if not done[k] then
      done[k] = true
      local x, y = (k - 1) % w, (k - 1) // w
      local l = lab[k]
      for i = 1, 8 do
        local o = NB[i]
        local nx, ny = x + o[1], y + o[2]
        if nx >= 0 and ny >= 0 and nx < w and ny < h then
          local q = ny * w + nx + 1
          if kind[q] == 2 and not done[q] then
            local nd = d + o[3]
            if fast and o[2] ~= 0 and fast[k] and fast[q] then
              nd = d + ((o[1] == 0) and MOUTH_V or MOUTH_D)
            end
            local old = dist[q]
            if not old or nd < old then
              dist[q], lab[q] = nd, l
              push(nd, q)
            end
          end
        end
      end
      count = count + 1
      if count % 2048 == 0 then step() end
    end
  end
  return dist, lab
end

-- Measures the surfaces of a base (see Scape: kind, the fall's runs that
-- start right under a surface, the landings).
function Flow.build(B, R, step)
  local w, h, kind = B.w, B.h, B.kind
  local W = { n = 0 }
  local idx, wx, wy, jOf = {}, {}, {}, {}
  for k = 1, B.N do
    if kind[k] == 2 then
      local j = #idx + 1
      idx[j], wx[j], wy[j], jOf[k] = k, (k - 1) % w, (k - 1) // w, j
    end
  end
  local n = #idx
  W.n, W.idx, W.x, W.y, W.jOf = n, idx, wx, wy, jOf
  if n == 0 then return W end
  -- Which surfaces are rivers, which are the mouth (river over a fall).
  local Rv, Rl = R.river or {}, R.lip or {}
  local isRiver, isLip = {}, {}
  for j = 1, n do
    isRiver[j], isLip[j] = Rv[idx[j]] or false, Rl[idx[j]] or false
  end
  W.river, W.lip = isRiver, isLip
  -- Down every column of a mouth: from its back (q 0) to its front (q 1,
  -- where the fall starts), px to the front, the row the fall starts on.
  local lipQ, lipD, lipFy = {}, {}, {}
  for x = 0, w - 1 do
    local y = 0
    while y < h do
      local k = y * w + x + 1
      if Rl[k] then
        local yT = y
        while y < h and Rl[y * w + x + 1] do y = y + 1 end
        local yB = y - 1
        local Lh = yB - yT + 1
        for yy = yT, yB do
          local j = jOf[yy * w + x + 1]
          lipQ[j] = (yy - yT + 0.5) / Lh
          lipD[j] = yB - yy
          lipFy[j] = R.y0 + yB + 1
        end
      else
        y = y + 1
      end
    end
  end
  W.lipQ, W.lipD, W.lipFy = lipQ, lipD, lipFy

  -- Shore distance (on the ground), shore pixels, the way off the shore.
  local dsAll = Mask.distance(R, function(k) return kind[k] ~= 0 end, step, VY)
  local ds, shore, gx, gy = {}, {}, {}, {}
  for j = 1, n do
    local k, x, y = idx[j], wx[j], wy[j]
    ds[j] = dsAll[k]
    shore[j] = (x > 0 and kind[k - 1] == 0) or (x < w - 1 and kind[k + 1] == 0)
      or (y > 0 and kind[k - w] == 0) or (y < h - 1 and kind[k + w] == 0)
    local l = (x > 0) and dsAll[k - 1] or ds[j]
    local r = (x < w - 1) and dsAll[k + 1] or ds[j]
    local t = (y > 0) and dsAll[k - w] or ds[j]
    local b = (y < h - 1) and dsAll[k + w] or ds[j]
    local ax, ay = r - l, (b - t) / (VY * VY)
    local len = sqrt(ax * ax + ay * ay)
    if len > 1e-6 then ax, ay = ax / len, ay / len end
    gx[j], gy[j] = ax, ay
  end
  W.ds, W.shore, W.gx, W.gy = ds, shore, gx, gy
  step()

  -- Surface straight above, down to the ground (none under a fall).
  local up = {}
  for x = 0, w - 1 do
    local run = (R.y0 > 0) and 0 or 999
    for y = 0, h - 1 do
      local k = y * w + x + 1
      local kd = kind[k]
      if kd == 2 then
        up[jOf[k]] = run
        run = run + 1
      elseif kd == 1 then
        run = 99
      else
        run = 0
      end
    end
  end
  W.up = up

  -- Connected surfaces.
  local comp, comps = {}, {}
  for j = 1, n do
    if not comp[j] then
      local id = #comps + 1
      comps[id] = { sink = false, src = false, size = 0 }
      local stack = { j }
      comp[j] = id
      while #stack > 0 do
        local q = stack[#stack]
        stack[#stack] = nil
        comps[id].size = comps[id].size + 1
        local x, y = wx[q], wy[q]
        for i = 1, 8 do
          local o = NB[i]
          local nx, ny = x + o[1], y + o[2]
          if nx >= 0 and ny >= 0 and nx < w and ny < h then
            local r = jOf[ny * w + nx + 1]
            if r and not comp[r] then
              comp[r] = id
              stack[#stack + 1] = r
            end
          end
        end
      end
    end
  end
  W.comp, W.comps = comp, comps
  step()

  -- Lips: the surface right over the top of a fall run.
  local lips, sinkSeeds = {}, {}
  for _, r in ipairs(B.fedRuns or {}) do
    local li = #lips + 1
    lips[li] = { x = r.x, top = B.y0 + r.yT }
    local yy = r.yT - (r.gapY or 1)
    if yy >= 0 then
      local up0 = yy * w + r.x + 1
      for _, k in ipairs({ up0, (r.x > 0) and up0 - 1 or 0, (r.x < w - 1) and up0 + 1 or 0 }) do
        if k > 0 and kind[k] == 2 then
          sinkSeeds[#sinkSeeds + 1] = { k, li }
          -- Coming off a mouth painted over the fall: that band is the lip.
          if Rl[k] then lips[li].mouth = true end
        end
      end
    end
  end
  W.lips = lips
  -- Landings in the water: the surface right under where a fall lands.
  local srcSeeds = {}
  for si, s in ipairs(B.segs) do
    if s.pool then
      for x = s.xa, s.xb do
        local y = s.cols[x]
        for dy = 1, 2 do
          local yy = y + dy
          if yy < h then
            local k = yy * w + x + 1
            if kind[k] == 2 then srcSeeds[#srcSeeds + 1] = { k, si } end
          end
        end
      end
    end
  end
  local dSinkK, sinkK = search(B, sinkSeeds, step, Rl)
  local dSrcK = search(B, srcSeeds, step)
  local dSink, sinkLab, dSrc = {}, {}, {}
  for j = 1, n do
    local k = idx[j]
    dSink[j], sinkLab[j], dSrc[j] = dSinkK[k], sinkK[k], dSrcK[k]
    local c = comps[comp[j]]
    if dSink[j] then c.sink = true end
    if dSrc[j] then c.src = true end
  end
  W.dSink, W.sinkLab, W.dSrc = dSink, sinkLab, dSrc
  step()

  -- Which way the water goes where a fall feeds or drains it: down the
  -- distances (toward a lip, away from a landing), on the ground. Ponds
  -- with neither are left to the drift.
  local psi = {}
  for j = 1, n do
    local c = comps[comp[j]]
    if c.sink or c.src then
      psi[j] = (dSink[j] or 0) - (dSrc[j] or 0)
    end
  end
  local ux, uy = {}, {}
  for j = 1, n do
    local v = psi[j]
    if v then
      local k, x, y = idx[j], wx[j], wy[j]
      local function at(dx, dy)
        local nx, ny = x + dx, y + dy
        if nx < 0 or ny < 0 or nx >= w or ny >= h then return nil end
        local q = jOf[ny * w + nx + 1]
        return q and psi[q]
      end
      local l, r, t, b = at(-1, 0), at(1, 0), at(0, -1), at(0, 1)
      local px = (l and r) and (r - l) / 2 or (r and r - v) or (l and v - l) or 0
      local py = (t and b) and (b - t) / 2 or (b and b - v) or (t and v - t) or 0
      -- Steepest way down on the ground, as a direction on the screen.
      local fx, fy = -px, -py / (VY * VY)
      local len = sqrt(fx * fx + fy * fy)
      if len > 1e-9 then ux[j], uy[j] = fx / len, fy / len else ux[j], uy[j] = 0, 0 end
    end
  end
  -- Smoothed twice over the neighbours.
  for _ = 1, 2 do
    local sx, sy = {}, {}
    for j = 1, n do
      if ux[j] then
        local x, y = wx[j], wy[j]
        local ax, ay = ux[j], uy[j]
        for i = 1, 8 do
          local o = NB[i]
          local nx, ny = x + o[1], y + o[2]
          if nx >= 0 and ny >= 0 and nx < w and ny < h then
            local q = jOf[ny * w + nx + 1]
            if q and ux[q] then ax, ay = ax + ux[q], ay + uy[q] end
          end
        end
        local len = sqrt(ax * ax + ay * ay)
        if len > 1e-9 then sx[j], sy[j] = ax / len, ay / len else sx[j], sy[j] = ux[j], uy[j] end
      end
    end
    ux, uy = sx, sy
    step()
  end
  W.fux, W.fuy = ux, uy

  -- Rings and the reflection: how far from where a fall lands in this
  -- water (squashed: seen from the side), and the landing right above.
  local hitting = {}
  for _, s in ipairs(B.segs) do if s.pool then hitting[#hitting + 1] = s end end
  local e, ry = {}, {}
  for j = 1, n do
    local x, y = wx[j], wy[j]
    local best = 999
    local X = x + 0.5
    local r0 = -1
    for _, s in ipairs(hitting) do
      local dx = 0
      if X < s.xa then dx = s.xa - X elseif X > s.xb + 1 then dx = X - s.xb - 1 end
      local dy = (y - s.yMax - 0.5) / RATIO
      local d = sqrt(dx * dx + dy * dy)
      if d < best then best = d end
      if x >= s.xa and x <= s.xb and y > s.yMax and (r0 < 0 or s.yMax > r0) then r0 = s.yMax end
    end
    e[j], ry[j] = best, r0
    if j % 2048 == 0 then step() end
  end
  W.e, W.ry = e, ry
  return W
end

--------------------------------------------------------------------------
-- settings: the drift, the lanes, the flow's clock
--------------------------------------------------------------------------

-- Whether guide rods steer the water (flow rods; lip rods only shape the
-- mouths).
function Flow.guided(p)
  return p.guideOn == true and (p.guideStrength or 0) > 0 and (p.guideReach or 0) > 0
    and type(p.guides) == "table" and #Guide.ofKind(p.guides, "flow") > 0
end

-- The key of what the lanes depend on.
function Flow.lanesKey(p)
  local key = table.concat({ p.seed, (p.drift or 0) > 0 and (p.angle or 0) or -1, p.rangle or 90 }, ":")
  if Flow.guided(p) then
    key = key .. ":" .. p.guideStrength .. ":" .. p.guideReach .. ":" .. Guide.signature(p.guides, "flow")
  end
  return key
end

-- The flow's direction everywhere (rivers away from the falls run their
-- own way; still water drifts when the drift is on; near a guide rod the
-- water runs along it) and the lanes along it. Depends on the seed, the
-- drift, the river's direction and the rods.
function Flow.lanes(W, B, p, step)
  local n = W.n
  local L = { key = Flow.lanesKey(p) }
  if n == 0 then return L end
  local w, h = B.w, B.h
  local jOf, wx, wy = W.jOf, W.x, W.y
  local dux, duy = way(p.angle or 0)
  local rux, ruy = way(p.rangle or 90)
  local driftOn = (p.drift or 0) > 0
  local ux, uy = {}, {}
  local comps, comp, isRiver = W.comps, W.comp, W.river
  for j = 1, n do
    local c = comps[comp[j]]
    if c.sink or c.src then
      ux[j], uy[j] = W.fux[j], W.fuy[j]
    elseif isRiver[j] then
      ux[j], uy[j] = rux, ruy
    elseif driftOn then
      ux[j], uy[j] = dux, duy
    end
  end
  -- Guide rods: near one the water turns to run along it, wholly on the
  -- rod at full strength, less and less out to the reach (still water
  -- too, where they pull it enough to start it); then smoothed once, so it
  -- turns gently where two rods meet.
  local guided = Flow.guided(p)
  if guided then
    local GF = Guide.field(W, B, Guide.chains(Guide.ofKind(p.guides, "flow")), p.guideStrength / 10,
      p.guideReach, step)
    local gw, gtx, gty = GF.w, GF.tx, GF.ty
    for j, a in pairs(gw) do
      if ux[j] or a >= 0.15 then
        local bx, by = (ux[j] or 0) * (1 - a) + gtx[j] * a, (uy[j] or 0) * (1 - a) + gty[j] * a
        local l = sqrt(bx * bx + by * by)
        if l > 1e-6 then ux[j], uy[j] = bx / l, by / l else ux[j], uy[j] = gtx[j], gty[j] end
      end
    end
    local sx, sy = {}, {}
    for j in pairs(gw) do
      local ax, ay = ux[j], uy[j]
      if ax then
        local x, y = wx[j], wy[j]
        for i = 1, 8 do
          local o = NB[i]
          local nx, ny = x + o[1], y + o[2]
          if nx >= 0 and ny >= 0 and nx < w and ny < h then
            local q = jOf[ny * w + nx + 1]
            if q and ux[q] then ax, ay = ax + ux[q], ay + uy[q] end
          end
        end
        local l = sqrt(ax * ax + ay * ay)
        if l > 1e-9 then sx[j], sy[j] = ax / l, ay / l end
      end
    end
    for j, v in pairs(sx) do ux[j], uy[j] = v, sy[j] end
    L.guide = GF
    step()
  end
  L.ux, L.uy = ux, uy
  -- Lanes carried down the flow: every pixel takes the lane of the pixel
  -- just upstream of it, so a lane stays the same down a streamline; where
  -- none is upstream (the river's start, a bank) a new one begins. Fine
  -- lanes (one px wide, random) give the streaks; coarse ones (a smooth
  -- noise, a few px wide) the drifting foam. A lane starts afresh after a
  -- while (sooner where the water spreads out from a landing), so a few
  -- lanes never fan out over a whole pool.
  local hash, perlin = Noise.hash, Noise.perlin
  local seed = p.seed or 1
  local x0, y0 = B.x0, B.y0
  local dSink, dSrc = W.dSink, W.dSrc
  local function flowing(j)
    local u = ux[j]
    return u and (u ~= 0 or uy[j] ~= 0)
  end
  local order, up = {}, nil
  if guided then
    -- Rods can turn the water any way, so no distance orders it: every
    -- pixel comes after the one just upstream of it, followed up to where
    -- none is (a loop is cut where it closes).
    up = {}
    for j = 1, n do
      if flowing(j) then
        local qx, qy = floor(wx[j] + 0.5 - ux[j]), floor(wy[j] + 0.5 - uy[j])
        local q = (qx >= 0 and qy >= 0 and qx < w and qy < h) and jOf[qy * w + qx + 1] or nil
        if q and q ~= j and flowing(q) then up[j] = q end
      end
    end
    local state, path = {}, {}
    for j = 1, n do
      if flowing(j) and not state[j] then
        local m, k = 0, j
        while k and not state[k] do
          state[k] = 1
          m = m + 1
          path[m] = k
          k = up[k]
        end
        if k and state[k] == 1 then up[path[m]] = nil end
        for i = m, 1, -1 do
          local q = path[i]
          state[q] = 2
          order[#order + 1] = q
        end
      end
    end
    L.up, L.order = up, order
  else
    local key = {}
    for j = 1, n do
      if flowing(j) then
        order[#order + 1] = j
        local c = comps[comp[j]]
        if c.sink or c.src then
          key[j] = (dSink[j] or 0) - (dSrc[j] or 0)
        else
          key[j] = -((x0 + wx[j]) * ux[j] + (y0 + wy[j]) * uy[j] * VY)
        end
      end
    end
    table.sort(order, function(a, b) return key[a] > key[b] end)
  end
  step()
  local fineV, coarseV, age = {}, {}, {}
  for i, j in ipairs(order) do
    local x, y = wx[j], wy[j]
    local q
    if up then
      q = up[j]
    else
      local qx, qy = floor(x + 0.5 - ux[j]), floor(y + 0.5 - uy[j])
      q = (qx >= 0 and qy >= 0 and qx < w and qy < h) and jOf[qy * w + qx + 1] or nil
    end
    local X, Y = x0 + x, y0 + y
    local local_ = perlin((X + 0.5) / 4, (Y + 0.5) * VY / 4, seed + 213)
    if q and q ~= j and fineV[q] then
      local c = comps[comp[j]]
      local maxAge = (c.src and not c.sink) and 14 or 40
      if age[q] >= maxAge then
        fineV[j], age[j] = hash(X, Y, seed + 211), floor(hash(X, Y, seed + 217) * 8)
      else
        fineV[j], age[j] = fineV[q], age[q] + 1
      end
      coarseV[j] = coarseV[q] * 0.92 + local_ * 0.08
    else
      fineV[j], age[j] = hash(X, Y, seed + 211), floor(hash(X, Y, seed + 217) * 8)
      coarseV[j] = local_
    end
    if i % 1024 == 0 then step() end
  end
  local lf, lc = {}, {}
  for _, j in ipairs(order) do
    lf[j] = min(63, floor(fineV[j] * 64))
    lc[j] = max(0, min(63, floor((coarseV[j] + 0.8) / 1.6 * 64)))
  end
  L.lf, L.lc = lf, lc
  return L
end

-- How the water's clock runs (in ground px at the base speed): toward a lip
-- it speeds up, sf(d) = 1 + a e^(-d / s); its time to the lip is then
-- d + s ln(1 + a e^(-d / s)) - s ln(1 + a). From a landing it slows down
-- likewise. A texture slid along this clock speeds up and stretches.
local function clock(d, a, s)
  return d + s * log(1 + a * exp(-d / s)) - s * log(1 + a)
end

-- phi: the clock for every flowing pixel (nil where the water is still);
-- spd: how much faster than the base speed it moves there. Rivers and
-- still water each have their own base speed (their own tables, Scape).
-- With guide rods the water may run any way, so the clock is carried down
-- the lanes instead: from where a lane starts (its clock as without rods)
-- it runs down by the time each step takes.
function Flow.phi(W, B, p, L)
  local n = W.n
  local phi, spd = {}, {}
  local rush = (p.rush or 0) * 0.35
  local outA = 1.2
  local SS, SR = 12, 16
  local driftOn = (p.drift or 0) > 0
  local dux, duy = way(p.angle or 0)
  local rux, ruy = way(p.rangle or 90)
  duy, ruy = duy * VY, ruy * VY
  local comps, comp, dSink, dSrc, isRiver = W.comps, W.comp, W.dSink, W.dSrc, W.river
  for j = 1, n do
    local c = comps[comp[j]]
    local ds, dr = dSink[j], dSrc[j]
    if c.sink or c.src then
      local f, sp = 0, 1
      if ds then
        f = f + clock(ds, rush, SS)
        sp = sp + rush * exp(-ds / SS)
      end
      if dr then
        f = f - clock(dr, outA, SR)
        sp = max(sp, 1 + outA * exp(-dr / SR))
      end
      phi[j], spd[j] = f, sp
    elseif isRiver[j] then
      local X, Y = B.x0 + W.x[j], B.y0 + W.y[j]
      phi[j], spd[j] = -(X * rux + Y * ruy), 1
    elseif driftOn then
      local X, Y = B.x0 + W.x[j], B.y0 + W.y[j]
      phi[j], spd[j] = -(X * dux + Y * duy), 1
    end
  end
  local up = L and L.up
  if up then
    local ux, uy, wx, wy = L.ux, L.uy, W.x, W.y
    for _, j in ipairs(L.order) do
      local sp = spd[j]
      if not sp then
        sp = 1
        spd[j] = 1
      end
      local q = up[j]
      if q and phi[q] then
        local dx, dy = wx[j] - wx[q], (wy[j] - wy[q]) * VY
        phi[j] = phi[q] - sqrt(dx * dx + dy * dy) / sp
      elseif not phi[j] then
        phi[j] = -((B.x0 + wx[j]) * ux[j] + (B.y0 + wy[j]) * uy[j] * VY)
      end
    end
  end
  return phi, spd
end

-- (Clean traces its lines over a field of its own, from the same search.)
Flow.search = search
Flow.VY = VY

return Flow
