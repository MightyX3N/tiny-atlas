-- Clean: the surfaces drawn the way the reference pictures draw rivers and
-- lakes. Flat tones in a few smooth zones (light shallows along the shore,
-- the water, deep and deepest further out), and every mark a run of whole
-- pixels: the shore's line, short glints, the net's walls. Never a lone
-- pixel.
--
-- Zones (they stay put): light shallows along the shore, their edge bent by
-- a smooth noise; further out deep and deepest blotches of a smooth noise,
-- over a share of the open water that Depth sets. Then cleaned: every
-- pixel needs a neighbour of its own zone beside it and one above or below
-- it (so no part is a pixel thin), and a patch of a few pixels joins what
-- is round it. Stones lie in the shallows; where two zones meet a
-- checkerboard can soften the step.
--
-- Everything is measured in pixels of the sprite, times the Size (1x ..
-- 3x, or Auto by the picture's size): a bigger picture gets bigger zones
-- and the same crisp one pixel lines. Last of all a frame loses any lone
-- pixel left where two marks crossed (Clean.despeckle).

local G = ... or _WOWE

local Noise = G.require("noise")
local Mask  = G.require("mask")

local Clean = {}

local floor, sqrt, min, max = math.floor, math.sqrt, math.min, math.max

local SHADOW, DEEP, BASE, LIGHT = 1, 2, 3, 4

-- The Size slider as a factor: 1 .. 5 is 1x .. 3x; 0 (Auto) goes by the
-- picture's size (R, the region: 1x up to 170 px, 3x from 510 px).
function Clean.factor(p, R)
  if p.cleanF then return p.cleanF end
  local s = p.cleanSize or 0
  if s >= 1 then return 1 + (s - 1) * 0.5 end
  local m = R and min(R.sprW or 0, R.sprH or 0) or 0
  if m <= 0 then return 1 end
  return min(3, max(1, m / 170))
end

--------------------------------------------------------------------------
-- zones
--------------------------------------------------------------------------

local function zonesKey(p)
  return table.concat({ p.seed or 1, p.shallows or 0, p.depth or 0, p.rdepth or 0, Clean.factor(p),
    ((p.lap or 0) >= 1) and 1 or 0, ((p.banks or 0) >= 1) and 1 or 0 }, ":")
end

-- The four neighbours of surface pixel j (nil: not water).
local function around(W, w, h)
  local jOf, wx, wy = W.jOf, W.x, W.y
  return function(j, s)
    local x, y = wx[j], wy[j]
    if s == 1 then x = x - 1 elseif s == 2 then x = x + 1 elseif s == 3 then y = y - 1 else y = y + 1 end
    if x < 0 or y < 0 or x >= w or y >= h then return nil end
    return jOf[y * w + x + 1]
  end
end

-- No part of a zone a pixel thin, no patch of a few pixels: a pixel with
-- no neighbour of its own zone beside it, or none above or below it (the
-- ground, a fall or the box's edge count as its own; the shore's line,
-- where it is drawn, does not), takes the zone that most of the pixels
-- round it have and that would hold there; then a patch smaller than minA
-- pixels joins what is round it.
local function tidyOnce(B, p, Z, step)
  local W = B.W
  local n = W.n
  local w, h = B.w, B.h
  local jOf, wx, wy, riv, shore = W.jOf, W.x, W.y, W.river, W.shore
  local f = Clean.factor(p)
  local nbr = around(W, w, h)
  local lineW, lineR = (p.lap or 0) >= 1, (p.banks or 0) >= 1
  local function lined(q) return shore[q] and ((riv[q] and lineR) or (not riv[q] and lineW)) end
  local function same(q, lv)
    if not q then return true end
    if lined(q) then return false end
    return Z[q] == lv
  end
  local cnt = { 0, 0, 0, 0 }
  for _ = 1, 12 do
    local changed = 0
    for j = 1, n do
      if not lined(j) then
        local lv = Z[j]
        local ok = (same(nbr(j, 1), lv) or same(nbr(j, 2), lv)) and (same(nbr(j, 3), lv) or same(nbr(j, 4), lv))
        if not ok then
          local x, y = wx[j], wy[j]
          cnt[1], cnt[2], cnt[3], cnt[4] = 0, 0, 0, 0
          for dy = -1, 1 do
            for dx = -1, 1 do
              local xx, yy = x + dx, y + dy
              if (dx ~= 0 or dy ~= 0) and xx >= 0 and yy >= 0 and xx < w and yy < h then
                local q = jOf[yy * w + xx + 1]
                if q and not lined(q) then
                  local v = Z[q]
                  cnt[v] = cnt[v] + ((dx == 0 or dy == 0) and 2 or 1)
                end
              end
            end
          end
          -- (Only a zone that would hold there; when none would, as
          -- between the shore's line and another zone, it stays.)
          local best, bc = lv, 0
          for v = 1, 4 do
            if v ~= lv and cnt[v] > bc
              and (same(nbr(j, 1), v) or same(nbr(j, 2), v)) and (same(nbr(j, 3), v) or same(nbr(j, 4), v)) then
              best, bc = v, cnt[v]
            end
          end
          if best ~= lv then
            Z[j] = best
            changed = changed + 1
          end
        end
      end
    end
    step()
    if changed == 0 then break end
  end
  local minA = floor(7 * f * f + 0.5)
  local seen, list, border = {}, {}, { 0, 0, 0, 0 }
  for j = 1, n do
    if not seen[j] then
      local lv = Z[j]
      local m = 1
      list[1] = j
      seen[j] = true
      border[1], border[2], border[3], border[4] = 0, 0, 0, 0
      local i = 1
      while i <= m do
        local q = list[i]
        i = i + 1
        for s = 1, 4 do
          local r = nbr(q, s)
          if r then
            local v = Z[r]
            if v == lv then
              if not seen[r] then
                seen[r] = true
                m = m + 1
                list[m] = r
              end
            else
              border[v] = border[v] + 1
            end
          end
        end
      end
      if m < minA then
        local best, bc = nil, 0
        for v = 1, 4 do
          if border[v] > bc then best, bc = v, border[v] end
        end
        if best then
          for q = 1, m do Z[list[q]] = best end
        end
      end
    end
    if j % 4096 == 0 then step() end
  end
  step()
  return Z
end

-- (Joining a patch can leave a pixel thin again: until both hold.)
local function tidy(B, p, Z, step)
  for _ = 1, 4 do
    local before = {}
    for j = 1, B.W.n do before[j] = Z[j] end
    tidyOnce(B, p, Z, step)
    local same = true
    for j = 1, B.W.n do
      if before[j] ~= Z[j] then same = false break end
    end
    if same then break end
  end
  return Z
end

-- The zones: the shallows along the shore (by a distance less squashed
-- than the ground's, a step up or down 1.4: on the far and near shores the
-- band would be thinner than the shore's own line), its edge bent by a
-- smooth noise; further out, deep and deepest blotches of a smooth noise,
-- taking up a share of the open water that Depth sets (so a big lake is
-- no darker than a small one), fading in over a few px from the shallows.
local function makeZones(B, R, p, step)
  local W = B.W
  local n = W.n
  local Z = {}
  if n == 0 then return Z end
  local f = Clean.factor(p)
  local ds, riv, wx, wy, idx = W.ds, W.river, W.x, W.y, W.idx
  local x0, y0 = B.x0, B.y0
  local seed = p.seed or 1
  local perlin = Noise.perlin
  local sh = (p.shallows or 0) * 0.75 * f
  local ampS = 0.8 * f + sh * 0.45
  local kind = B.kind
  local dz = (sh > 0) and Mask.distance(R, function(k) return kind[k] ~= 0 end, step, 1.4) or nil
  -- The deep blotches' noise, spread evenly over 0 .. 1 (a share of the
  -- pixels above any value).
  local u = {}
  for j = 1, n do
    local X, Y = x0 + wx[j] + 0.5, y0 + wy[j] + 0.5
    u[j] = perlin(X / (24 * f), Y / (14 * f), seed + 405) * 0.72 + perlin(X / (10 * f), Y / (6 * f), seed + 407) * 0.28
    if j % 4096 == 0 then step() end
  end
  Noise.even(u)
  step()
  -- Depth d: the share of the open water that is deep (d / 10 of it at
  -- most), the deepest a part of that from 4 up; how far out it fades in.
  local function cuts(d)
    if d <= 0 then return 2, 2, 1 end
    local deep = 1 - d * 0.088
    local most = (d >= 4) and (1 - (d - 3) * 0.045) or 2
    return deep, most, (3 + (10 - d) * 0.5) * f
  end
  local dW, xW, rW = cuts(p.depth or 0)
  local dR, xR, rR = cuts(p.rdepth or 0)
  for j = 1, n do
    local X, Y = x0 + wx[j] + 0.5, y0 + wy[j] + 0.5
    local n1 = perlin(X / (13 * f), Y / (8 * f), seed + 401) * 0.75
      + perlin(X / (5.5 * f), Y / (3.5 * f), seed + 403) * 0.25
    if sh > 0 and dz[idx[j]] + n1 * ampS < sh then
      Z[j] = LIGHT
    else
      local dT, xT, rw = dW, xW, rW
      if riv[j] then dT, xT, rw = dR, xR, rR end
      local r = (ds[j] - sh) / rw
      if r < 0 then r = 0 elseif r > 1 then r = 1 end
      local v = u[j] * r * r * (3 - 2 * r)
      Z[j] = (v > xT) and SHADOW or ((v > dT) and DEEP or BASE)
    end
    if j % 2048 == 0 then step() end
  end
  step()
  return tidy(B, p, Z, step)
end

local function finishKey(p, zk)
  return table.concat({ zk, p.stones or 0, p.dither or 0 }, ":")
end

-- On top of the zones: a checkerboard where zones meet (dither), stones in
-- the shallows.
local function finishZones(B, p, Z0, step)
  local W = B.W
  local n = W.n
  local Z = {}
  for j = 1, n do Z[j] = Z0[j] end
  if n == 0 then return Z end
  local f = Clean.factor(p)
  local w, h, x0, y0 = B.w, B.h, B.x0, B.y0
  local jOf, wx, wy = W.jOf, W.x, W.y
  local seed = p.seed or 1
  local hash = Noise.hash
  local nbr = around(W, w, h)
  local function nb(x, y)
    if x < 0 or y < 0 or x >= w or y >= h then return nil end
    return jOf[y * w + x + 1]
  end

  -- Dither: on the darker side of where two zones meet, a checkerboard of
  -- the lighter tone (the first row half, the next a quarter, then an
  -- eighth), laid by the sprite's pixels so it stays put.
  local dither = p.dither or 0
  if dither > 0 then
    local dist, lighter = {}, {}
    local front = {}
    for j = 1, n do
      local lv = Z[j]
      local best = nil
      for s = 1, 4 do
        local q = nbr(j, s)
        if q and Z[q] > lv and (not best or Z[q] < best) then best = Z[q] end
      end
      if best then
        dist[j], lighter[j] = 1, best
        front[#front + 1] = j
      end
    end
    for d = 2, dither do
      local nf = {}
      for _, j in ipairs(front) do
        for s = 1, 4 do
          local q = nbr(j, s)
          if q and not dist[q] and Z[q] == Z[j] then
            dist[q], lighter[q] = d, lighter[j]
            nf[#nf + 1] = q
          end
        end
      end
      front = nf
    end
    local out = {}
    for j, d in pairs(dist) do
      local X, Y = x0 + wx[j], y0 + wy[j]
      local on
      if d == 1 then on = (X + Y) % 2 == 0
      elseif d == 2 then on = X % 2 == 0 and Y % 2 == 0
      else on = X % 4 == 0 and Y % 2 == 0 and (X // 2 + Y // 2) % 2 == 0 end
      if on then out[j] = lighter[j] end
    end
    for j, v in pairs(out) do Z[j] = v end
    step()
  end

  -- Stones in the shallows: round, a little squashed (seen from the
  -- side), a tone darker than the bed, their lower rim darker still; a
  -- cell of a jittered grid holds one or none.
  local stones = p.stones or 0
  if stones > 0 then
    local cs = (9 + stones * 0.6) * f
    local csy = cs * 0.7
    local share = 0.2 + stones * 0.06
    local cells = {}
    local function stone(ci, cj)
      local key = cj * 65536 + ci
      local s = cells[key]
      if s ~= nil then return s end
      s = false
      if hash(ci, cj, seed + 451) < share then
        local cx = (ci + 0.25 + 0.5 * hash(ci, cj, seed + 452)) * cs
        local cy = (cj + 0.25 + 0.5 * hash(ci, cj, seed + 453)) * csy
        local jc = nb(floor(cx - x0), floor(cy - y0))
        local lv = jc and Z[jc]
        if lv and (lv == LIGHT or (lv == BASE and stones >= 6)) then
          local rx = max(2.6, cs * (0.28 + 0.16 * hash(ci, cj, seed + 454)))
          s = { cx = cx, cy = cy, rx = rx, ry = max(1.8, rx * 0.68), lv = lv, id = key }
        end
      end
      cells[key] = s
      return s
    end
    local sid, slv = {}, {}
    for j = 1, n do
      local X, Y = x0 + wx[j] + 0.5, y0 + wy[j] + 0.5
      local ci, cj = floor(X / cs), floor(Y / csy)
      for b = cj - 1, cj + 1 do
        for a = ci - 1, ci + 1 do
          local s = stone(a, b)
          if s then
            local dx, dy = (X - s.cx) / s.rx, (Y - s.cy) / s.ry
            if dx * dx + dy * dy < 1 then sid[j], slv[j] = s.id, s.lv end
          end
        end
      end
      if j % 2048 == 0 then step() end
    end
    for j, id in pairs(sid) do
      local below = nb(wx[j], wy[j] + 1)
      local lv = slv[j] - 1
      if not below or sid[below] ~= id then lv = lv - 1 end
      Z[j] = max(SHADOW, lv)
    end
    step()
  end
  return Z
end

--------------------------------------------------------------------------
-- the net: walls between whole cells
--------------------------------------------------------------------------

-- The net at loop phase t, as cells: every surface pixel takes the cell
-- (the net's tile, wobbled and slid as the classic net is) it lies in, for
-- each copy; a wall is where a pixel's cell differs from the one beside
-- or below it, shown or hidden whole (each pair of cells has its own
-- moment), so the lines are one pixel and unbroken. Returns surface index
-- -> true for walls and for dark cells (patches).
function Clean.net(F, NSW, NSR, ctx)
  local B = F.base
  local W = B.W
  local n = W.n
  local wall, dark = {}, {}
  if not NSW and not NSR then return wall, dark end
  local hash = Noise.hash
  local w, h, jOf, wx, wy, river = B.w, B.h, W.jOf, W.x, W.y, W.river
  local x0B, y0B = B.x0, B.y0
  local wc, ws, ct, st = ctx.wc, ctx.ws, ctx.ct, ctx.st
  local phi, spd, LUX, LUY = F.phi, F.spd, ctx.LUX, ctx.LUY
  local labA, labB = {}, {}
  local visA, visB = {}, {}
  local seed = ctx.seed
  local SPD_CAP = ctx.SPD_CAP
  for j = 1, n do
    local NS = river[j] and NSR or NSW
    if NS and NS.lines then
      local nT, NT_ = NS.t, NS.T
      local cw = wc[j] * ct - ws[j] * st
      local sw = ws[j] * ct + wc[j] * st
      local bx, by = x0B + wx[j] + cw * NS.wr, y0B + wy[j] + sw * NS.wr
      local ph = phi[j]
      if ph then
        local ux, uy = LUX[j] or 0, LUY[j] or 0
        local sp = spd[j] or 1
        if sp > SPD_CAP then sp = SPD_CAP end
        local m = sp / sqrt(ux * ux + 4 * uy * uy + 1e-9)
        local da, db = NS.shA * m, NS.shB * m
        local ax, ay = bx - ux * da, by - uy * da
        local cx, cy = bx + NS.ox - ux * db, by + NS.oy - uy * db
        labA[j] = nT[(floor(ay) % NT_) * NT_ + floor(ax) % NT_ + 1]
        labB[j] = nT[(floor(cy) % NT_) * NT_ + floor(cx) % NT_ + 1]
        visA[j], visB[j] = NS.visA, NS.visB
      else
        labA[j] = nT[(floor(by) % NT_) * NT_ + floor(bx) % NT_ + 1]
        visA[j] = NS.vis
      end
      local d = NS.dark
      if d > 0 then
        local wa = ph and NS.wA or 1
        if labA[j] < d * wa then dark[j] = true end
        if labB[j] and labB[j] < d * NS.wB then dark[j] = true end
      end
    end
  end
  local function gate(a, b, vis)
    if a > b then a, b = b, a end
    return hash(floor(a * 16777216), floor(b * 16777216), seed + 701) < vis
  end
  for j = 1, n do
    local la = labA[j]
    if la then
      local x, y = wx[j], wy[j]
      local r = (x < w - 1) and jOf[y * w + x + 2] or nil
      local d = (y < h - 1) and jOf[(y + 1) * w + x + 1] or nil
      local va = visA[j]
      if r and labA[r] and labA[r] ~= la and gate(la, labA[r], va) then wall[j] = true
      elseif d and labA[d] and labA[d] ~= la and gate(la, labA[d], va) then wall[j] = true end
      local lb = labB[j]
      if lb and not wall[j] then
        local vb = visB[j]
        if r and labB[r] and labB[r] ~= lb and gate(lb, labB[r], vb) then wall[j] = true
        elseif d and labB[d] and labB[d] ~= lb and gate(lb, labB[d], vb) then wall[j] = true end
      end
    end
  end
  return wall, dark
end

--------------------------------------------------------------------------
-- lines from fields, for a frame
--------------------------------------------------------------------------

-- What a frame's surface loop asks about a pixel's neighbours, for lines
-- drawn as the edge of a region (the pixels inside that have a neighbour
-- outside): always one pixel wide and unbroken, whatever the slant.
-- ctx: w, h, jOf, wx, wy, ds, river, t, rp (phase along the shore), e and
-- dn (rings), tide (tideOn, amp, cyct, ph), lapA / lapAR (how far the
-- lapping line goes out on still water / rivers).
function Clean.kit(ctx)
  local K = {}
  local w, h, jOf, wx, wy = ctx.w, ctx.h, ctx.jOf, ctx.wx, ctx.wy
  local ds, river, rp, e, dn = ctx.ds, ctx.river, ctx.rp, ctx.e, ctx.dn
  local tideOn, amp, cyct, tph = ctx.tideOn, ctx.amp, ctx.cyct, ctx.tidePh
  local t, lapA, lapAR = ctx.t, ctx.lapA, ctx.lapAR
  local cos, TAU = math.cos, math.pi * 2
  local function nbr(j, dx, dy)
    local x, y = wx[j] + dx, wy[j] + dy
    if x < 0 or y < 0 or x >= w or y >= h then return nil end
    return jOf[y * w + x + 1]
  end
  -- The shore as the tide has it now (still water).
  local function dT(q)
    if tideOn and not river[q] then return ds[q] + amp * (0.5 - 0.5 * cos(TAU * (cyct + tph[q]))) end
    return ds[q]
  end
  K.dT = dT
  -- Whether a 4-neighbour of j lies on the far side: f(q) >= v.
  function K.across(j, f, v)
    for s = 1, 4 do
      local q
      if s == 1 then q = nbr(j, 1, 0) elseif s == 2 then q = nbr(j, -1, 0)
      elseif s == 3 then q = nbr(j, 0, 1) else q = nbr(j, 0, -1) end
      if q and f(q) >= v then return true end
    end
    return false
  end
  -- The lapping line: out to lap(q) px from the shore and back, its phase
  -- moving along the shore.
  local function lap(q)
    local a = river[q] and lapAR or lapA
    return 1 + a * (0.5 - 0.5 * cos(TAU * (t + rp[q] * 0.6)))
  end
  K.lap = lap
  function K.lapOff(q) return dT(q) - lap(q) end
  function K.ring(q) return e[q] + dn[q] * 1.6 end
  return K
end

-- The last word: a surface pixel whose colour none of the eight round it
-- shares (where two marks crossed, a bubble's edge, a drop) takes the
-- colour of the neighbour beside it whose colour is commonest round it
-- (the water's own first, on a tie). Twice, for pairs. buf holds a
-- frame's bytes (Codes), LV and EL read them. Returns how many changed.
function Clean.despeckle(B, buf, LV, EL, waterEls)
  local W = B.W
  local w, h, kind = B.w, B.h, B.kind
  local idx, wx, wy = W.idx, W.x, W.y
  local byte = string.byte
  local cnt = {}
  local total = 0
  for _ = 1, 2 do
    local fixK, fixC = {}, {}
    local nf = 0
    for j = 1, W.n do
      local k = idx[j]
      local lv = LV[byte(buf[k])]
      if lv and lv > 0 then
        local x, y = wx[j], wy[j]
        local same = false
        for c = 1, 6 do cnt[c] = 0 end
        for dy = -1, 1 do
          local yy = y + dy
          if yy >= 0 and yy < h then
            local row = yy * w + 1
            for dx = -1, 1 do
              local xx = x + dx
              if (dx ~= 0 or dy ~= 0) and xx >= 0 and xx < w then
                local q = row + xx
                if kind[q] ~= 0 then
                  local l2 = LV[byte(buf[q])]
                  if l2 == lv then
                    same = true
                    break
                  end
                  if l2 and l2 > 0 then cnt[l2] = cnt[l2] + 1 end
                end
              end
            end
            if same then break end
          end
        end
        if not same then
          local best, bestS = nil, -1
          for s = 1, 4 do
            local q
            if s == 1 then q = (x > 0) and k - 1 or nil elseif s == 2 then q = (x < w - 1) and k + 1 or nil
            elseif s == 3 then q = (y > 0) and k - w or nil else q = (y < h - 1) and k + w or nil end
            if q and kind[q] == 2 then
              local c = buf[q]
              local b = byte(c)
              local l2 = LV[b]
              if l2 and l2 > 0 then
                local score = cnt[l2] * 2 + (waterEls[EL[b]] and 1 or 0)
                if score > bestS then best, bestS = c, score end
              end
            end
          end
          if best then
            nf = nf + 1
            fixK[nf], fixC[nf] = k, best
          end
        end
      end
    end
    for i = 1, nf do buf[fixK[i]] = fixC[i] end
    total = total + nf
    if nf == 0 then break end
  end
  return total
end

--------------------------------------------------------------------------
-- prepare
--------------------------------------------------------------------------

-- F.clean: the zones (each part kept while what it depends on stays the
-- same).
function Clean.prepare(F, p, prev, step)
  local B = F.base
  -- (The settings with the Size worked out once, for everything below.)
  local f = Clean.factor(p, F.region)
  p = setmetatable({ cleanF = f }, { __index = p })
  local C = { f = f }
  local old = prev and prev.clean
  local zk = zonesKey(p)
  if old and prev.base == B and old.zonesKey == zk then
    C.zones0 = old.zones0
  else
    C.zones0 = makeZones(B, F.regionL or F.region, p, step)
  end
  C.zonesKey = zk
  local fk = finishKey(p, zk)
  if old and old.zones0 == C.zones0 and old.finishKey == fk then
    C.zones = old.zones
  else
    C.zones = finishZones(B, p, C.zones0, step)
  end
  C.finishKey = fk
  F.clean = C
  return C
end

return Clean
