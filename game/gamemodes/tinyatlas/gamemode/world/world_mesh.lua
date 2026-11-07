-- Builds the world's geometry as quad buffers (4 vertices per quad: x y z u v r g b each, local metres).
-- Engine-agnostic: GMod turns buffers into IMeshes, LÖVE into love.graphics meshes.
local M = {}
local floor, max, min, sqrt, cos, sin, pi = math.floor, math.max, math.min, math.sqrt, math.cos, math.sin, math.pi

-- light: direction towards the sun, ambient + diffuse
local LX, LY, LZ = 0.38, -0.42, 0.82
do local l = sqrt(LX * LX + LY * LY + LZ * LZ); LX, LY, LZ = LX / l, LY / l, LZ / l end
local AMB, DIF = 0.55, 0.5
M.SKIRT = 1.5            -- skirts hang this far down so neighbouring levels never show a crack
M.TILE_CELLS = 3          -- ground textures repeat every 3 m at the 1 m level
M.WATER_CELLS = 11        -- the water texture repeats every 11 m

local function shade_n(nx, ny, nz)
  local l = sqrt(nx * nx + ny * ny + nz * nz)
  local d = (nx * LX + ny * LY + nz * LZ) / l
  return AMB + DIF * (d > 0 and d or 0)
end
M.shade_n = shade_n

-- buffers are reused (their big arrays stay allocated), so building doesn't churn the garbage collector
local pool = {}
function M.buffer()
  local b = pool[#pool]
  if b then pool[#pool] = nil; b.n, b.k = 0, 0; return b end
  return { n = 0, k = 0, v = {} }
end
function M.release(b) if #pool < 64 then pool[#pool + 1] = b end end

local function vert(b, x, y, z, u, v, r, g, bl)
  local a, k = b.v, b.k
  a[k + 1], a[k + 2], a[k + 3], a[k + 4], a[k + 5], a[k + 6], a[k + 7], a[k + 8] = x, y, z, u, v, r, g, bl
  b.k = k + 8
end
M.vert = vert
local function done(b) b.n = b.n + 1 end
M.done = done

local function c255(x) x = floor(x + 0.5); return x > 255 and 255 or (x < 0 and 0 or x) end

local function hash(a, b) return (a * 92837 + b * 68947 + 12345) % 1013 end
M.hash = hash

-- ---------------------------------------------------------------- the 1 m level ----
-- Ground of one block (B x B cells) of a near chunk. tagcells[tag] = { {u0,v0,u1,v1}, ... }.
-- Local coords: x = cell column inside the block, y = cell row (origin = block south-west corner).
function M.ground_lod1(b, C, bi, bj, B, tagcells, fallback)
  local n, H, T, tn = C.n, C.H, C.T, C.tn
  local i0, j0 = bi * B, bj * B
  local K = M.TILE_CELLS
  local S = {}
  for j = 0, B do
    local gj = j0 + j
    local jd, ju = max(gj - 1, 0), min(gj + 1, n - 1)
    for i = 0, B do
      local gi = i0 + i
      local il, ir = max(gi - 1, 0), min(gi + 1, n - 1)
      local dx = (H[gj * n + ir] - H[gj * n + il]) / (ir - il)
      local dy = (H[ju * n + gi] - H[jd * n + gi]) / (ju - jd)
      S[j * (B + 1) + i] = 255 * shade_n(-dx, -dy, 1)
    end
  end
  local gx0, gy0 = floor(C.x0 + 0.5), floor(C.y0 + 0.5)
  local rects = {}
  for j = 0, B - 1 do
    local gj = j0 + j
    local gy = gy0 + gj
    local ty = floor(gy / K)
    local fy0 = (gy - ty * K) / K
    local fy1 = fy0 + 1 / K
    for i = 0, B - 1 do
      local gi = i0 + i
      local gx = gx0 + gi
      local tx = floor(gx / K)
      local cl = tagcells[T[gj * tn + gi]] or fallback
      local r = cl[1 + hash(tx, ty) % #cl]
      local fx0 = (gx - tx * K) / K
      local du, dv = r[3] - r[1], r[4] - r[2]
      local u0, u1 = r[1] + du * fx0, r[1] + du * (fx0 + 1 / K)
      local v0, v1 = r[4] - dv * fy0, r[4] - dv * fy1
      local s00, s10 = S[j * (B + 1) + i], S[j * (B + 1) + i + 1]
      local s11, s01 = S[(j + 1) * (B + 1) + i + 1], S[(j + 1) * (B + 1) + i]
      vert(b, i, j, H[gj * n + gi], u0, v0, s00, s00, s00)
      vert(b, i + 1, j, H[gj * n + gi + 1], u1, v0, s10, s10, s10)
      vert(b, i + 1, j + 1, H[(gj + 1) * n + gi + 1], u1, v1, s11, s11, s11)
      vert(b, i, j + 1, H[(gj + 1) * n + gi], u0, v1, s01, s01, s01)
      done(b)
    end
  end
  -- skirts on all four edges
  local d = M.SKIRT
  local function skirt(ia, ja, ib, jb, ci, cj)
    local cl = tagcells[T[(j0 + cj) * tn + i0 + ci]] or fallback
    local r = cl[1]
    local za, zb = H[(j0 + ja) * n + i0 + ia], H[(j0 + jb) * n + i0 + ib]
    local s = 150
    vert(b, ia, ja, za, r[1], r[2], s, s, s); vert(b, ib, jb, zb, r[3], r[2], s, s, s)
    vert(b, ib, jb, zb - d, r[3], r[4], s, s, s); vert(b, ia, ja, za - d, r[1], r[4], s, s, s)
    done(b)
  end
  for k = 0, B - 1 do
    skirt(k, 0, k + 1, 0, k, 0); skirt(k + 1, B, k, B, k, B - 1)
    skirt(0, k + 1, 0, k, 0, k); skirt(B, k, B, k + 1, B - 1, k)
  end
  return b
end

-- water surface z at chunk-local (x, y) metres from the 8 m grid
local function water_z(C, x, y)
  local W, wn, wr = C.W, C.wn, C.wres
  local fx, fy = x / wr, y / wr
  local i, j = floor(fx), floor(fy)
  if i >= wn - 1 then i = wn - 2 end
  if j >= wn - 1 then j = wn - 2 end
  if i < 0 then i = 0 end
  if j < 0 then j = 0 end
  fx, fy = fx - i, fy - j
  local a, b2 = W[j * wn + i], W[j * wn + i + 1]
  local c, d = W[(j + 1) * wn + i], W[(j + 1) * wn + i + 1]
  return (a + (b2 - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy
end
M.water_z = water_z

-- Water surface on the water-tagged cells of a block. UVs stay inside frame 0 of the animation sheet
-- (frames stacked vertically); the engine slides the texture by one frame height to animate.
function M.water_lod1(b, C, bi, bj, B, water_tag, frames, sheet_px)
  if not C.W then return b end
  local T, tn = C.T, C.tn
  local i0, j0 = bi * B, bj * B
  local K = M.WATER_CELLS
  local fh = 1 / frames
  local inset = 0.5 / (sheet_px or 1792)
  local gx0, gy0 = floor(C.x0 + 0.5), floor(C.y0 + 0.5)
  for j = 0, B - 1 do
    local gj = j0 + j
    for i = 0, B - 1 do
      local gi = i0 + i
      if T[gj * tn + gi] == water_tag then
        local gx, gy = gx0 + gi, gy0 + gj
        local fx = (gx - floor(gx / K) * K) / K
        local fy = (gy - floor(gy / K) * K) / K
        local u0, u1 = fx, fx + 1 / K
        local v0 = inset + (fh - 2 * inset) * (1 - fy)
        local v1 = inset + (fh - 2 * inset) * (1 - fy - 1 / K)
        vert(b, i, j, water_z(C, gi, gj), u0, v0, 255, 255, 255)
        vert(b, i + 1, j, water_z(C, gi + 1, gj), u1, v0, 255, 255, 255)
        vert(b, i + 1, j + 1, water_z(C, gi + 1, gj + 1), u1, v1, 255, 255, 255)
        vert(b, i, j + 1, water_z(C, gi, gj + 1), u0, v1, 255, 255, 255)
        done(b)
      end
    end
  end
  return b
end

-- ---------------------------------------------------------------- objects ----
-- ear clipping for building roofs; ring = { x1, y1, x2, y2, ... } counter-clockwise
local function triangulate(xs, ys, out)
  local n = #xs
  local idx = {}
  for i = 1, n do idx[i] = i end
  local guard = 0
  while #idx > 3 and guard < 400 do
    guard = guard + 1
    local m = #idx
    local clipped = false
    for k = 1, m do
      local a, bb, c = idx[(k - 2) % m + 1], idx[k], idx[k % m + 1]
      local ax, ay, bx, by, cx, cy = xs[a], ys[a], xs[bb], ys[bb], xs[c], ys[c]
      local cross = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
      if cross > 1e-9 then
        local inside = false
        for q = 1, m do
          local p = idx[q]
          if p ~= a and p ~= bb and p ~= c then
            local px, py = xs[p], ys[p]
            local d1 = (bx - ax) * (py - ay) - (by - ay) * (px - ax)
            local d2 = (cx - bx) * (py - by) - (cy - by) * (px - bx)
            local d3 = (ax - cx) * (py - cy) - (ay - cy) * (px - cx)
            if d1 >= 0 and d2 >= 0 and d3 >= 0 then inside = true; break end
          end
        end
        if not inside then
          out[#out + 1] = a; out[#out + 1] = bb; out[#out + 1] = c
          table.remove(idx, k); clipped = true
          break
        end
      end
    end
    if not clipped then break end
  end
  if #idx == 3 then out[#out + 1] = idx[1]; out[#out + 1] = idx[2]; out[#out + 1] = idx[3]
  elseif #idx > 3 then   -- degenerate ring: fan the rest
    for k = 2, #idx - 1 do out[#out + 1] = idx[1]; out[#out + 1] = idx[k]; out[#out + 1] = idx[k + 1] end
  end
  return out
end
M.triangulate = triangulate

local function ring_local(Bd, first, ox, oy)
  local xs, ys = {}, {}
  local n = (#Bd - first + 1) / 2
  for k = 1, n do xs[k] = Bd[first + 2 * k - 2] - ox; ys[k] = Bd[first + 2 * k - 1] - oy end
  if n > 1 and xs[n] == xs[1] and ys[n] == ys[1] then xs[n], ys[n] = nil, nil; n = n - 1 end
  local area = 0
  for k = 1, n do local k2 = k % n + 1; area = area + xs[k] * ys[k2] - xs[k2] * ys[k] end
  if area < 0 then
    for k = 1, floor(n / 2) do xs[k], xs[n + 1 - k] = xs[n + 1 - k], xs[k]; ys[k], ys[n + 1 - k] = ys[n + 1 - k], ys[k] end
  end
  return xs, ys, n
end
M.ring_local = ring_local

local function wall_shade(dx, dy, L)
  return shade_n(dy / L, -dx / L, 0.15)
end

local function roof(b, xs, ys, top, white, r, g, bl)
  local tri = triangulate(xs, ys, {})
  local u, v = (white[1] + white[3]) / 2, (white[2] + white[4]) / 2
  local s = shade_n(0, 0, 1)
  r, g, bl = c255(r * s), c255(g * s), c255(bl * s)
  for k = 1, #tri, 3 do
    local a, bb, c = tri[k], tri[k + 1], tri[k + 2]
    vert(b, xs[a], ys[a], top, u, v, r, g, bl); vert(b, xs[bb], ys[bb], top, u, v, r, g, bl)
    vert(b, xs[c], ys[c], top, u, v, r, g, bl); vert(b, xs[c], ys[c], top, u, v, r, g, bl)
    done(b)
  end
end

-- A building with textured facades: one quad per bay per floor. Bd = { style, height, base, x1, y1, ... }
-- O = objects atlas info (facades, white, roof_colour), P = pack.buildings, tint = { r, g, b }
function M.building_lod1(b, Bd, ox, oy, O, P, tint)
  local style, height, base = Bd[1], Bd[2], Bd[3]
  local xs, ys, n = ring_local(Bd, 4, ox, oy)
  if n < 3 then return end
  local F = O.facades[style % #O.facades + 1]
  local up, gr = F.upper, F.ground
  local top = base + height
  local bay, fl, gfl = P.bay_metres or 2.9, P.floor_metres or 3.2, P.ground_floor_metres or 4.2
  local zg = min(top, base + gfl)
  local rows = floor((top - zg) / fl + 0.5)
  local rh = rows > 0 and (top - zg) / rows or 0
  local z0 = base - 1
  for k = 1, n do
    local k2 = k % n + 1
    local x1, y1, x2, y2 = xs[k], ys[k], xs[k2], ys[k2]
    local dx, dy = x2 - x1, y2 - y1
    local L = sqrt(dx * dx + dy * dy)
    if L > 0.3 then
      local s = c255(255 * wall_shade(dx, dy, L))
      local nb = max(1, floor(L / bay + 0.5))
      for q = 0, nb - 1 do
        local ax, ay = x1 + dx * q / nb, y1 + dy * q / nb
        local bx, by = x1 + dx * (q + 1) / nb, y1 + dy * (q + 1) / nb
        vert(b, ax, ay, z0, gr[1], gr[4], s, s, s); vert(b, bx, by, z0, gr[3], gr[4], s, s, s)
        vert(b, bx, by, zg, gr[3], gr[2], s, s, s); vert(b, ax, ay, zg, gr[1], gr[2], s, s, s)
        done(b)
        for f = 0, rows - 1 do
          local za, zb = zg + f * rh, zg + (f + 1) * rh
          vert(b, ax, ay, za, up[1], up[4], s, s, s); vert(b, bx, by, za, up[3], up[4], s, s, s)
          vert(b, bx, by, zb, up[3], up[2], s, s, s); vert(b, ax, ay, zb, up[1], up[2], s, s, s)
          done(b)
        end
      end
    end
  end
  local rc = O.roof_colour
  roof(b, xs, ys, top, O.white, rc[1] * tint[1], rc[2] * tint[2], rc[3] * tint[3])
end

-- A building as plain coloured walls + roof (the distant levels). colour = { r, g, b }
function M.building_flat(b, xs, ys, n, base, top, white, wall, roofc)
  local u, v = (white[1] + white[3]) / 2, (white[2] + white[4]) / 2
  for k = 1, n do
    local k2 = k % n + 1
    local x1, y1, x2, y2 = xs[k], ys[k], xs[k2], ys[k2]
    local dx, dy = x2 - x1, y2 - y1
    local L = sqrt(dx * dx + dy * dy)
    if L > 0.3 then
      local s = wall_shade(dx, dy, L)
      local r, g, bl = c255(wall[1] * s), c255(wall[2] * s), c255(wall[3] * s)
      vert(b, x1, y1, base - 1, u, v, r, g, bl); vert(b, x2, y2, base - 1, u, v, r, g, bl)
      vert(b, x2, y2, top, u, v, r, g, bl); vert(b, x1, y1, top, u, v, r, g, bl)
      done(b)
    end
  end
  roof(b, xs, ys, top, white, roofc[1], roofc[2], roofc[3])
end

-- A box building, plain coloured (mid pages hold thousands of these): 4 walls and 1 roof quad.
function M.box_flat(b, bx, ox, oy, wall, roofc)
  local x, y, L, Wd, a = bx[1] - ox, bx[2] - oy, bx[3] / 2, bx[4] / 2, bx[5] * pi / 180
  local c, s = cos(a), sin(a)
  local base, top = bx[7], bx[7] + bx[6]
  local x1, y1 = x - L * c + Wd * s, y - L * s - Wd * c
  local x2, y2 = x + L * c + Wd * s, y + L * s - Wd * c
  local x3, y3 = x + L * c - Wd * s, y + L * s + Wd * c
  local x4, y4 = x - L * c - Wd * s, y - L * s + Wd * c
  local function wall_q(ax, ay, bx2, by2, len)
    local sh = wall_shade(bx2 - ax, by2 - ay, len)
    local r, g, bl = c255(wall[1] * sh), c255(wall[2] * sh), c255(wall[3] * sh)
    vert(b, ax, ay, base - 1, 0.5, 0.5, r, g, bl); vert(b, bx2, by2, base - 1, 0.5, 0.5, r, g, bl)
    vert(b, bx2, by2, top, 0.5, 0.5, r, g, bl); vert(b, ax, ay, top, 0.5, 0.5, r, g, bl)
    done(b)
  end
  local l2, w2 = 2 * L + 1e-6, 2 * Wd + 1e-6
  wall_q(x1, y1, x2, y2, l2); wall_q(x2, y2, x3, y3, w2); wall_q(x3, y3, x4, y4, l2); wall_q(x4, y4, x1, y1, w2)
  local sr = shade_n(0, 0, 1)
  local r, g, bl = c255(roofc[1] * sr), c255(roofc[2] * sr), c255(roofc[3] * sr)
  vert(b, x1, y1, top, 0.5, 0.5, r, g, bl); vert(b, x2, y2, top, 0.5, 0.5, r, g, bl)
  vert(b, x3, y3, top, 0.5, 0.5, r, g, bl); vert(b, x4, y4, top, 0.5, 0.5, r, g, bl)
  done(b)
end

-- mid-page box building { x, y, length, width, angle_deg, height, base } -> ring
function M.box_ring(bx, ox, oy)
  local x, y, L, Wd, a = bx[1] - ox, bx[2] - oy, bx[3] / 2, bx[4] / 2, bx[5] * pi / 180
  local c, s = cos(a), sin(a)
  local xs, ys = {}, {}
  local pts = { { -L, -Wd }, { L, -Wd }, { L, Wd }, { -L, Wd } }
  for k = 1, 4 do xs[k] = x + pts[k][1] * c - pts[k][2] * s; ys[k] = y + pts[k][1] * s + pts[k][2] * c end
  return xs, ys, 4
end

-- A tree or bush: two crossed quads with the sprite. rect = { u0, v0, u1, v1, w_px, h_px }
function M.tree(b, x, y, z, rect, height, ang, s)
  local w = height * rect[5] / rect[6] / 2
  s = s or 255
  for k = 0, 1 do
    local a = ang + k * pi / 2
    local dx, dy = cos(a) * w, sin(a) * w
    vert(b, x - dx, y - dy, z - 0.2, rect[1], rect[4], s, s, s)
    vert(b, x + dx, y + dy, z - 0.2, rect[3], rect[4], s, s, s)
    vert(b, x + dx, y + dy, z + height, rect[3], rect[2], s, s, s)
    vert(b, x - dx, y - dy, z + height, rect[1], rect[2], s, s, s)
    done(b)
  end
end

-- Bridge deck segment: top into the ground buffer (tag texture), sides into the objects buffer
function M.bridge_segment(gb, ob, x1, y1, z1, x2, y2, z2, w, rect, white, side)
  local dx, dy = x2 - x1, y2 - y1
  local L = sqrt(dx * dx + dy * dy)
  if L < 0.05 then return end
  local nx, ny = -dy / L * w / 2, dx / L * w / 2
  local s = 255 * shade_n(0, 0, 1)
  vert(gb, x1 - nx, y1 - ny, z1, rect[1], rect[4], s, s, s); vert(gb, x2 - nx, y2 - ny, z2, rect[3], rect[4], s, s, s)
  vert(gb, x2 + nx, y2 + ny, z2, rect[3], rect[2], s, s, s); vert(gb, x1 + nx, y1 + ny, z1, rect[1], rect[2], s, s, s)
  done(gb)
  local u, v = (white[1] + white[3]) / 2, (white[2] + white[4]) / 2
  for sd = -1, 1, 2 do
    local ex, ey = nx * sd, ny * sd
    local sh = wall_shade(dx * sd, dy * sd, L)
    local r, g, bl = c255(side[1] * sh), c255(side[2] * sh), c255(side[3] * sh)
    vert(ob, x1 + ex, y1 + ey, z1, u, v, r, g, bl); vert(ob, x2 + ex, y2 + ey, z2, u, v, r, g, bl)
    vert(ob, x2 + ex, y2 + ey, z2 - 0.9, u, v, r, g, bl); vert(ob, x1 + ex, y1 + ey, z1 - 0.9, u, v, r, g, bl)
    done(ob)
  end
  local r, g, bl = c255(side[1] * 0.45), c255(side[2] * 0.45), c255(side[3] * 0.45)
  vert(ob, x1 - nx, y1 - ny, z1 - 0.9, u, v, r, g, bl); vert(ob, x2 - nx, y2 - ny, z2 - 0.9, u, v, r, g, bl)
  vert(ob, x2 + nx, y2 + ny, z2 - 0.9, u, v, r, g, bl); vert(ob, x1 + nx, y1 + ny, z1 - 0.9, u, v, r, g, bl)
  done(ob)
end

-- ---------------------------------------------------------------- distant levels ----
-- Plain-coloured terrain from any grid. V = { H, n (row length of H), T, tn (row length of T), res (m per index) }.
-- Quads cover index range [qi0, qi1) x [qj0, qj1) in steps of `step`; emit(i, j) says which quads exist
-- (holes for finer levels / cells without data). Local coords = (index * res) - (qi0 * res, qj0 * res) + off.
-- colours[tag] = { r, g, b }; water: tag id + colour + optional wz(i, j) (water surface at a vertex index).
function M.terrain_flat(b, V, qi0, qj0, qi1, qj1, step, emit, colours, fallback, water_tag, wcol, wz, offx, offy)
  local H, n, T, tn, res = V.H, V.n, V.T, V.tn, V.res
  local nrow = V.nrows or n
  offx, offy = offx or 0, offy or 0
  local function shade_at(i, j)
    local il, ir = max(i - step, 0), min(i + step, n - 1)
    local jd, ju = max(j - step, 0), min(j + step, nrow - 1)
    local dx = (H[j * n + ir] - H[j * n + il]) / ((ir - il) * res)
    local dy = (H[ju * n + i] - H[jd * n + i]) / ((ju - jd) * res)
    return shade_n(-dx, -dy, 1)
  end
  local E = {}
  local cols = floor((qi1 - qi0) / step)
  local rowsq = floor((qj1 - qj0) / step)
  for jj = 0, rowsq - 1 do
    for ii = 0, cols - 1 do
      E[jj * cols + ii] = emit == nil or emit(qi0 + ii * step, qj0 + jj * step) == true
    end
  end
  local ox, oy = qi0 * res - offx, qj0 * res - offy
  local half = floor(step / 2)
  local SK = M.SKIRT * 2
  local function edge(ai, aj, bi2, bj2, c)
    local za, zb = H[aj * n + ai], H[bj2 * n + bi2]
    local r, g, bl = c255(c[1] * 0.5), c255(c[2] * 0.5), c255(c[3] * 0.5)
    local xa, ya, xb, yb = ai * res - ox, aj * res - oy, bi2 * res - ox, bj2 * res - oy
    vert(b, xa, ya, za, 0.5, 0.5, r, g, bl); vert(b, xb, yb, zb, 0.5, 0.5, r, g, bl)
    vert(b, xb, yb, zb - SK, 0.5, 0.5, r, g, bl); vert(b, xa, ya, za - SK, 0.5, 0.5, r, g, bl)
    done(b)
  end
  local function corner(vi, vj, c, wet)
    local z = wet and wz(vi, vj) or H[vj * n + vi]
    local s = wet and 1 or shade_at(vi, vj)
    vert(b, vi * res - ox, vj * res - oy, z, 0.5, 0.5, c255(c[1] * s), c255(c[2] * s), c255(c[3] * s))
  end
  for jj = 0, rowsq - 1 do
    local j = qj0 + jj * step
    for ii = 0, cols - 1 do
      if E[jj * cols + ii] then
        local i = qi0 + ii * step
        local tag = T[min(j + half, nrow - 2) * tn + min(i + half, tn - 1)]
        local c = (tag == water_tag and wcol) or colours[tag] or fallback
        local wet = tag == water_tag and wz ~= nil
        corner(i, j, c, wet); corner(i + step, j, c, wet); corner(i + step, j + step, c, wet); corner(i, j + step, c, wet)
        done(b)
        if jj == 0 or not E[(jj - 1) * cols + ii] then edge(i, j, i + step, j, c) end
        if jj == rowsq - 1 or not E[(jj + 1) * cols + ii] then edge(i + step, j + step, i, j + step, c) end
        if ii == 0 or not E[jj * cols + ii - 1] then edge(i, j + step, i, j, c) end
        if ii == cols - 1 or not E[jj * cols + ii + 1] then edge(i + step, j, i + step, j + step, c) end
      end
    end
  end
  return b
end

return M
