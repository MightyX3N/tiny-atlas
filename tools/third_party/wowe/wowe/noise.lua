-- Small, fast noise: an integer hash and gradient noise, plain or wrapping
-- round in y (for textures that slide along the water and come back to
-- where they started at the end of the loop).

local Noise = {}

local floor, sqrt = math.floor, math.sqrt

-- Integer hash of a lattice point, 0 <= h < 1.
local function hash(ix, iy, seed)
  local h = ix * 374761393 + iy * 668265263 + seed * 1440662683
  h = (h ~ (h >> 13)) * 1274126177
  h = h ~ (h >> 16)
  return (h & 0xffffff) / 16777216
end
Noise.hash = hash

-- Sixteen gradient directions.
local GX, GY = {}, {}
for i = 0, 15 do
  local a = i * math.pi / 8
  GX[i], GY[i] = math.cos(a), math.sin(a)
end

local function grad(cx, cy, s, dx, dy)
  local h = cx * 374761393 + cy * 668265263 + s
  h = (h ~ (h >> 13)) * 1274126177
  h = ((h ~ (h >> 16)) >> 4) & 15
  return GX[h] * dx + GY[h] * dy
end

-- Gradient noise, roughly -1 .. 1.
function Noise.perlin(x, y, seed)
  local ix, iy = floor(x), floor(y)
  local fx, fy = x - ix, y - iy
  local u = fx * fx * fx * (fx * (fx * 6 - 15) + 10)
  local v = fy * fy * fy * (fy * (fy * 6 - 15) + 10)
  local s = seed * 1440662683
  local a = grad(ix, iy, s, fx, fy)
  local b = grad(ix + 1, iy, s, fx - 1, fy)
  local c = grad(ix, iy + 1, s, fx, fy - 1)
  local d = grad(ix + 1, iy + 1, s, fx - 1, fy - 1)
  local ab = a + (b - a) * u
  return (ab + (c + (d - c) * u - ab) * v) * 1.41
end

-- The same, wrapping round every `period` (a whole number) in y: the
-- noise at y and at y + period is the same.
function Noise.perlinWrap(x, y, seed, period)
  local ix, iy = floor(x), floor(y)
  local fx, fy = x - ix, y - iy
  local u = fx * fx * fx * (fx * (fx * 6 - 15) + 10)
  local v = fy * fy * fy * (fy * (fy * 6 - 15) + 10)
  local s = seed * 1440662683
  local y0, y1 = iy % period, (iy + 1) % period
  local a = grad(ix, y0, s, fx, fy)
  local b = grad(ix + 1, y0, s, fx - 1, fy)
  local c = grad(ix, y1, s, fx, fy - 1)
  local d = grad(ix + 1, y1, s, fx - 1, fy - 1)
  local ab = a + (b - a) * u
  return (ab + (c + (d - c) * u - ab) * v) * 1.41
end

-- The same, wrapping round every `px` in x and `py` in y (whole numbers):
-- a tile that repeats without a seam.
function Noise.perlinTile(x, y, seed, px, py)
  local ix, iy = floor(x), floor(y)
  local fx, fy = x - ix, y - iy
  local u = fx * fx * fx * (fx * (fx * 6 - 15) + 10)
  local v = fy * fy * fy * (fy * (fy * 6 - 15) + 10)
  local s = seed * 1440662683
  local x0, x1 = ix % px, (ix + 1) % px
  local y0, y1 = iy % py, (iy + 1) % py
  local a = grad(x0, y0, s, fx, fy)
  local b = grad(x1, y0, s, fx - 1, fy)
  local c = grad(x0, y1, s, fx, fy - 1)
  local d = grad(x1, y1, s, fx - 1, fy - 1)
  local ab = a + (b - a) * u
  return (ab + (c + (d - c) * u - ab) * v) * 1.41
end

-- Smooth noise (-1 .. 1, features about `scale` px) on a T x T tile that
-- repeats without a seam.
function Noise.tileField(T, scale, seed, step)
  local n = math.max(1, floor(T / scale + 0.5))
  local inv = n / T
  local out = {}
  for y = 0, T - 1 do
    local fy = (y + 0.5) * inv
    local row = y * T + 1
    for x = 0, T - 1 do
      out[row + x] = Noise.perlinTile((x + 0.5) * inv, fy, seed, n, n)
    end
    if step and y % 16 == 15 then step() end
  end
  return out
end

-- A net of cell walls on a tile of n x n cells of `cell` px (T = n * cell
-- px a side) that repeats without a seam: the distance (px) to the nearest
-- wall at every pixel (capped at `cap`), a number 0 .. 1 for the cell it
-- is in and the distance to the cell's own seed (for round spots). The
-- walls wave (bent by `bend` px of smooth noise) instead of running
-- straight.
function Noise.tileNet(cell, n, seed, bend, cap, step)
  local T = cell * n
  local bx = Noise.tileField(T, cell * 0.9, seed + 203, step)
  local by = Noise.tileField(T, cell * 0.9, seed + 205, step)
  local SU, SV, TONE = {}, {}, {}
  for j = 0, n - 1 do
    for i = 0, n - 1 do
      local k = j * n + i + 1
      SU[k] = cell * (i + 0.15 + 0.7 * hash(i, j, seed))
      SV[k] = cell * (j + 0.15 + 0.7 * hash(i, j, seed + 7))
      TONE[k] = hash(i, j, seed + 13)
    end
  end
  local huge = math.huge
  local out, tone, centre = {}, {}, {}
  for py = 0, T - 1 do
    local row = py * T
    for px = 0, T - 1 do
      local q = row + px + 1
      local x, y = px + 0.5 + bx[q] * bend, py + 0.5 + by[q] * bend
      local ci, cj = floor(x / cell), floor(y / cell)
      -- The three nearest seeds (round the tile's edges, their copies),
      -- looked for in the cells round this one: seeds keep 0.15 of a cell
      -- off their cell's sides, so the nearest ones are there.
      local b1, b2, b3 = huge, huge, huge
      local u1, v1, u2, v2, u3, v3, k1 = 0, 0, 0, 0, 0, 0, 1
      for j = cj - 1, cj + 1 do
        local wj = j % n
        local oy = (j - wj) * cell
        local base = wj * n + 1
        for i = ci - 1, ci + 1 do
          local wi = i % n
          local k = base + wi
          local su, sv = SU[k] + (i - wi) * cell, SV[k] + oy
          local du, dv = su - x, sv - y
          local d2 = du * du + dv * dv
          if d2 < b3 then
            if d2 < b2 then
              b3, u3, v3 = b2, u2, v2
              if d2 < b1 then
                b2, u2, v2 = b1, u1, v1
                b1, u1, v1, k1 = d2, su, sv, k
              else
                b2, u2, v2 = d2, su, sv
              end
            else
              b3, u3, v3 = d2, su, sv
            end
          end
        end
      end
      -- Wall to the second seed, and to the third.
      local au, av = u2 - u1, v2 - v1
      local e = (b2 - b1) / (2 * sqrt(au * au + av * av))
      local cu, cv = u3 - u1, v3 - v1
      local e3 = (b3 - b1) / (2 * sqrt(cu * cu + cv * cv))
      if e3 < e then e = e3 end
      if e > cap then e = cap end
      out[q] = e
      tone[q] = TONE[k1]
      centre[q] = sqrt(b1)
    end
    if step then step() end
  end
  return out, tone, T, centre
end

-- A few octaves of plain noise, roughly -1 .. 1.
function Noise.fbm(x, y, octaves, seed)
  local sum, amp, norm = 0, 1, 0
  for o = 1, octaves do
    sum = sum + Noise.perlin(x, y, seed + o * 31) * amp
    norm = norm + amp
    amp = amp * 0.5
    x, y = x * 2.03, y * 2.03
  end
  return sum / norm
end

-- Smooth noise (-1 .. 1, one octave, features `scale` px) over a window of
-- w x h pixels whose top-left pixel is at world (ox, oy): worked out every
-- `stride` px and filled in between, as it barely changes from one pixel
-- to the next.
function Noise.field(ox, oy, w, h, scale, seed, stride, step)
  stride = stride or 2
  local gw, gh = floor((w - 1) / stride) + 2, floor((h - 1) / stride) + 2
  local grid = {}
  local inv = 1 / scale
  for gy = 0, gh - 1 do
    local y = (oy + gy * stride + 0.5) * inv
    for gx = 0, gw - 1 do
      grid[gy * gw + gx + 1] = Noise.perlin((ox + gx * stride + 0.5) * inv, y, seed)
    end
  end
  local out = {}
  local fs = 1 / stride
  for py = 0, h - 1 do
    local gy = floor(py / stride)
    local ay = (py - gy * stride) * fs
    local r0, r1 = gy * gw + 1, (gy + 1) * gw + 1
    local row = py * w + 1
    for px = 0, w - 1 do
      local gx = floor(px / stride)
      local ax = (px - gx * stride) * fs
      local a, b = grid[r0 + gx], grid[r0 + gx + 1]
      local c, d = grid[r1 + gx], grid[r1 + gx + 1]
      out[row + px] = a + (b - a) * ax + (c - a) * ay + (a - b - c + d) * ax * ay
    end
    if step and py % 8 == 7 then step() end
  end
  return out
end

-- Distance (px) to the nearest cell wall at every pixel of a window, and
-- a number 0 .. 1 for the cell each pixel is in.
-- The cells: a jittered grid turned to the direction (ux, uy), su px long
-- along it and sv px across. Window: w x h pixels, its top-left pixel at
-- world (ox, oy). Distances are capped at `cap`. `bx`, `by` (optional, one
-- value per pixel of the window) bend the walls so they wave instead of
-- running straight. `step` is called once per row so a long job can pause.
--
-- The walls looked at are those between the nearest seed and the next two
-- nearest (exact enough: a pixel's nearest wall is almost always one of
-- them).
function Noise.cellWalls(ox, oy, w, h, ux, uy, su, sv, seed, cap, step, bx, by, bend)
  cap = cap or 4
  bend = bend or 0
  -- The lattice range that covers the (bent) window, with room around it.
  local U0, U1, V0, V1 = math.huge, -math.huge, math.huge, -math.huge
  local e0x, e0y, e1x, e1y = ox - bend, oy - bend, ox + w + bend, oy + h + bend
  for _, c in ipairs({ { e0x, e0y }, { e1x, e0y }, { e0x, e1y }, { e1x, e1y } }) do
    local U = c[1] * ux + c[2] * uy
    local V = -c[1] * uy + c[2] * ux
    if U < U0 then U0 = U end
    if U > U1 then U1 = U end
    if V < V0 then V0 = V end
    if V > V1 then V1 = V end
  end
  local rv = (su / sv > 1.8) and 3 or 2
  local ri = (sv / su > 1.8) and 2 or 1
  local i0, i1 = floor(U0 / su) - ri - 1, floor(U1 / su) + ri + 1
  local j0, j1 = floor(V0 / sv) - rv - 1, floor(V1 / sv) + rv + 1
  local ni = i1 - i0 + 1
  local SU, SV, TONE = {}, {}, {}
  for j = j0, j1 do
    for i = i0, i1 do
      local k = (j - j0) * ni + (i - i0) + 1
      SU[k] = su * (i + 0.15 + 0.7 * hash(i, j, seed))
      SV[k] = sv * (j + 0.15 + 0.7 * hash(i, j, seed + 7))
      TONE[k] = hash(i, j, seed + 13)
    end
  end
  local huge = math.huge
  local out, tone = {}, {}
  for py = 0, h - 1 do
    local row = py * w
    local y0 = oy + py + 0.5
    for px = 0, w - 1 do
      local q = row + px + 1
      local x, y = ox + px + 0.5, y0
      if bx then x, y = x + bx[q], y + by[q] end
      local U = x * ux + y * uy
      local V = -x * uy + y * ux
      local ci, cj = floor(U / su), floor(V / sv)
      -- The three nearest seeds.
      local b1, b2, b3, k1, k2, k3 = huge, huge, huge, 1, 1, 1
      for j = cj - rv, cj + rv do
        local base = (j - j0) * ni - i0 + 1
        for i = ci - ri, ci + ri do
          local k = base + i
          local du, dv = SU[k] - U, SV[k] - V
          local d2 = du * du + dv * dv
          if d2 < b3 then
            if d2 < b2 then
              b3, k3 = b2, k2
              if d2 < b1 then
                b2, k2 = b1, k1
                b1, k1 = d2, k
              else
                b2, k2 = d2, k
              end
            else
              b3, k3 = d2, k
            end
          end
        end
      end
      -- Wall to the second seed, and to the third.
      local au, av = SU[k1], SV[k1]
      local bu, bv = SU[k2] - au, SV[k2] - av
      local e = (b2 - b1) / (2 * sqrt(bu * bu + bv * bv))
      local gap3 = b3 - b1
      if gap3 < 2 * e * (su + sv) * 2 then
        local cu, cv = SU[k3] - au, SV[k3] - av
        local e3 = gap3 / (2 * sqrt(cu * cu + cv * cv))
        if e3 < e then e = e3 end
      end
      if e > cap then e = cap end
      out[q] = e
      tone[q] = TONE[k1]
    end
    if step then step() end
  end
  return out, tone
end

-- Spreads values evenly over 0 .. 1, keeping their order (a value of v
-- then has about v of the others below it), so a threshold reads as a
-- share of the pixels. In place; returns the list.
function Noise.even(a)
  local n = #a
  if n == 0 then return a end
  local lo, hi = math.huge, -math.huge
  for i = 1, n do
    local v = a[i]
    if v < lo then lo = v end
    if v > hi then hi = v end
  end
  if hi <= lo then
    for i = 1, n do a[i] = 0.5 end
    return a
  end
  local NB = 512
  local s = NB / (hi - lo)
  local hist = {}
  for b = 0, NB do hist[b] = 0 end
  for i = 1, n do
    local b = floor((a[i] - lo) * s)
    hist[b] = hist[b] + 1
  end
  local cdf, acc = {}, 0
  for b = 0, NB do
    cdf[b] = acc / n
    acc = acc + hist[b]
  end
  cdf[NB + 1] = 1
  for i = 1, n do
    local v = (a[i] - lo) * s
    local b = floor(v)
    a[i] = cdf[b] + (cdf[b + 1] - cdf[b]) * (v - b)
  end
  return a
end

return Noise
