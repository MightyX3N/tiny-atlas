-- The scene: from a region (Mask) and the settings, one string per frame
-- with a byte per pixel of the region's box (Codes: element, colour, what
-- lies under it; 0 = nothing).
--
-- Falls. Every column of the fall mask is cut into runs; the top of a run
-- is where the water comes over an edge, its bottom where it lands. Down a
-- run the water speeds up (v ~ sqrt of the height): a texture laid along
-- the distance fallen, with that speed folded in, slides down and
-- stretches. It wraps round every P px (how far it slides in a loop), so
-- the loop is seamless.
--
-- Surfaces (Flow measures them): rivers (their own mask and settings) and
-- still water (pools, ponds). Water flows toward the lips (where a fall
-- starts right under a surface) and away from the landings (where a fall
-- hits one); rivers away from the falls run their own way, ponds lie
-- still, or drift. On the water lies a net of light lines: on
-- still water it wobbles in place; on flowing water it slides down the
-- flow, as two copies taking turns (each fades in and out while the other
-- is in full view, the way flowing water is drawn in games with a flow
-- map), so it follows every bend and stretches where the water speeds up.
-- Along the flow runs a clock (faster near a lip): a few streaks and the
-- foam a fall sends down the river are laid along it and along the
-- "lanes", so they follow the water's curves, speed up toward the edge and
-- wrap round every Ds of the clock.
--
-- At a lip the water goes over the edge (Mouth): one band across the edge, column by column: blue teeth reaching
-- up into the river, white water over the edge, cyan streaks hanging into
-- the curtain and their light blue tails, every column its own lengths,
-- bobbing up and down like a wave along the edge. Where the river's mask
-- overlaps the fall's, that overlap is the mouth (the deeper, the longer
-- its white curl); a lip rod (Guide) can draw the edge instead. The
-- falling water has a style of its own: the first strands and slits, long
-- streaks lighter at the top, bands with ragged fringes, or rows of
-- scallops, all sliding down and speeding up. Bands sag down the fall from
-- the lip and break up as they go (arcs). Fast rivers break into white
-- water. Along the shores: a shimmering line, lapping foam, foam piling up
-- where the flow hits a bank; dark shade under top banks; deeper water
-- darker.
--
-- Landings: round bubbles boil, mist rises, droplets jump; rings spread
-- over the water and the fall shows upside down in it.
--
-- From WOWe Generator too: dark patches (whole cells of the net, or round
-- spots when there is no net), wave lines rolling in to still water's
-- shores, and the tide: still water climbs past its mask and falls back
-- to it, leaving the ground wet for a while.
--
-- Everything that moves is a function of the loop phase t (0 .. 1) that
-- comes back to itself at t = 1, so frame n + 1 would be frame 1 again.
--
-- Work is split so a change redoes only what it has to:
--   base     the masks: runs, landings, the surfaces' distances (Flow)
--   noise    per-pixel noise (seed)
--   tex      the fall's texture (seed, fall speed, frames)
--   lanes    the flow's direction and lanes (seed, drift)
--   ftex     the flow's streak and foam tables (seed, river speed, frames)
--   statics  thresholds from the sliders, the clock, the particles (cheap)
--   frame    the rest, cheap per pixel

local G = ... or _WOWE

local Noise = G.require("noise")
local Codes = G.require("codes")
local Flow  = G.require("flow")
local Guide = G.require("guide")
local Mask  = G.require("mask")
local Clean = G.require("clean")
local Mouth = G.require("mouth")

local Scape = {}

local floor, sqrt, cos, sin, abs, min, max = math.floor, math.sqrt, math.cos, math.sin,
  math.abs, math.min, math.max
local TAU, PI = math.pi * 2, math.pi
local huge = math.huge
local byte = string.byte

local SHADOW, DEEP, BASE, LIGHT, HIGH, FOAM = 1, 2, 3, 4, 5, 6
Scape.SHADOW, Scape.DEEP, Scape.BASE, Scape.LIGHT, Scape.HIGH, Scape.FOAM = SHADOW, DEEP, BASE, LIGHT, HIGH, FOAM

local E = Codes.E
local C, LVB, ELB, UNB = Codes.C, Codes.LV, Codes.EL, Codes.UN
local E_WATER, E_DEEP, E_FALL, E_GAP, E_LINE, E_LIP, E_EDGE = E.WATER, E.DEEP, E.FALL, E.GAP, E.LINE, E.LIP, E.EDGE
local E_STREAK, E_SHORE, E_SHADE, E_RING, E_TRAIL = E.STREAK, E.SHORE, E.SHADE, E.RING, E.TRAIL
local E_FOAM, E_SPRAY, E_MIST, E_SPARK = E.FOAM, E.SPRAY, E.MIST, E.SPARK
local E_NET, E_PATCH, E_WAVE, E_WET = E.NET, E.PATCH, E.WAVE, E.WET
local CH0 = Codes.CH0
local CLEAN_WATER = { [E_WATER] = true, [E_DEEP] = true }

local function nop() end

-- How the water is squashed seen from the side (about 30 degrees up).
local RATIO = Flow.RATIO
-- How soon a fall speeds up: twice its speed at the top after 3 * S0 px.
local S0 = 16

-- The fall texture's period: how far it slides at the top in a loop (px).
function Scape.period(p)
  local px = 0.25 + (p.speed or 5) * 0.35
  return max(4, floor(px * (p.frames or 16) + 0.5))
end

local function clockPeriod(speed, frames)
  local px = 0.15 + speed * 0.22
  return max(4, floor(px * (frames or 16) + 0.5))
end

-- The flow's period: how far the rivers' clock runs in a loop.
function Scape.flowPeriod(p)
  return clockPeriod(p.flow or 4, p.frames)
end

-- The still water's: its drift, or a slow current where a fall feeds it.
function Scape.waterPeriod(p)
  local d = p.drift or 0
  return clockPeriod((d > 0) and d or 3, p.frames)
end

-- Foam, spray and rings run this many times a loop (more for long loops,
-- so they keep their pace).
function Scape.cycles(p)
  return max(1, floor((p.frames or 16) / 14 + 0.5))
end

Scape.even = Noise.even

--------------------------------------------------------------------------
-- base: the masks
--------------------------------------------------------------------------

local function makeBase(R, step)
  local w, h = R.w, R.h
  local water = R.water
  local N = w * h
  -- A gap of 1 or 2 px between a surface and the top of a fall under it is
  -- closed: the fall reaches up to the water.
  local fall = {}
  for k = 1, N do fall[k] = R.fall[k] end
  for x = 0, w - 1 do
    for y = 1, h - 1 do
      local k = y * w + x + 1
      if fall[k] and not fall[k - w] and not water[k - w] then
        for g = 2, 3 do
          local yy = y - g
          if yy < 0 then break end
          local q = yy * w + x + 1
          if fall[q] then break end
          if water[q] then
            for z = yy + 1, y - 1 do fall[z * w + x + 1] = true end
            break
          end
        end
      end
    end
  end
  local kind = {}
  for k = 1, N do kind[k] = fall[k] and 1 or (water[k] and 2 or 0) end

  -- Across every row: fall pixels from it to its span's edge (the water
  -- goes on past the sprite's edge, so no edge there).
  local leftOpen, rightOpen = R.x0 == 0, R.x0 + w == R.sprW
  local dl, dr = {}, {}
  for y = 0, h - 1 do
    local row = y * w
    local run = leftOpen and 99 or 0
    for x = 0, w - 1 do
      local k = row + x + 1
      if fall[k] then dl[k] = run run = run + 1 else run = 0 end
    end
    run = rightOpen and 99 or 0
    for x = w - 1, 0, -1 do
      local k = row + x + 1
      if fall[k] then dr[k] = run run = run + 1 else run = 0 end
    end
  end
  step()

  -- Down every column: runs of falling water.
  local topOpen, bottomOpen = R.y0 == 0, R.y0 + h == R.sprH
  local runs, runOf = {}, {}
  local cx0, cx1 = huge, -1
  for x = 0, w - 1 do
    local y = 0
    while y < h do
      if fall[y * w + x + 1] then
        local yT = y
        while y < h and fall[y * w + x + 1] do y = y + 1 end
        local r = { x = x, yT = yT, yB = y - 1 }
        runs[#runs + 1] = r
        for yy = yT, y - 1 do runOf[yy * w + x + 1] = r end
        if x < cx0 then cx0 = x end
        if x > cx1 then cx1 = x end
      else
        y = y + 1
      end
    end
  end
  -- A run starting beside one that began well above it is the same water
  -- sliding sideways (the mask's side is not straight): it carries on that
  -- one's fall instead of starting at an edge of its own. Likewise a run
  -- ending beside one that goes on well below it does not land. Coming in
  -- over the sprite's top: no edge; going out at its bottom: no landing.
  -- Right under a surface the water comes off it (fed): no top band.
  local function beside(x, y)
    if y < 0 or y >= h then return nil, nil end
    return (x > 0) and runOf[y * w + x] or nil, (x < w - 1) and runOf[y * w + x + 2] or nil
  end
  local fedRuns = {}
  table.sort(runs, function(a, b) return a.yT < b.yT end)
  for _, r in ipairs(runs) do
    local best, bestS = nil, -1
    local a, b = beside(r.x, r.yT - 1)
    if a and a.yT < r.yT - 2 and a.s0 + r.yT - a.yT > bestS then best, bestS = a, a.s0 + r.yT - a.yT end
    if b and b.yT < r.yT - 2 and b.s0 + r.yT - b.yT > bestS then best, bestS = b, b.s0 + r.yT - b.yT end
    if best then
      r.s0, r.top, r.lip, r.fed = bestS, best.top, false, best.fed
    else
      r.lip = not (topOpen and r.yT == 0)
      r.s0 = r.lip and 0 or 30
      r.top = R.y0 + r.yT
      r.fed = false
      -- Water on a surface just above (a gap of up to 2 px is forgiven).
      for gapY = 1, 3 do
        local yy = r.yT - gapY
        if yy < 0 or r.fed then break end
        local up = yy * w + r.x + 1
        if kind[up] == 1 then break end
        if kind[up] == 2 or (r.x > 0 and kind[up - 1] == 2) or (r.x < w - 1 and kind[up + 1] == 2) then
          r.fed, r.gapY = true, gapY
          r.above = (kind[up] == 2) and up or ((r.x > 0 and kind[up - 1] == 2) and up - 1 or up + 1)
          fedRuns[#fedRuns + 1] = r
        end
      end
    end
    local lands = not (bottomOpen and r.yB == h - 1)
    if lands then
      local c, d = beside(r.x, r.yB + 1)
      if (c and c.yB > r.yB + 2) or (d and d.yB > r.yB + 2) then lands = false end
    end
    r.lands = lands
  end
  table.sort(runs, function(a, b)
    if a.x ~= b.x then return a.x < b.x end
    return a.yT < b.yT
  end)
  local n = 0
  local idx, fx, fy, fs, frem, flen, ftop, flip, fdl, fdr, ffed = {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}
  local impacts = {}
  for _, r in ipairs(runs) do
    local L = r.s0 + r.yB - r.yT + 1
    for yy = r.yT, r.yB do
      n = n + 1
      local k = yy * w + r.x + 1
      idx[n], fx[n], fy[n] = k, r.x, yy
      fs[n] = r.s0 + yy - r.yT
      frem[n] = r.lands and (r.yB - yy) or 99
      flen[n] = L
      ftop[n] = r.top
      flip[n] = r.lip
      ffed[n] = r.fed
      fdl[n], fdr[n] = dl[k], dr[k]
    end
    if r.lands then impacts[#impacts + 1] = { x = r.x, y = r.yB } end
  end
  step()

  -- Landings side by side (and at about the same height) make a segment.
  local segs = {}
  for _, im in ipairs(impacts) do
    local best, bd = nil, 4
    for _, s in ipairs(segs) do
      if s.lastX == im.x - 1 then
        local d = abs(s.lastY - im.y)
        if d < bd then best, bd = s, d end
      end
    end
    if best then
      best.xb, best.lastX, best.lastY = im.x, im.x, im.y
      best.cols[im.x] = im.y
      if im.y > best.yMax then best.yMax = im.y end
      if im.y < best.yMin then best.yMin = im.y end
    else
      segs[#segs + 1] = { xa = im.x, xb = im.x, lastX = im.x, lastY = im.y,
                          cols = { [im.x] = im.y }, yMax = im.y, yMin = im.y }
    end
  end
  for _, s in ipairs(segs) do
    s.width = s.xb - s.xa + 1
    s.cx = (s.xa + s.xb + 1) / 2
    -- Lands in water?
    local hits = 0
    for x = s.xa, s.xb do
      local y = s.cols[x]
      for dy = 1, 3 do
        local yy = y + dy
        if yy < h and kind[yy * w + x + 1] == 2 then hits = hits + 1 break end
      end
    end
    s.pool = hits >= max(1, s.width * 0.3)
  end

  -- The mouth's columns use the falls' texture too.
  local Rl = R.lip or {}
  for k = 1, N do
    if Rl[k] then
      local x = (k - 1) % w
      if x < cx0 then cx0 = x end
      if x > cx1 then cx1 = x end
    end
  end
  local B = {
    w = w, h = h, x0 = R.x0, y0 = R.y0, N = N, kind = kind,
    n = n, idx = idx, fx = fx, fy = fy, fs = fs, frem = frem, flen = flen, ftop = ftop,
    flip = flip, fed = ffed, fdl = fdl, fdr = fdr, cx0 = cx0, cx1 = cx1,
    segs = segs, fedRuns = fedRuns,
  }
  B.W = Flow.build(B, R, step)
  local buf = {}
  for k = 1, N do buf[k] = CH0 end
  B.buf, B.dirty, B.dirtySet = buf, {}, {}
  return B
end

--------------------------------------------------------------------------
-- noise: by sprite position, for a seed
--------------------------------------------------------------------------

local NEAR_D = 20

local function makeNoise(B, seed, step)
  local Z = {}
  local x0, y0 = B.x0, B.y0
  local perlin, fbm = Noise.perlin, Noise.fbm
  -- The falls: a wobble for the edge of their shading; per column a band
  -- of tone, how high the top band shows and the phases it moves with.
  local sn = {}
  for j = 1, B.n do
    local X, Y = x0 + B.fx[j] + 0.5, y0 + B.fy[j] + 0.5
    sn[j] = perlin(X / 3, Y / 6, seed + 11)
    if j % 2048 == 0 then step() end
  end
  Z.sn = sn
  local band = {}
  local cn, cc, cs = {}, {}, {}
  for x = 0, B.w - 1 do
    local X = x0 + x + 0.5
    band[x] = perlin(X / 4.5, 0.5, seed + 12)
    -- The bank shade per column: how deep it reaches and its phase.
    local a = TAU * 1.5 * perlin(X / 11, 3.5, seed + 111)
    cn[x], cc[x], cs[x] = fbm(X / 7, 0.5, 2, seed + 101), cos(a), sin(a)
  end
  Z.band = band
  -- Per column, for the falls' styles: clumps of about two px, mostly
  -- short, some long; pointed spikes (long and narrow where a smooth noise
  -- crosses 0) for ragged ends that taper.
  local tooth, spike = {}, {}
  for x = 0, B.w - 1 do
    local X = x0 + x
    local g = floor((X + 0.5 + 1.3 * perlin(X / 7, 6.5, seed + 19)) / 2)
    tooth[x] = 0.2 + 0.8 * Noise.hash(g, 3, seed + 23) ^ 1.6
    spike[x] = max(0, 1 - 2.2 * abs(perlin((X + 0.5) / 2.4, 7.5, seed + 29))) ^ 1.5
  end
  Z.tooth, Z.spike = tooth, spike
  Z.cn, Z.cc, Z.cs = cn, cc, cs
  -- The surfaces: depth wobble, shimmer, ring gaps; near the shore the
  -- lapping foam's phase, roughness and holes.
  local W = B.W
  local dn, rc, rs, pg, fc, fs, fn, ho = {}, {}, {}, {}, {}, {}, {}, {}
  local wc, wsn, rp, rg = {}, {}, {}, {}
  for j = 1, W.n do
    local X, Y = x0 + W.x[j] + 0.5, y0 + W.y[j] + 0.5
    dn[j] = perlin(X / 8, Y / 8, seed + 21)
    local a = TAU * 1.3 * perlin(X / 20, Y / 20, seed + 91)
    wc[j], wsn[j] = cos(a), sin(a)
    pg[j] = 0.5 + 0.5 * perlin(X / 2.6, Y / 2.6, seed + 71)
    if W.ds[j] < NEAR_D then
      rc[j] = perlin(X / 3, Y / 3, seed + 61)
      rs[j] = perlin(X / 3, Y / 3, seed + 62)
      local f = TAU * 1.2 * perlin(X / 18, Y / 18, seed + 31)
      fc[j], fs[j] = cos(f), sin(f)
      fn[j] = fbm(X / 4, Y / 4, 2, seed + 41)
      ho[j] = perlin(X / 2.5, Y / 2.5, seed + 51)
      -- Waves rolling in and the tide: their phase along the shore, and
      -- where a wave line breaks.
      rp[j] = perlin(X / 22, Y / 22, seed + 171)
      rg[j] = perlin(X / 3.5, Y / 3.5, seed + 181)
    else
      rc[j], rs[j], fc[j], fs[j], fn[j], ho[j], rp[j], rg[j] = 0, 0, 0, 0, 0, 0, 0, 0
    end
    if j % 1024 == 0 then step() end
  end
  Z.dn, Z.rc, Z.rs, Z.pg, Z.fc, Z.fs, Z.fn, Z.ho = dn, rc, rs, pg, fc, fs, fn, ho
  Z.wc, Z.ws, Z.rp, Z.rg = wc, wsn, rp, rg
  return Z
end

--------------------------------------------------------------------------
-- tide: the ground round still water that the tide climbs over
--------------------------------------------------------------------------

-- Ground round still water (not a river's banks) up to A px away (on the
-- ground: a step up or down the screen is two), over open ground only:
-- for each pixel how far out it lies (s, negative: the first ring of
-- ground is -0.5, as the water's own shore pixels are 0.5 in) and the
-- noise its shore line and foam need when the water is on it.
local function makeTide(B, A, seed, step)
  local w, h, kind = B.w, B.h, B.kind
  local W = B.W
  local INF = 1e9
  local dist = {}
  for k = 1, B.N do dist[k] = INF end
  for j = 1, W.n do
    if not W.river[j] and not W.lip[j] then dist[W.idx[j]] = 0 end
  end
  local D2 = sqrt(1 + 4)
  -- Two passes of a chamfer over open ground (falls and rivers stop it).
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local k = y * w + x + 1
      if kind[k] == 0 then
        local d = dist[k]
        if x > 0 and dist[k - 1] + 1 < d then d = dist[k - 1] + 1 end
        if y > 0 then
          if dist[k - w] + 2 < d then d = dist[k - w] + 2 end
          if x > 0 and dist[k - w - 1] + D2 < d then d = dist[k - w - 1] + D2 end
          if x < w - 1 and dist[k - w + 1] + D2 < d then d = dist[k - w + 1] + D2 end
        end
        dist[k] = d
      end
    end
  end
  step()
  for y = h - 1, 0, -1 do
    for x = w - 1, 0, -1 do
      local k = y * w + x + 1
      if kind[k] == 0 then
        local d = dist[k]
        if x < w - 1 and dist[k + 1] + 1 < d then d = dist[k + 1] + 1 end
        if y < h - 1 then
          if dist[k + w] + 2 < d then d = dist[k + w] + 2 end
          if x < w - 1 and dist[k + w + 1] + D2 < d then d = dist[k + w + 1] + D2 end
          if x > 0 and dist[k + w - 1] + D2 < d then d = dist[k + w - 1] + D2 end
        end
        dist[k] = d
      end
    end
  end
  step()
  local T = { n = 0, idx = {}, s = {}, rc = {}, rs = {}, fc = {}, fs = {}, fn = {}, ho = {}, rp = {}, iOf = {} }
  local perlin, fbm = Noise.perlin, Noise.fbm
  local n = 0
  for k = 1, B.N do
    local d = dist[k]
    if kind[k] == 0 and d > 0 and d <= A + 0.5 then
      n = n + 1
      local X, Y = B.x0 + (k - 1) % w + 0.5, B.y0 + (k - 1) // w + 0.5
      T.idx[n], T.s[n] = k, -(d - 0.5)
      T.iOf[k] = n
      T.rc[n] = perlin(X / 3, Y / 3, seed + 61)
      T.rs[n] = perlin(X / 3, Y / 3, seed + 62)
      local f = TAU * 1.2 * perlin(X / 18, Y / 18, seed + 31)
      T.fc[n], T.fs[n] = cos(f), sin(f)
      T.fn[n] = fbm(X / 4, Y / 4, 2, seed + 41)
      T.ho[n] = perlin(X / 2.5, Y / 2.5, seed + 51)
      T.rp[n] = perlin(X / 22, Y / 22, seed + 171)
      if n % 1024 == 0 then step() end
    end
  end
  T.n = n
  return T
end

-- How far past its mask the tide may take still water (0: no tide).
function Scape.tideReach(p)
  if not p.tide or (p.tideAmp or 0) <= 0 then return 0 end
  return math.ceil(p.tideAmp) + 1
end

--------------------------------------------------------------------------
-- tex: the falls' texture, per column, wrapping round every P px
--------------------------------------------------------------------------

-- Distance to the nearest wall of a net of tall cells (cw px wide, about
-- 15 px high), wrapping round every P px in v; walls bent a little.
local function netWalls(X, v, P, seed, cw, Jn, ch, wb)
  local hash = Noise.hash
  local x = X + 0.5 + Noise.perlinWrap(X / 4, (v + 0.5) / P * wb, seed + 8, wb) * 1.4
  local y = v + 0.5
  local ci, cj = floor(x / cw), floor(y / ch)
  local b1, b2, b3 = huge, huge, huge
  local ax, ay, bx, by, qx, qy = 0, 0, 0, 0, 0, 0
  for j = cj - 1, cj + 1 do
    local jj = j % Jn
    for i = ci - 2, ci + 2 do
      local sx = cw * (i + 0.15 + 0.7 * hash(i, jj, seed + 31))
      local sy = ch * (j + 0.15 + 0.7 * hash(i, jj, seed + 37))
      local dx, dy = sx - x, sy - y
      local d2 = dx * dx + dy * dy
      if d2 < b3 then
        if d2 < b2 then
          b3, qx, qy = b2, bx, by
          if d2 < b1 then
            b2, bx, by = b1, ax, ay
            b1, ax, ay = d2, sx, sy
          else
            b2, bx, by = d2, sx, sy
          end
        else
          b3, qx, qy = d2, sx, sy
        end
      end
    end
  end
  local ux, uy = bx - ax, by - ay
  local e = (b2 - b1) / (2 * sqrt(ux * ux + uy * uy))
  local vx, vy = qx - ax, qy - ay
  local e3 = (b3 - b1) / (2 * sqrt(vx * vx + vy * vy))
  if e3 < e then e = e3 end
  return e
end

local function makeTex(B, seed, P, step)
  local T = { P = P, c0 = B.cx0, cols = max(0, B.cx1 - B.cx0 + 1) }
  local tone, line, gap, net, gate = {}, {}, {}, {}, {}
  local wrap = Noise.perlinWrap
  local function per(size) return max(1, floor(P / size + 0.5)) end
  local ws, wt, wl, wq, wg = per(28), per(38), per(20), per(9), per(12)
  local Jn = per(15)
  local ch = P / Jn
  local wb = per(12)
  local k = 0
  for c = 0, T.cols - 1 do
    local X = B.x0 + B.cx0 + c
    local Xc = X + 0.5
    for v = 0, P - 1 do
      local y = (v + 0.5) / P
      k = k + 1
      -- Strands (thin, long) over broad bands of tone.
      tone[k] = wrap(Xc / 1.5, y * ws, seed + 2, ws) * 0.55 + wrap(Xc / 4.5, y * wt, seed + 3, wt) * 0.45
      -- Light lines: one or two px wide, long.
      line[k] = wrap(Xc / 1.15, y * wl, seed + 1, wl) * 0.75 + wrap(Xc / 0.6, y * wl * 2, seed + 5, wl * 2) * 0.35
      -- Where the curtain splits.
      gap[k] = wrap(Xc / 2.4, y * wq, seed + 4, wq) * 0.85 + wrap(Xc / 1.1, y * wq * 2, seed + 6, wq * 2) * 0.25
      net[k] = netWalls(X, v, P, seed, 5, Jn, ch, wb)
      gate[k] = wrap(Xc / 5, y * wg, seed + 9, wg)
    end
    step()
  end
  Noise.even(tone) Noise.even(line) Noise.even(gap) Noise.even(gate)
  step()
  T.tone, T.line, T.gap, T.net, T.gate = tone, line, gap, net, gate
  T.key = table.concat({ seed, P, B.x0 + B.cx0, T.cols }, ":")
  return T
end

local function texKey(B, p)
  return table.concat({ p.seed, Scape.period(p), B.x0 + B.cx0, max(0, B.cx1 - B.cx0 + 1) }, ":")
end

-- The flow's tables: per lane (64) a strip wrapping round every Ds of the
-- clock: thin streaks (fine lanes) and foam patches (coarse lanes).
local function makeFlowTex(seed, Ds, step)
  local T = { D = Ds, key = seed .. ":" .. Ds }
  -- (A river's and still water's tables differ by their seed and length.)
  -- And flecks of foam, one or two px, scattered (carried along the rods).
  local wrap, hash = Noise.perlinWrap, Noise.hash
  local st, tt, fk = {}, {}, {}
  local ws = max(1, floor(Ds / 9 + 0.5))
  local wf = max(1, floor(Ds / 12 + 0.5))
  local k = 0
  for l = 0, 63 do
    for v = 0, Ds - 1 do
      local y = (v + 0.5) / Ds
      k = k + 1
      st[k] = wrap(l * 1.37 + 0.5, y * ws, seed + 101, ws) * 0.8 + wrap(l * 2.11 + 0.3, y * ws * 2, seed + 102, ws * 2) * 0.3
      tt[k] = wrap(l * 0.16 + 0.5, y * wf, seed + 103, wf) * 0.75 + wrap(l * 0.37 + 0.2, y * wf * 2, seed + 104, wf * 2) * 0.35
      fk[k] = hash(l, v // 2, seed + 105)
    end
    if l % 16 == 15 then step() end
  end
  T.st, T.tt, T.fk = Noise.even(st), Noise.even(tt), fk
  return T
end

-- Still water's net of light: cell walls over the box (and a few
-- px round it for the wobble), where the net breaks up (spread evenly over
-- 0 .. 1) and a number per cell (dark cells).
-- How far flowing water's net slides in one turn of its two copies (ground
-- px; up to two cells: longer turns would tear it in the bends, shorter
-- ones make it pulse) and how many turns a loop takes, for a clock running
-- D px a loop.
local SPD_CAP = 1.8
function Scape.netTurns(D, cell)
  local k = max(1, math.ceil(D / (cell * 2)))
  return k, D / k
end

-- The net: a tile of cell walls about 110 px a side that repeats without a
-- seam (sprite px, so it stays put when the masks change), and where its
-- lines break up (a tile of its own, of another size, so the two never
-- repeat together). Made once for a seed and a cell size.
local function makeNet(seed, cell, step)
  local n = max(4, floor(110 / cell + 0.5))
  local N = { key = seed .. ":" .. cell }
  N.e, N.t, N.T, N.c = Noise.tileNet(cell, n, seed + 201, cell * 0.3, 4, step)
  N.TG = 96
  N.g = Noise.even(Noise.tileField(N.TG, 5, seed + 301, step))
  return N
end

--------------------------------------------------------------------------
-- statics: what the sliders make of the base
--------------------------------------------------------------------------

local function makeStatics(B, Z, p)
  local S = {}
  local n = B.n
  local fs, flen, fdl, fdr, fx = B.fs, B.flen, B.fdl, B.fdr, B.fx
  local sh = (p.shading or 0) / 10
  local litLeft = p.light ~= "right"
  local g = (p.gaps or 0) / 10
  local add, gthr, ek = {}, {}, {}
  local band, sn = Z.band, Z.sn
  for j = 1, n do
    local l, r = fdl[j], fdr[j]
    local lit, dark = l, r
    if not litLeft then lit, dark = r, l end
    local wd = l + r + 1
    if wd > 150 then wd = 150 end
    -- Round: lighter toward the lit side, darker toward the other.
    local a = 0
    if sh > 0 then
      local lw = 1.2 + wd * 0.16 + sn[j] * 0.8
      local dw = 1.5 + wd * 0.22 + sn[j] * 0.8
      if lit < lw then a = a + sh * 0.6 * (1 - lit / lw) end
      if dark < dw then a = a - sh * 0.75 * (1 - dark / dw) end
    end
    -- Darker under the edge (in the overhang's shade), lighter toward the
    -- foot (the water fills with air).
    local down = min(1, fs[j] / max(1, flen[j]))
    add[j] = a * 0.5 + band[fx[j]] * 0.12 + sn[j] * 0.04 + (down - 0.45) * 0.22
    -- Slits: most at the top, none from about half way down.
    local s = fs[j]
    local glen = max(10, flen[j] * 0.5)
    local f = 1 - s / glen
    if f > 0 then
      gthr[j] = g * 0.42 * f ^ 1.25
    else
      gthr[j] = -1
    end
    -- The outline: 1 on the lit side, -1 on the other.
    if lit == 0 then ek[j] = 1 elseif dark == 0 then ek[j] = -1 else ek[j] = 0 end
  end
  S.add, S.gthr, S.ek = add, gthr, ek
  return S
end

-- How much the flow pushes each surface pixel at its bank (foam piles up
-- where the water runs into a shore or a stone).
local function makePush(W, L)
  local fu = {}
  local ux, uy, gx, gy = L.ux or {}, L.uy or {}, W.gx, W.gy
  for j = 1, W.n do
    local u = ux[j]
    if u then
      local v = -(gx[j] * u + gy[j] * uy[j])
      fu[j] = (v > 0) and v or 0
    else
      fu[j] = 0
    end
  end
  return fu
end

--------------------------------------------------------------------------
-- particles: bubbles, mist, droplets, drips, sparkles
--------------------------------------------------------------------------

local function makeParticles(B, p)
  local hash = Noise.hash
  local seed = p.seed or 1
  local bubbles, puffs, drops = {}, {}, {}
  local foam, spread, size = p.foam or 0, p.spread or 0, p.bubble or 0
  local mist, rise, spray = p.mist or 0, p.rise or 0, p.spray or 0
  for si, s in ipairs(B.segs) do
    local W = s.width
    local half = max(1, W / 2)
    local sd = seed * 7 + si * 131
    -- (A trickle a few px wide off the side of an edge lands without
    -- foam, mist or spray: they would be blobs bigger than itself.)
    if W < 4 then goto continue end
    -- Foam: bubbles born along the landing, swelling and drifting out.
    local nb = (foam > 0) and (math.ceil(W * foam * 0.13) + 2) or 0
    for i = 1, nb do
      local h1, h2 = hash(i, 1, sd), hash(i, 2, sd)
      local x0 = s.xa + h1 * W
      local col = min(s.xb, max(s.xa, floor(x0)))
      local yb = s.cols[col] or s.yMax
      local dir = (x0 - s.cx) / half
      if dir > 1 then dir = 1 elseif dir < -1 then dir = -1 end
      local spreadPx = 1 + spread * 1.1
      bubbles[#bubbles + 1] = {
        x0 = x0,
        y0 = yb + 1.2 - hash(i, 3, sd) * (1.5 + foam * 0.45),
        vx = (dir * 0.8 + (hash(i, 4, sd) - 0.5) * 0.9) * spreadPx,
        rise = 0.5 + hash(i, 5, sd) * (1 + foam * 0.25),
        drop = hash(i, 6, sd) * (s.pool and (1 + spread * 0.45) or 0.8),
        rmax = (2 + size * 0.5) * (0.55 + 0.6 * hash(i, 7, sd)) * (1.2 - 0.45 * abs(dir)),
        ph = h2,
      }
    end
    -- Mist: puffs rising off the landing, swelling and fading.
    local nm = (mist > 0) and math.ceil((W + 10) * mist * 0.09) or 0
    for i = 1, nm do
      local x0 = s.xa - 5 + hash(i, 11, sd) * (W + 10)
      local dir = (x0 - s.cx) / half
      puffs[#puffs + 1] = {
        x0 = x0,
        y0 = s.yMax + 1.5 - hash(i, 12, sd) * 4,
        rise = 2 + rise * 1.8 + hash(i, 13, sd) * 5,
        drift = dir * (2 + hash(i, 14, sd) * 4) + (hash(i, 18, sd) - 0.5) * 4,
        r0 = 2 + hash(i, 15, sd) * 2,
        rg = 2.5 + mist * 0.4 + hash(i, 16, sd) * 3,
        ph = hash(i, 17, sd),
      }
    end
    -- Spray: droplets flung up and out, falling back.
    local nd = (spray > 0) and math.ceil(W * spray * 0.16 + spray) or 0
    local pw = 0.7 + spray * 0.07
    for i = 1, nd do
      local x0 = s.xa + hash(i, 21, sd) * W
      local dir = (x0 >= s.cx) and 1 or -1
      if hash(i, 22, sd) < 0.2 then dir = -dir end
      drops[#drops + 1] = {
        x0 = x0,
        y0 = (s.cols[min(s.xb, max(s.xa, floor(x0)))] or s.yMax) + 0.5,
        hx = dir * (2 + hash(i, 23, sd) * 8) * pw,
        hy = (3 + hash(i, 24, sd) * 9) * pw,
        life = 0.22 + hash(i, 25, sd) * 0.3,
        ph = hash(i, 26, sd),
      }
    end
    ::continue::
  end
  -- Drips: drops breaking off the curtain's sides and falling beside it.
  local drips = {}
  local edges = p.edges or 0
  if edges >= 2 then
    local list = {}
    for j = 1, B.n do
      if (B.fdl[j] == 0 or B.fdr[j] == 0) and B.fs[j] > 3 and B.frem[j] > 6 then list[#list + 1] = j end
    end
    local count = floor(#list * edges * 0.01 + 0.5)
    for i = 1, count do
      local j = list[floor(hash(i, 51, seed) * #list) + 1]
      local side = (B.fdl[j] == 0) and -1 or 1
      drips[#drips + 1] = {
        x0 = B.fx[j] + 0.5 + side * 0.8,
        y0 = B.fy[j] + 0.5,
        dx = side * (0.4 + hash(i, 52, seed) * 1.6),
        len = 5 + hash(i, 53, seed) * 10,
        life = 0.12 + hash(i, 54, seed) * 0.16,
        ph = hash(i, 55, seed),
      }
    end
  end
  -- Sparkles on the falls (short flashes) and on the surfaces.
  local glints = {}
  local amount = p.sparkle or 0
  if amount > 0 then
    local pool = {}
    for j = 1, B.n do
      if B.fdl[j] > 1 and B.fdr[j] > 1 and B.fs[j] > 4 and B.frem[j] > 4 then pool[#pool + 1] = j end
    end
    local count = floor(#pool * amount * 0.0006 + 0.5)
    if #pool > 0 then count = max(count, min(#pool, floor(amount / 2))) end
    for i = 1, count do
      local j = pool[floor(hash(i, 31, seed) * #pool) + 1]
      glints[#glints + 1] = { k = B.idx[j], fall = true, phase = hash(i, 32, seed),
                              life = 0.07 + 0.08 * hash(i, 33, seed) }
    end
    local W = B.W
    pool = {}
    for j = 1, W.n do
      if W.ds[j] > 2.4 and W.e[j] > 6 and not (W.dSink[j] and W.dSink[j] < 14) then pool[#pool + 1] = j end
    end
    count = floor(#pool * amount * 0.0009 + 0.5)
    if #pool > 0 then count = max(count, min(#pool, amount)) end
    for i = 1, count do
      local j = pool[floor(hash(i, 41, seed) * #pool) + 1]
      glints[#glints + 1] = { k = W.idx[j], fall = false, phase = hash(i, 42, seed),
                              life = 0.16 + 0.14 * hash(i, 43, seed), plus = hash(i, 44, seed) < 0.5 }
    end
  end
  return { bubbles = bubbles, puffs = puffs, drops = drops, drips = drips, glints = glints }
end

--------------------------------------------------------------------------
-- prepare
--------------------------------------------------------------------------

-- Everything a frame needs, reusing what `prev` has when it still fits.
function Scape.prepare(R, p, prev, step)
  step = step or nop
  local F = { region = R }
  -- Lip rods (Guide, when the rods are on): edges drawn by hand.
  local lipRods = (p.guideOn and type(p.guides) == "table") and Guide.ofKind(p.guides, "lip") or {}
  local lipKey = (#lipRods > 0) and Guide.signature(lipRods) or ""
  F.lipKey = lipKey
  if prev and prev.region == R and prev.lipKey == lipKey and prev.base then
    F.base, F.regionL = prev.base, prev.regionL
  else
    local RR = R
    if lipKey ~= "" then
      local edges = {}
      for i, r in ipairs(lipRods) do edges[i] = Guide.edge(r) end
      RR = Mask.withLips(R, edges)
    end
    F.regionL = RR
    F.base = makeBase(RR, step)
  end
  local B = F.base
  if prev and prev.base == B and prev.noise and prev.noiseSeed == p.seed then
    F.noise = prev.noise
  else
    F.noise = makeNoise(B, p.seed, step)
  end
  F.noiseSeed = p.seed
  local key = texKey(B, p)
  if prev and prev.tex and prev.tex.key == key then
    F.tex = prev.tex
  else
    F.tex = makeTex(B, p.seed, Scape.period(p), step)
  end
  local lk = Flow.lanesKey(p)
  if prev and prev.base == B and prev.lanes and prev.lanes.key == lk then
    F.lanes = prev.lanes
  else
    F.lanes = Flow.lanes(B.W, B, p, step)
  end
  local Ds = Scape.flowPeriod(p)
  local fk = p.seed .. ":" .. Ds
  if prev and prev.ftex and prev.ftex.key == fk then
    F.ftex = prev.ftex
  else
    F.ftex = makeFlowTex(p.seed, Ds, step)
  end
  local Dw = Scape.waterPeriod(p)
  local wk = (p.seed + 7) .. ":" .. Dw
  if F.ftex.key == wk then
    F.wtex = F.ftex
  elseif prev and prev.wtex and prev.wtex.key == wk then
    F.wtex = prev.wtex
  else
    F.wtex = makeFlowTex(p.seed + 7, Dw, step)
  end
  -- The nets: the still and pooled water's (Cell on the Water page) and
  -- the rivers' (their own Cell); one when both cells are the same. Clean
  -- makes the cells as much bigger as its Size.
  local cf = (p.clean and B.W.n > 0) and Clean.factor(p, R) or 1
  F.cellW = max(6, floor((p.cell or 14) * cf + 0.5))
  F.cellR = max(6, floor((p.rcell or 12) * cf + 0.5))
  local function net(cell)
    local nk = p.seed .. ":" .. cell
    for _, N in ipairs({ F.net or false, prev and prev.net or false, prev and prev.rnet or false }) do
      if N and N.key == nk then return N end
    end
    return makeNet(p.seed, cell, step)
  end
  if ((p.net or 0) > 0 or (p.patches or 0) > 0) and B.W.n > 0 then
    F.net = net(F.cellW)
  elseif prev then
    F.net = prev.net
  end
  if ((p.rnet or 0) > 0 or (p.rpatches or 0) > 0) and (F.regionL.riverCount or 0) > 0 and B.W.n > 0 then
    F.rnet = net(F.cellR)
  elseif prev then
    F.rnet = prev.rnet
  end
  -- The tide: the ground it climbs over, and its phase round the shore
  -- (all together, or in waves along it).
  local A = Scape.tideReach(p)
  if A > 0 and B.W.n > 0 then
    local tk = A .. ":" .. p.seed
    if prev and prev.base == B and prev.tideBand and prev.tideBand.key == tk then
      F.tideBand = prev.tideBand
    else
      F.tideBand = makeTide(B, A, p.seed, step)
      F.tideBand.key = tk
    end
    local un = (p.tideUneven or 0) / 10 * 1.5
    local rp, ph, bph = F.noise.rp, {}, {}
    for j = 1, B.W.n do ph[j] = (rp[j] * un) % 1 end
    local TB = F.tideBand
    for i = 1, TB.n do bph[i] = (TB.rp[i] * un) % 1 end
    F.tidePh, F.tideBPh = ph, bph
  elseif prev and prev.base == B then
    F.tideBand = prev.tideBand
  end
  F.phi, F.spd = Flow.phi(B.W, B, p, F.lanes)
  F.fu = makePush(B.W, F.lanes)
  F.statics = makeStatics(B, F.noise, p)
  F.parts = makeParticles(B, p)
  -- The clean surfaces (Clean): their zones.
  if p.clean and B.W.n > 0 then
    Clean.prepare(F, p, prev, step)
  elseif prev then
    F.clean = prev.clean
  end
  -- The band over every edge (Mouth).
  local mk = Mouth.key(p)
  if prev and prev.base == B and prev.mouth and prev.mouth.key == mk then
    F.mouth = prev.mouth
  else
    F.mouth = Mouth.prepare(B, p)
  end
  step()
  return F
end

--------------------------------------------------------------------------
-- a frame
--------------------------------------------------------------------------

-- The pixels at loop phase t (0 .. 1), as a string of one byte per pixel
-- of the box (Codes).
function Scape.levels(F, p, t, step)
  step = step or nop
  local B, Z, X, S = F.base, F.noise, F.tex, F.statics
  local w, buf, kind = B.w, B.buf, B.kind
  local ct, st = cos(TAU * t), sin(TAU * t)
  local cyc = Scape.cycles(p)
  local tc = t * cyc

  -- Ground pixels drawn on last time (foam, mist, spray) go back to
  -- nothing; every water pixel is drawn again below.
  local dirty, dirtySet = B.dirty, B.dirtySet
  for i = 1, #dirty do buf[dirty[i]] = CH0 end
  local function onGround(k)
    if not dirtySet[k] then
      dirtySet[k] = true
      dirty[#dirty + 1] = k
    end
  end

  local P = X.P
  local off = t * P
  local tone, line = X.tone, X.line
  local c0 = X.c0
  -- The band over every edge (Mouth): its runs, how they bob now.
  local MO = F.mouth or { runs = {}, rid = {}, sj = {}, se = {} }
  local mRuns, mBob, mLevel = MO.runs, Mouth.bob(MO, p, t), Mouth.level

  ------------------------------------------------------------------ falls
  local n = B.n
  if n > 0 then
    local gap, net, gate = X.gap, X.net, X.gate
    local idx, fx, fs, frem, ftop, fed = B.idx, B.fx, B.fs, B.frem, B.ftop, B.fed
    local add, gthr, ek = S.add, S.gthr, S.ek
    local lines, netAmt, edges = p.lines or 0, p.weave or 0, p.edges or 0
    -- Texture values are spread evenly over 0 .. 1 (shares of the pixels).
    local lineHi = (lines > 0) and (1 - lines * 0.022) or 9
    local lineTop = 1 - lines * 0.007
    local lineLo = lines * 0.01
    local netOn = netAmt > 0
    local netVis = netAmt * 0.06
    local netW = 0.45 + netAmt * 0.01
    local holeThr = (edges >= 5) and (1 - (edges - 4) * 0.035) or 9
    local gapCore = (p.gaps or 0) >= 4
    -- Arcs: bands sagging across the fall, born at the top, darkening and
    -- breaking up as they fall (mA of them a loop, so they loop).
    local arcs = p.arcs or 0
    local arcOn = arcs > 0
    local mA = max(1, floor(P / (8 + (10 - arcs) * 0.6) + 0.5))
    local LbA = P / mA
    local arcLen = 8 + arcs * 3.5
    local sagK = 1.2 + arcs * 0.15
    local fdl, fdr = B.fdl, B.fdr
    local flen, flip = B.flen, B.flip
    local cFall, cGap, cLine, cLip, cEdge = C[E_FALL], C[E_GAP], C[E_LINE], C[E_LIP], C[E_EDGE]
    -- The style of the falling water, and its bands (a whole number of
    -- them a loop; the scallops' rows take turns, so an even number).
    local style = p.fallStyle or "classic"
    local classic, streaky = style == "classic", style == "streaks"
    local mF = max(1, floor(P / 18 + 0.5))
    local LbF = P / mF
    local mS = max(2, 2 * floor(P / 28 + 0.5))
    local LbS = P / mS
    local arcW = 11
    local tooth, spike = Z.tooth, Z.spike
    local mRid = MO.rid
    for j = 1, n do
      local x = fx[j]
      local s = fs[j]
      -- Fallen u px (sped up), plus where the run starts (so steps of a
      -- cascade do not repeat each other).
      local u = 2 * S0 * (sqrt(1 + s / S0) - 1) + ftop[j]
      local k = (x - c0) * P + floor((u - off) % P) + 1
      local L = line[k]
      local lv, cc = BASE, cFall
      if classic or streaky then
        local T = tone[k] + add[j]
        if classic then
          lv = (T < 0.24) and DEEP or ((T < 0.74) and BASE or LIGHT)
        else
          lv = (T < 0.3) and DEEP or ((T < 0.75) and BASE or LIGHT)
        end
        if L > lineHi then
          lv = (L > lineTop or lv == LIGHT) and HIGH or LIGHT
          cc = cLine
        elseif L < lineLo and lv > DEEP then
          lv = lv - 1
        end
        if streaky and lv < HIGH and s < (6 + flen[j] * 0.18) * (0.45 + 0.6 * tooth[x] + 0.5 * spike[x]) then
          -- Long streaks: the sheet is lighter at the top, down to a
          -- ragged end.
          lv = lv + 1
        end
      else
        local f
        if style == "fringe" then
          -- Curtains from light to dark, each hanging in long ragged
          -- fringes over the next, sliding down.
          f = ((u - off) / LbF + 0.25 * tooth[x] + 0.55 * spike[x] + 0.0137) % 1
        else
          -- Rows of scallops, every other row half an arch over.
          local f0 = (u - off) / LbS
          local xo = ((x + (floor(f0) % 2) * arcW * 0.5) % arcW) / arcW
          -- (A hair off, so a whole number of px never lands right on a
          -- threshold, where rounding could change it a loop later.)
          f = (f0 + 0.45 * (1 - (2 * xo - 1) ^ 2) + 0.0137) % 1
        end
        lv = (f < 0.12) and HIGH or ((f < 0.45) and LIGHT or ((f < 0.82) and BASE or DEEP))
        if style == "fringe" then
          -- Lighter near the top, darker toward the foot.
          local g = s / max(1, flen[j])
          if g < 0.22 and lv < HIGH then lv = lv + 1 elseif g > 0.62 and lv > DEEP then lv = lv - 1 end
        end
        local a = add[j]
        if a > 0.18 and lv < HIGH then lv = lv + 1 elseif a < -0.22 and lv > DEEP then lv = lv - 1 end
        if L > 1 - lines * 0.012 then lv, cc = HIGH, cLine end
      end
      if classic and netOn and net[k] < netW and gate[k] < netVis then
        lv = (lv >= LIGHT) and HIGH or LIGHT
        if netAmt >= 8 and lv == HIGH and net[k] < netW * 0.5 then lv = FOAM end
        cc = cLine
      end
      local q = gap[k]
      local isGap = false
      if (classic or streaky) and q < gthr[j] and s > 2 then
        -- A slit: the curtain splits and the dark shows through.
        lv = (gapCore and q < gthr[j] * 0.55) and SHADOW or DEEP
        cc, isGap = cGap, true
      end
      local e = ek[j]
      local isEdge = false
      if e ~= 0 and edges > 0 then
        if q > holeThr then
          lv = 0
        elseif e > 0 then
          if L > 0.9 - edges * 0.035 then lv = FOAM
          elseif L > 0.45 - edges * 0.04 then
            if lv < HIGH then lv = HIGH end
          elseif lv < LIGHT then lv = LIGHT end
          cc, isEdge = cEdge, true
        elseif not isGap then
          lv = (edges >= 4) and ((lv > DEEP) and DEEP or SHADOW) or ((lv > DEEP) and lv - 1 or lv)
          cc, isEdge = cEdge, true
        end
      end
      if arcOn and lv > 0 and s < arcLen and not isEdge and (classic or streaky) then
        local l, rr = fdl[j], fdr[j]
        local wd = l + rr + 1
        if wd < 150 then
          local a = (l + 0.5) / wd
          local sag = sagK * (1 + s * 0.06) * (1 - (2 * a - 1) ^ 2) * min(1, wd / 8)
          if (u - sag - off) % LbA < 1 then
            local f = s / arcLen
            if gate[k] > f * 1.1 - 0.1 then
              lv = (f < 0.35 or lv >= LIGHT) and HIGH or LIGHT
              cc = cLine
            end
          end
        end
      end
      if lv > 0 and frem[j] < 2 and not isEdge then
        -- The foot of the run churns.
        lv = lv + 1
        if lv > HIGH then lv = HIGH end
      end
      -- Over the edge: the mouth's band.
      local ri = mRid[j]
      if ri then
        local ml = mLevel(mRuns[ri], s, mBob[ri], true)
        if ml then lv, cc = ml, cLip end
      end
      local under = (cc == cFall or cc == cGap) and 0 or 7
      buf[idx[j]] = (lv > 0) and cc[under + lv] or CH0
      if j % 1024 == 0 then step() end
    end
  end

  --------------------------------------------------------------- surfaces
  local W = B.W
  local wn = W.n
  if wn > 0 then
    local widx, wds, wup, we, wry, wx, wy = W.idx, W.ds, W.up, W.e, W.ry, W.x, W.y
    local dSink, sinkLab, dSrc, wshore = W.dSink, W.sinkLab, W.dSrc, W.shore
    local lips = W.lips
    local phi, spd, fu = F.phi, F.spd, F.fu
    local lf, lc = F.lanes.lf or {}, F.lanes.lc or {}
    -- Where guide rods pull the water: more streaks, still water most (a
    -- current through a pond), and a line of foam carried along each rod
    -- (the way foam marks a current).
    local gW = F.lanes.guide and F.lanes.guide.w
    local gFoam = (p.guideFoam or 0) * 0.022
    -- Rivers and still water: their own tables and settings.
    local FT, WT = F.ftex, F.wtex
    local STr, TTr, Dr = FT.st, FT.tt, FT.D
    local STw, TTw, Dw = WT.st, WT.tt, WT.D
    local FKr, FKw = FT.fk, WT.fk
    local tDr, tDw = t * Dr, t * Dw
    local isRiver = W.river
    local dn, rc, rs, pg, fc, fsn, fnz, ho = Z.dn, Z.rc, Z.rs, Z.pg, Z.fc, Z.fs, Z.fn, Z.ho
    local cn, ccol, cs = Z.cn, Z.cc, Z.cs
    local cWater, cDeep, cStreak, cShore, cShade = C[E_WATER], C[E_DEEP], C[E_STREAK], C[E_SHORE], C[E_SHADE]
    local cRing, cTrail, cLip = C[E_RING], C[E_TRAIL], C[E_LIP]
    -- Depth and shade.
    local depthW, depthR = p.depth or 0, p.rdepth or 0
    local depthDW = (depthW > 0) and (3 + (10 - depthW) * 1.6) or 1e9
    local depthDR = (depthR > 0) and (3 + (10 - depthR) * 1.6) or 1e9
    local shadeOn = (p.shade or 0) > 0
    local sdBase = (p.shade or 0) * 0.9
    -- Streaks (where a river runs fast) and the foam carried down it.
    local streaks = p.streaks or 0
    local sShareR = streaks * 0.008
    local rapids = (p.rapids or 0) * 0.035
    local trail = p.trail or 0
    local trailLen = 8 + trail * 7
    -- Rings and the reflection.
    local K = p.ripples or 0
    local Rmax = 6 + (p.reach or 0) * 4.5
    local churnR = 1.2 + (p.foam or 0) * 0.25
    local tr = t * cyc
    local reflLen = (p.reflect or 0) * 2.2
    local t2 = TAU * 2 * t
    -- The shore: a shimmering line, lapping foam, foam piling up.
    local foW, foR = p.lap or 0, p.banks or 0
    local fBaseW, fAmpW, fRoughW = 0.5 + (foW - 2) * 0.33, 0.3 + (foW - 2) * 0.2, 0.4 + foW * 0.1
    local fBaseR, fAmpR, fRoughR = 0.5 + (foR - 2) * 0.33, 0.3 + (foR - 2) * 0.2, 0.4 + foR * 0.1
    local flowFoam = 1.2 + (p.flow or 4) * 0.2
    -- The water just above an edge: the mouth's band (its teeth, its
    -- white core where the river overlaps the fall).
    local mSj, mSe = MO.sj, MO.se
    -- The net: light lines and darker cells (patches); with no lines,
    -- round dark spots swelling and shrinking. Still water's
    -- wobbles in place, flowing water's slides down the flow (two copies in
    -- turn). The still and pooled water's net and the rivers' each have
    -- their own settings.
    local function netSet(N, amt, cell, patches, D)
      if not N or (amt <= 0 and patches <= 0) then return nil end
      local full = (amt > 0) and min(1, 0.25 + amt * 0.075) or 0
      local k, Dc = Scape.netTurns(D, cell)
      local tA, tB = (t * k) % 1, (t * k + 0.5) % 1
      local wA = 1 - abs(2 * tA - 1)
      return { e = N.e, g = N.g, t = N.t, c = N.c, T = N.T, TG = N.TG,
               lines = amt > 0, vis = full, line = (amt >= 8) and FOAM or HIGH,
               halo = (amt >= 7) and ((amt - 6) * 0.3) or 0,
               wr = 0.7 + cell * 0.035, dark = patches * 0.05, spotDark = patches * 0.06, spotR = 1 / (cell * 0.34),
               shA = tA * Dc, shB = tB * Dc, wA = wA, wB = 1 - wA, visA = wA * full, visB = (1 - wA) * full,
               ox = floor(N.T * 0.37) + 0.31, oy = floor(N.T * 0.61) + 0.17 }
    end
    local NSW = netSet(F.net, p.net or 0, F.cellW or p.cell or 14, p.patches or 0, Dw)
    local NSR = netSet(F.rnet, p.rnet or 0, F.cellR or p.rcell or 12, p.rpatches or 0, Dr)
    local cNet, cPatch, cWave = C[E_NET], C[E_PATCH], C[E_WAVE]
    -- The tide: still water climbs up to amp px past its shore and back.
    local TB = F.tideBand
    local tideOn = TB ~= nil and Scape.tideReach(p) > 0 and F.tidePh ~= nil
    local amp = tideOn and p.tideAmp or 0
    local cyct = (p.tideCycles or 1) * t
    local tPh = F.tidePh
    -- Wave lines rolling in to still water's shores.
    local waves = p.waves or 0
    local spanW = 5 + 2.5 * waves
    local fwMax = (foW >= 2) and (fBaseW + fAmpW + 0.5) or 1
    local rpZ, rgZ = Z.rp, Z.rg
    local LUX, LUY = F.lanes.ux or {}, F.lanes.uy or {}
    local x0B, y0B = B.x0, B.y0
    local wc, wsn = Z.wc, Z.ws
    -- Clean (Clean): flat zones, the net as walls between whole cells;
    -- everything else drawn as unbroken lines too (the shore, its lapping,
    -- rings, wave lines).
    local clean = p.clean == true and F.clean ~= nil
    local CK
    if clean then
      local lapA = 0.6 + max(0, foW - 2) * 0.32
      CK = Clean.kit({ w = w, h = B.h, jOf = W.jOf, wx = wx, wy = wy, ds = wds, river = isRiver, t = t,
        rp = rpZ, e = we, dn = dn, tideOn = tideOn, amp = amp, cyct = cyct, tidePh = tPh,
        lapA = lapA, lapAR = 0.6 + max(0, foR - 2) * 0.32 })
      CK.zones = F.clean.zones
      CK.wall, CK.dark = Clean.net(F, NSW, NSR, {
        wc = wc, ws = wsn, ct = ct, st = st, LUX = LUX, LUY = LUY, seed = p.seed or 1, SPD_CAP = SPD_CAP,
      })
      if foW >= 2 then fwMax = 1 + lapA + 0.5 end
    end
    for j = 1, wn do
      local k = widx[j]
      local d = wds[j]
      local nd = dn[j]
      local riv = isRiver[j]
      local cc, lv = cWater, BASE
      if clean then
        lv = CK.zones[j] or BASE
        if lv <= DEEP then cc = cDeep end
      elseif d + nd * 2.2 > (riv and depthDR or depthDW) then
        cc, lv = cDeep, DEEP
      end
      local e = we[j]
      if e < churnR then cc, lv = cWater, LIGHT
      elseif e < churnR + 4 + nd * 2 and lv <= DEEP then cc, lv = cWater, BASE end
      if shadeOn then
        local u = wup[j]
        if u < 40 then
          local col = wx[j]
          local sd = sdBase * (0.75 + 0.35 * cn[col]) + 0.9 * (ccol[col] * ct - cs[col] * st)
          if u < sd then
            cc, lv = cShade, (lv >= LIGHT) and DEEP or SHADOW
          elseif u < sd + 1.6 then
            cc, lv = cShade, (lv >= LIGHT) and BASE or DEEP
          end
        end
      end
      -- The shore as the tide has it now (still water only).
      local dT = d
      if tideOn and not riv then dT = d + amp * (0.5 - 0.5 * cos(TAU * (cyct + tPh[j]))) end
      local ph = phi[j]
      local NS = NSW
      if riv then NS = NSR end
      if NS and clean and NS.lines then
        if CK.dark[j] then cc, lv = cPatch, (lv >= BASE) and DEEP or SHADOW end
        if CK.wall[j] then cc, lv = cNet, min(HIGH, lv + ((NS.line == FOAM) and 2 or 1)) end
      elseif NS then
        local nE, nG, nT, nC, NT_, TG = NS.e, NS.g, NS.t, NS.c, NS.T, NS.TG
        local cw = wc[j] * ct - wsn[j] * st
        local sw = wsn[j] * ct + wc[j] * st
        local bx, by = x0B + wx[j] + cw * NS.wr, y0B + wy[j] + sw * NS.wr
        local ev, thr, dark = 9, 0, false
        -- Copies of the net: still water's one, wobbling in place; flowing
        -- water's two, sliding down the flow (from upstream), each fading
        -- out as it has gone a turn while the other fades in, the second
        -- from another part of the net. Faster near a lip (it stretches);
        -- a step down the screen is two on the ground.
        local ux, uy, m = 0, 0, 0
        local copies = 1
        if ph then
          ux, uy = LUX[j] or 0, LUY[j] or 0
          local sp = spd[j] or 1
          if sp > SPD_CAP then sp = SPD_CAP end
          m = sp / sqrt(ux * ux + 4 * uy * uy + 1e-9)
          copies = 2
        end
        for copy = 1, copies do
          local vis, wgt, sx, sy = NS.vis, 1, bx, by
          if ph then
            local dd
            if copy == 1 then
              vis, wgt, dd = NS.visA, NS.wA, NS.shA * m
            else
              vis, wgt, dd = NS.visB, NS.wB, NS.shB * m
              sx, sy = sx + NS.ox, sy + NS.oy
            end
            sx, sy = sx - ux * dd, sy - uy * dd
          end
          local ix, iy = floor(sx), floor(sy)
          local xa, ya = ix % NT_, iy % NT_
          local r0 = ya * NT_ + 1
          if NS.lines then
            if vis > 0 then
              local gv = nG[(iy % TG) * TG + ix % TG + 1]
              if gv < vis then
                local ax, ay = sx - ix, sy - iy
                local xb, yb = xa + 1, ya + 1
                if xb == NT_ then xb = 0 end
                if yb == NT_ then yb = 0 end
                local r1 = yb * NT_ + 1
                local a, b, c, d4 = nE[r0 + xa], nE[r0 + xb], nE[r1 + xa], nE[r1 + xb]
                local e2 = a + (b - a) * ax + (c - a) * ay + (a - b - c + d4) * ax * ay
                local t2 = 0.28 + min(0.5, (vis - gv) * 1.4)
                if e2 - t2 < ev - thr then ev, thr = e2, t2 end
                if nT[r0 + xa] < NS.dark and gv < vis - 0.2 then dark = true end
              end
            end
          elseif wgt > 0 then
            -- No lines: a round spot round some cells' seeds, swelling and
            -- shrinking (and with its copy as it fades).
            local tn = nT[r0 + xa]
            if tn < NS.spotDark then
              local swell = 1 + 0.2 * cos(TAU * (t + tn * 7.3))
              if nC[r0 + xa] * NS.spotR < swell * sqrt(wgt) then dark = true end
            end
          end
        end
        if dark then cc, lv = cPatch, (lv >= BASE) and DEEP or SHADOW end
        if ev < thr then
          cc, lv = cNet, NS.line
        elseif ev < thr + NS.halo then
          cc, lv = cNet, (lv >= BASE) and LIGHT or BASE
        end
      end
      -- The flow: streaks, white water in a fast river, and the foam a
      -- fall sends down the stream.
      local lane = lf[j]
      if ph and lane then
        local ST, TT, Ds = STw, TTw, Dw
        local vv
        if riv then
          ST, TT, Ds = STr, TTr, Dr
          vv = floor((ph + tDr) % Dr) + 1
        else
          vv = floor((ph + tDw) % Dw) + 1
        end
        -- A clock a hair under 0 comes out at Ds itself: that is 0 again.
        if vv > Ds then vv = 1 end
        -- Streaks only where the water speeds up toward an edge: on calm
        -- water (and spreading from a landing) they would line up in
        -- dotted rows down the lanes.
        local dk0, dr0 = dSink[j], dSrc[j]
        local fast = (dk0 and (not dr0 or dk0 < dr0)) and (spd[j] - 1) or 0
        if sShareR > 0 and fast > 0 and not clean then
          local fx_, fy_ = LUX[j] or 0, LUY[j] or 1
          local sv = ST[(floor((x0B + wx[j]) * fy_ - (y0B + wy[j]) * fx_ + 0.5) % 64) * Ds + vv]
          local share = sShareR * min(2, fast * 2.5)
          local g = gW and gW[j]
          if g then share = share * (1 + g * 0.8) end
          if sv > 1 - share then
            cc, lv = cStreak, (sv > 1 - share * 0.3 or lv >= BASE) and ((lv >= LIGHT) and HIGH or LIGHT) or BASE
          end
        end
        -- White water: all down a river (not only where it speeds up toward
        -- an edge), more where it runs fast or into a bank; where a rod pulls
        -- the water, more of it, laid along the rod (the lanes follow it),
        -- still water too.
        local g = gW and gW[j] or 0
        if rapids > 0 and (riv or g > 0.2) then
          -- (The lane mixed with where it lies across the flow, every 3 px
          -- another: a coarse lane alone stays the same over wide stretches,
          -- and some never foamed.)
          local fx_, fy_ = LUX[j] or 0, LUY[j] or 1
          local cr = floor(((x0B + wx[j]) * fy_ - (y0B + wy[j]) * fx_) / 3)
          local wv = TT[((lc[j] + cr * 23) % 64) * Ds + vv]
          local share = riv and rapids * (0.3 + max(0, spd[j] - 1) * 0.8 + fu[j] * 1.2 + g * 1.0)
            or rapids * g * 0.8
          if wv > 1 - share then cc, lv = cTrail, (wv > 1 - share * 0.45) and FOAM or HIGH end
        end
        if g > 0.3 and gFoam > 0 and not clean then
          local fv = (riv and FKr or FKw)[lane * Ds + vv]
          local share = gFoam * (g - 0.3) * 2
          if fv > 1 - share then cc, lv = cTrail, (fv > 1 - share * 0.4) and FOAM or HIGH end
        end
        local dr = dSrc[j]
        if trail > 0 and dr and dr < trailLen and not clean then
          local tv = TT[lc[j] * Ds + vv]
          local f = 1 - dr / trailLen
          local share = trail * 0.07 * f * sqrt(f)
          if tv > 1 - share then cc, lv = cTrail, (tv > 1 - share * 0.4) and FOAM or HIGH end
        end
      end
      -- The fall upside down in the water under it.
      local r0 = wry[j]
      if r0 >= 0 and reflLen > 0 then
        local dy = wy[j] - r0
        local reach
        if clean then
          -- (Every other row, cut off smoothly: no specks.)
          reach = dy <= reflLen * (0.75 + 0.25 * nd) and dy % 2 == 0
        else
          reach = dy <= reflLen and pg[j] > dy / reflLen * 0.9
        end
        if reach then
          local sy = r0 - floor(dy * 1.4 + 0.5) - 2
          local sx = wx[j] + floor(sin(t2 + dy * 0.9) * 1.2 + 0.5)
          if sy >= 0 and sx >= 0 and sx < w then
            local sk = sy * w + sx + 1
            if kind[sk] == 1 then
              local sl = LVB[byte(buf[sk])] or 0
              if sl >= HIGH then cc, lv = cWater, LIGHT
              elseif sl == LIGHT and lv < BASE then cc, lv = cWater, BASE end
            end
          end
        end
      end
      -- Rings from the landing (wobbling a little, not drawn with a ruler).
      if K > 0 and e < Rmax + churnR + 3 and clean then
        -- Each ring the one pixel line round where it has reached, fading
        -- out in long arcs as it spreads.
        local ew = e + nd * 1.6
        for i = 0, K - 1 do
          local a = (tr + i / K) % 1
          local Rr = churnR + 1 + a * Rmax
          if ew < Rr and ew > Rr - 3 and CK.across(j, CK.ring, Rr) then
            if a < 0.3 or rpZ[j] * 0.5 + 0.5 > a * 1.25 - 0.3 then
              cc, lv = cRing, (a < 0.3) and HIGH or min(HIGH, max(LIGHT, lv + 1))
            end
            break
          end
        end
      elseif K > 0 and e < Rmax + churnR + 3 then
        local ew = e + nd * 1.6
        for i = 0, K - 1 do
          local a = (tr + i / K) % 1
          local Rr = churnR + 1 + a * Rmax
          local dd = ew - Rr
          if dd > -0.6 and dd < 0.6 then
            if a < 0.25 or pg[j] > a * 1.05 - 0.2 then
              cc, lv = cRing, (a < 0.3) and HIGH or LIGHT
            end
            break
          elseif dd > -1.8 and dd <= -0.6 and a < 0.55 and lv <= BASE and lv > SHADOW and pg[j] > a * 1.3 then
            lv = lv - 1
          end
        end
      end
      -- Wave lines rolling in to still water's shores, growing as they
      -- come.
      if waves > 0 and not riv and dT > fwMax and dT < NEAR_D then
        local ph0 = t + rpZ[j] * 0.35
        for r = 0, waves - 1 do
          local wph = (ph0 + r / waves) % 1
          local pos = fwMax + 0.8 + spanW * (1 - wph)
          local hit
          if clean then
            hit = dT < pos and dT > pos - 3 and CK.across(j, CK.dT, pos)
              and rpZ[j] * 0.5 + 0.5 < min(1, wph * 2.2) * 0.8
          else
            hit = abs(dT - pos) < 0.5 and rgZ[j] * 0.5 + 0.5 < min(1, wph * 2.2) * 0.62
          end
          if hit then
            cc, lv = cWave, (wph > 0.55) and HIGH or LIGHT
            break
          end
        end
      end
      -- The shore line and lapping foam (a river's banks have their own).
      local fo = riv and foR or foW
      if clean then
        -- The shore's line, unbroken (where the tide has not climbed past
        -- it); a second line lapping out and back; two px thick where the
        -- flow runs into the bank.
        if fo >= 1 then
          if wshore[j] and dT - d < 0.5 then
            cc, lv = cShore, (fo >= 6) and FOAM or HIGH
          elseif fo >= 2 and dT < CK.lap(j) and dT - d < 0.5 and CK.across(j, CK.lapOff, 0) then
            cc, lv = cShore, HIGH
          elseif fo >= 2 and d < 1.6 and fu[j] * flowFoam > 0.7 then
            cc, lv = cShore, HIGH
          end
        end
      elseif fo >= 1 and dT < 0.6 then
        local v = rc[j] * ct + rs[j] * st
        if v > -0.3 then cc, lv = cShore, (v > 0.45) and FOAM or HIGH end
      end
      if fo >= 2 and dT < NEAR_D and not clean then
        local lp = 0.5 + 0.5 * (fc[j] * ct - fsn[j] * st)
        local fw = (riv and fBaseR or fBaseW) + (riv and fAmpR or fAmpW) * lp + flowFoam * fu[j]
        local dd = dT + fnz[j] * (riv and fRoughR or fRoughW)
        if dd < fw then
          cc, lv = cShore, (fw - dd > 1.3 and ho[j] > 0.3) and HIGH or FOAM
        elseif dd < fw + 1 and lv < HIGH then
          cc, lv = cShore, HIGH
        end
      end
      -- Just above an edge: the mouth's band.
      local ri = mSj[j]
      if ri then
        local ml = mLevel(mRuns[ri], mSe[j], mBob[ri], false)
        if ml then cc, lv = cLip, ml end
      end
      local under = (cc == cWater or cc == cDeep) and 0 or 14
      buf[k] = cc[under + lv]
      if j % 1024 == 0 then step() end
    end

    ------------------------------------------------------------------ tide
    -- Still water past its mask: the ground the tide covers now is water
    -- with the shore line and lapping foam at its edge; the ground it has
    -- just left stays wet a while.
    if tideOn then
      local TBidx, TBs, bph = TB.idx, TB.s, F.tideBPh
      local trc, trs, tfc, tfs, tfn, tho = TB.rc, TB.rs, TB.fc, TB.fs, TB.fn, TB.ho
      local wetOn = (p.tideWet or 0) > 0
      local wetLen = (p.tideWet or 0) / 10 * 0.9
      local acos = math.acos
      local cWet = C[E_WET]
      local iOf = TB.iOf
      -- (Clean: whether ground pixel kk is under the tide now.)
      local function covered(kk)
        local i2 = iOf[kk]
        if not i2 then return false end
        return TBs[i2] + amp * (0.5 - 0.5 * cos(TAU * ((cyct + bph[i2]) % 1))) > 0
      end
      for i = 1, TB.n do
        local k = TBidx[i]
        local s = TBs[i]
        local u = (cyct + bph[i]) % 1
        local dd0 = s + amp * (0.5 - 0.5 * cos(TAU * u))
        if dd0 > 0 and clean then
          -- Shallow water, its edge the shore's unbroken line.
          local cc, lv = cWater, LIGHT
          if foW >= 1 then
            local x = (k - 1) % w
            local edge = false
            for q = 1, 4 do
              local kk
              if q == 1 then kk = (x < w - 1) and k + 1 or nil elseif q == 2 then kk = (x > 0) and k - 1 or nil
              elseif q == 3 then kk = (k + w <= B.N) and k + w or nil else kk = (k - w >= 1) and k - w or nil end
              if kk and kind[kk] == 0 and not covered(kk) then edge = true break end
            end
            if edge then cc, lv = cShore, (foW >= 6) and FOAM or HIGH end
          end
          buf[k] = cc[((cc == cWater) and 0 or 14) + lv]
          onGround(k)
        elseif dd0 > 0 then
          local cc, lv = cWater, BASE
          if foW >= 1 and dd0 < 0.6 then
            local v = trc[i] * ct + trs[i] * st
            if v > -0.3 then cc, lv = cShore, (v > 0.45) and FOAM or HIGH end
          end
          if foW >= 2 then
            local lp = 0.5 + 0.5 * (tfc[i] * ct - tfs[i] * st)
            local fw = fBaseW + fAmpW * lp
            local dd = dd0 + tfn[i] * fRoughW
            if dd < fw then
              cc, lv = cShore, (fw - dd > 1.3 and tho[i] > 0.3) and HIGH or FOAM
            elseif dd < fw + 1 and lv < HIGH then
              cc, lv = cShore, HIGH
            end
          end
          buf[k] = cc[((cc == cWater) and 0 or 14) + lv]
          onGround(k)
        elseif wetOn then
          -- Under water while the phase is between u1 and 1 - u1; wet for
          -- a while after.
          local c = -s / amp
          if c < 1 then
            local u1 = acos(1 - 2 * c) / TAU
            if (u - 1 + u1) % 1 < wetLen then
              buf[k] = cWet[SHADOW]
              onGround(k)
            end
          end
        end
        if i % 1024 == 0 then step() end
      end
    end
  end

  ------------------------------------------------------------- sparkles
  local Pt = F.parts
  local cSpark = C[E_SPARK]
  local cleanS = p.clean == true and F.clean ~= nil
  -- (Clean glints grow a little with the Size: 4 px across at 1x, 8 at 3x.)
  local glintW = 2 * math.max(1, floor(sqrt(cleanS and F.clean.f or 1) + 0.5))
  local function spark(k, lv)
    local u = kind[k]
    if u == 0 then return end
    local b = byte(buf[k])
    if b == 0 then return end
    if LVB[b] < lv then buf[k] = cSpark[u * 7 + lv] end
  end
  local N = B.N
  for _, g in ipairs(Pt.glints) do
    local ph = (t + g.phase) % 1
    if ph < g.life then
      local s = ph / g.life
      local k = g.k
      if g.fall then
        spark(k, (s < 0.35 or s > 0.65) and HIGH or FOAM)
        if s >= 0.35 and s <= 0.65 then
          if k - w >= 1 then spark(k - w, HIGH) end
          if k + w <= N then spark(k + w, HIGH) end
        end
      elseif cleanS then
        -- A short dash across: two px as it comes and goes, four and
        -- brighter at its height (one colour each time, so no pixel of it
        -- stands alone); all of it on the water or none.
        local x = (k - 1) % w
        local wide = s >= 0.25 and s < 0.75
        local half = wide and glintW or (glintW // 2)
        local xa, xb = x - half + 1, x + half
        local ok = xa >= 0 and xb < w
        if ok then
          for xx = xa, xb do
            if kind[k - x + xx] ~= 2 then ok = false break end
          end
        end
        if ok then
          for xx = xa, xb do spark(k - x + xx, wide and FOAM or HIGH) end
        end
      elseif s < 0.3 or s > 0.7 then
        spark(k, HIGH)
      else
        spark(k, FOAM)
        local x = (k - 1) % w
        if x > 0 then spark(k - 1, HIGH) end
        if x < w - 1 then spark(k + 1, HIGH) end
        if g.plus then
          if k - w >= 1 then spark(k - w, HIGH) end
          if k + w <= N then spark(k + w, HIGH) end
        end
      end
    end
  end

  ------------------------------------------------------------------ foam
  -- One cloud of bubbles: each pixel takes the bubble it lies deepest in
  -- (px from its edge), so the cloud's outside gets a rim and where two
  -- bubbles meet a seam shows: round clumps, lit on top, shaded under.
  local h = B.h
  local bubbles = Pt.bubbles
  local lightX = (p.light == "right") and -0.45 or 0.45
  if #bubbles > 0 then
    local dep, dep2, cls, list = {}, {}, {}, {}
    local nl = 0
    for _, bb in ipairs(bubbles) do
      local a = (tc + bb.ph) % 1
      local sa = sin(PI * a)
      local r = bb.rmax * sqrt(sa)
      if r >= 0.55 then
        local cx = bb.x0 + bb.vx * a
        local cy = bb.y0 - bb.rise * sa + bb.drop * a
        local rimOn = r >= 1.4
        local ya, yb = max(0, floor(cy - r)), min(h - 1, floor(cy + r))
        local xa, xb = max(0, floor(cx - r)), min(w - 1, floor(cx + r))
        for yy = ya, yb do
          local dy = yy + 0.5 - cy
          local row = yy * w + 1
          for xx = xa, xb do
            local dx = xx + 0.5 - cx
            local d = sqrt(dx * dx + dy * dy)
            if d < r then
              local c = r - d
              local k = row + xx
              local old = dep[k]
              if not old then
                nl = nl + 1
                list[nl] = k
                old = 0
                dep2[k] = 0
              end
              if c > old then
                dep2[k] = old
                dep[k] = c
                if rimOn and c < 0.95 then cls[k] = LIGHT
                elseif (dy * 0.8 + dx * lightX) > r * 0.26 then cls[k] = HIGH
                else cls[k] = FOAM end
              elseif c > dep2[k] then
                dep2[k] = c
              end
            end
          end
        end
      end
    end
    local cFoam = C[E_FOAM]
    for i = 1, nl do
      local k = list[i]
      local u = kind[k]
      if u == 0 then onGround(k) end
      local lv = cls[k]
      -- A seam between two clumps: one step darker.
      if lv > LIGHT and dep2[k] > 1.1 and dep[k] - dep2[k] < 0.75 then lv = lv - 1 end
      buf[k] = cFoam[u * 7 + lv]
    end
    step()
  end

  ----------------------------------------------------------------- spray
  local drops, drips = Pt.drops, Pt.drips
  if #drops > 0 or #drips > 0 then
    local cSpray = C[E_SPRAY]
    local function dot(x, y, lv)
      local xi, yi = floor(x), floor(y)
      if xi < 0 or yi < 0 or xi >= w or yi >= h then return end
      local k = yi * w + xi + 1
      local u = kind[k]
      if lv < FOAM then
        local b = byte(buf[k])
        if b ~= 0 and LVB[b] >= lv then return end
      end
      if u == 0 then onGround(k) end
      buf[k] = cSpray[u * 7 + lv]
    end
    for _, d in ipairs(drops) do
      local a = (tc + d.ph) % 1
      if a < d.life then
        local s = a / d.life
        local x = d.x0 + d.hx * s
        local y = d.y0 - 4 * d.hy * s * (1 - s)
        local s2 = s - 0.09
        if s2 > 0 then
          dot(d.x0 + d.hx * s2, d.y0 - 4 * d.hy * s2 * (1 - s2), HIGH)
        end
        dot(x, y, FOAM)
      end
    end
    for _, d in ipairs(drips) do
      local a = (tc + d.ph) % 1
      if a < d.life then
        local s = a / d.life
        local y = d.y0 + d.len * (0.3 * s + 0.7 * s * s)
        local x = d.x0 + d.dx * s
        dot(x, y - 1, HIGH)
        dot(x, y, (s < 0.7) and FOAM or HIGH)
      end
    end
  end

  ------------------------------------------------------------------ mist
  -- Puffs: where thick, the water under them turns lighter (by palette,
  -- so its lines still show) and the ground gets a see-through haze;
  -- thin edges are dithered.
  local puffs = Pt.puffs
  if #puffs > 0 then
    local mc = max(1, floor((p.frames or 16) / 24 + 0.5))
    local tm = t * mc
    local cov, list = {}, {}
    local nl = 0
    for _, pf in ipairs(puffs) do
      local a = (tm + pf.ph) % 1
      local strength = sin(PI * a) * 0.75
      local r = pf.r0 + pf.rg * a
      local cx = pf.x0 + pf.drift * a
      local cy = pf.y0 - pf.rise * a
      local ya, yb = max(0, floor(cy - r)), min(h - 1, floor(cy + r))
      local xa, xb = max(0, floor(cx - r)), min(w - 1, floor(cx + r))
      for yy = ya, yb do
        local dy = (yy + 0.5 - cy) * 1.15
        local row = yy * w + 1
        for xx = xa, xb do
          local dx = xx + 0.5 - cx
          local d = sqrt(dx * dx + dy * dy)
          if d < r then
            local c = (1 - d / r) * strength
            local k = row + xx
            local old = cov[k]
            if not old then
              nl = nl + 1
              list[nl] = k
              cov[k] = c
            else
              cov[k] = old + c
            end
          end
        end
      end
    end
    local cMist = C[E_MIST]
    local seed = p.seed or 1
    local x0, y0 = B.x0, B.y0
    local perlin = Noise.perlin
    for i = 1, nl do
      local k = list[i]
      local x, y = (k - 1) % w + x0, (k - 1) // w + y0
      -- Fluffy, not round: a noise over the sprite roughens the edge.
      local c = cov[k] + perlin(x / 3.2, y / 3.2, seed + 91) * 0.32
      local inc = 0
      if c > 0.95 then inc = 2
      elseif c > 0.52 then inc = 1
      elseif c > 0.3 and (x + y) % 2 == 0 then inc = 1 end
      if inc > 0 then
        local b = byte(buf[k])
        if b == 0 then
          -- Over the ground: thick mist at its opacity, thin at half.
          onGround(k)
          buf[k] = cMist[((inc == 2) and 0 or 7) + FOAM]
        else
          local lv, el, u = LVB[b], ELB[b], UNB[b]
          lv = lv + inc
          if lv > FOAM then lv = FOAM end
          if el == E_MIST then lv = FOAM end
          buf[k] = C[el][u * 7 + lv]
        end
      end
    end
  end

  -- Clean: no lone pixel left on the water, where two marks crossed or a
  -- bubble's edge, a drop or the mist's fringe fell.
  if p.clean == true and F.clean ~= nil then Clean.despeckle(B, buf, LVB, ELB, CLEAN_WATER) end

  return table.concat(buf)
end

-- Frame i (1 .. n) of the loop.
function Scape.frame(F, p, i, step)
  local n = p.frames or 16
  return Scape.levels(F, p, ((i - 1) % n) / n, step)
end

-- The box written to the sprite (the region's).
function Scape.box(F)
  local B = F.base
  return { x0 = B.x0, y0 = B.y0, w = B.w, h = B.h }
end

return Scape
