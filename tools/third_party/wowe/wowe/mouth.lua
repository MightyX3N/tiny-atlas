-- The mouth: where the water goes over a fall's edge, drawn as a strip
-- laid over the edge and bent down with it: one band across the edge, made of columns. In each column,
-- from the river down to the curtain:
--
--   teeth    blue streaks reaching up into the river (two blues)
--   core     white water right over the edge
--   fringe   streaks hanging down from it into the curtain, each fading
--            from cyan to light blue to the water's blue (some start
--            light blue), now and then a dark slit in one
--
-- The band is as big as its fall is wide (the settings are px on a fall 30
-- px wide; a wider fall gets a bigger mouth, up to three times, the way a
-- drawn strip is laid across the whole edge).
--
-- Every column has lengths of its own (Ragged: from smooth along the edge
-- to wholly uneven, column by column), and the whole band of a column
-- bobs up and down (Wave), the bobbing running along the edge like a wave,
-- a whole number of times a loop, so the loop closes. Where the river
-- overlaps the fall's top (the mouth painted over it, or a lip rod), the
-- deeper the overlap the more of the white core lies on it: a long curl
-- over the edge, seen from the side.
--
-- A fall coming over a bare edge (no water above it) gets the band too,
-- without teeth, its core as tall as the Fall page's Top says.

local G = ... or _WOWE

local Noise = G.require("noise")

local Mouth = {}

local floor, max, min, sin = math.floor, math.max, math.min, math.sin
local TAU = math.pi * 2

local SHADOW, DEEP, BASE, LIGHT, HIGH, FOAM = 1, 2, 3, 4, 5, 6

-- What the band depends on (with the masks).
function Mouth.key(p)
  return table.concat({ p.seed or 1, p.mouthFoam or 0, p.mouthFringe or 0, p.mouthTeeth or 0,
    p.mouthRagged or 0, p.top or 0 }, ":")
end

-- Every lip run (a fall starting at an edge) gets its column's band;
-- every fall pixel knows its run, and the surface pixels above a fed run
-- (up the column, as far as the band can reach) know theirs and how far
-- above the edge they are.
function Mouth.prepare(B, p)
  local M = { runs = {}, rid = {}, sj = {}, se = {}, key = Mouth.key(p) }
  local n = B.n
  if n == 0 then return M end
  local seed = p.seed or 1
  local hash, perlin = Noise.hash, Noise.perlin
  local foamM, fringeM, teethM = p.mouthFoam or 0, p.mouthFringe or 0, p.mouthTeeth or 0
  local g = (p.mouthRagged or 0) / 10
  local topF = (p.top or 0) * 0.8
  local W = B.W
  local w, kind = B.w, B.kind
  local jOf = W.jOf or {}
  local isLip = W.lip or {}
  local fx, fy, fs, flip, fed = B.fx, B.fy, B.fs, B.flip, B.fed
  local fdl, fdr = B.fdl, B.fdr
  local x0, y0 = B.x0, B.y0
  -- Along the edge a smooth noise, a column a hash: Ragged mixes them.
  local function mix(X, k)
    local nz = 0.5 + 0.5 * perlin((X + 0.5) / 6, k + 0.5, seed + 811)
    return nz * (1 - g) + hash(X, k, seed + 812) * g
  end
  local runs, rid = M.runs, M.rid
  local byTop = {}
  for j = 1, n do
    if flip[j] and fs[j] == 0 then
      local x, yT = fx[j], fy[j]
      local X = x0 + x
      -- As big as the fall is wide here.
      local sc = min(3, max(0.7, min(150, fdl[j] + fdr[j] + 1) / 30))
      local F = (fed[j] and foamM or topF) * sc
      if F > 0 then
        -- How far the overlap above reaches (rows of mouth).
        local Lh = 0
        if fed[j] then
          local yy = yT - 1
          while yy >= 0 do
            local q = jOf[yy * w + x + 1]
            if not q or not isLip[q] then break end
            Lh = Lh + 1
            yy = yy - 1
          end
        end
        local core = max(1, floor(F * (0.7 + 0.6 * mix(X, 1)) + 0.5))
        local up = (Lh > 0) and min(Lh, floor(Lh * 0.6 + 0.99)) or floor(core * 0.3)
        local down = max(1, core - up)
        -- The streak under the core: cyan, light blue, the water's blue.
        local fringe = floor(fringeM * sc * (0.35 + 0.9 * mix(X, 3) ^ 1.3) + 0.5)
        local f1 = floor(fringe * (0.3 + 0.3 * hash(X, 11, seed + 820)) + 0.5)
        if hash(X, 12, seed + 821) < 0.3 then f1 = 0 end
        local f2 = floor((fringe - f1) * 0.55 + 0.5)
        local r = {
          x = x, top = yT, fed = fed[j], Lh = Lh,
          up = up, down = down,
          teeth = fed[j] and floor(teethM * sc * (0.3 + 0.9 * mix(X, 2)) + 0.5) or 0,
          fringe = fringe, f1 = f1, f2 = f1 + f2,
          teethLv = (hash(X, 8, seed + 813) < 0.55) and LIGHT or BASE,
          ph = TAU * (0.6 * perlin((X + 0.5) / 7, 9.5, seed + 814) + g * hash(X, 9, seed + 815)),
          X = X,
        }
        -- Now and then a dark slit between the streaks.
        if fringe >= 4 and hash(X, 5, seed + 816) < 0.2 + g * 0.15 then
          local a = 1 + floor(hash(X, 6, seed + 817) * (fringe - 3))
          r.gapA, r.gapB = a, a + ((hash(X, 7, seed + 818) > 0.6) and 3 or 2)
        end
        runs[#runs + 1] = r
        byTop[yT * w + x] = #runs
      end
    end
  end
  -- Every fall pixel's run (its pixels come one after another, top down).
  local cur = nil
  for j = 1, n do
    if fs[j] == 0 or j == 1 or fx[j] ~= fx[j - 1] or fy[j] ~= fy[j - 1] + 1 then
      cur = flip[j] and byTop[fy[j] * w + fx[j]] or nil
    end
    rid[j] = cur
  end
  -- The water above a fed run, up the column: how far above the edge.
  local A = (p.mouthWave or 0)
  for id, r in ipairs(runs) do
    if r.fed then
      local reach = r.up + r.teeth + max(4, A) + 1
      local yy = r.top - 1
      local steps = 0
      while yy >= 0 and steps < reach do
        local k = yy * w + r.x + 1
        if kind[k] ~= 2 then break end
        steps = steps + 1
        local q = jOf[k]
        if q and not M.sj[q] then
          M.sj[q], M.se[q] = id, -steps
        end
        yy = yy - 1
      end
    end
  end
  return M
end

-- How far each run's band bobs at loop phase t (px, whole): Wave px at
-- most, twice a loop, the bobbing running along the edge.
function Mouth.bob(M, p, t)
  local A = p.mouthWave or 0
  local b = {}
  for id, r in ipairs(M.runs) do
    b[id] = (A > 0) and floor(A * sin(TAU * 2 * t - r.X * TAU / 9 + r.ph) + 0.5) or 0
  end
  return b
end

-- The band's colour at e px below the edge (above it: negative) for run
-- r bobbing bb px, or nil where the band is not. `fall`: on the fall (the
-- edge's own column: never the river's texture above the band there).
function Mouth.level(r, e, bb, fall)
  local ee = e - bb
  local up = r.up
  if fall and ee < -up then return FOAM end
  if ee < -(up + r.teeth) then return nil end
  if ee < -up then return r.teethLv end
  local down = r.down
  if ee < down then return FOAM end
  local f = ee - down
  if f < r.fringe then
    if r.gapA and f >= r.gapA and f < r.gapB then return DEEP end
    if f < r.f1 then return HIGH end
    if f < r.f2 then return LIGHT end
    return BASE
  end
  return nil
end

return Mouth
