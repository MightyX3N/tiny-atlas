-- Triangle lists for drawing one built cell: ground with repeating pack textures, water at its level, quay walls.
-- Shared by every game; the game turns the lists into its own meshes.
--
--   mesh.build(r, g, opts) -> groups
--   r      cell.build result;  g  ground.heights result
--   opts.k          metres per global unit (one scale for the whole world, from the world's origin latitude)
--   opts.ox, oy     the cell origin in metres from the world origin (x east, y north): textures line up across cells
--   opts.tile_metres  metres one ground texture covers (the pack's tile_metres)
--   opts.unit       output units per metre (Garry's Mod: 52.4934; 1 = metres)
--   opts.tick       called now and then (build jobs yield there)
--   groups = { { tex = "asphalt", n = vertices, d = { x, y, z, u, v, r, g, b, ... } }, ... }
--     positions are relative to the cell origin; x east, y north, z up; three vertices per triangle,
--     counter-clockwise seen from above; at most 65,535 vertices per group (one GMod mesh)
local cell = ATLAS_REQUIRE("cell")
local sqrt, floor, max, min, abs = math.sqrt, math.floor, math.max, math.min, math.abs

local M = {}

-- which pack ground texture each surface uses
M.TEXTURE = {
  building = "urban", road = "asphalt", road_unpaved = "gravel", cycleway = "cycleway", path = "paving",
  path_unpaved = "dirt", rail = "rail", track = "dirt", pier = "paving", water = "water", sea = "water",
  stream = "water", paved = "paving", sand = "sand", wetland = "wetland", wood = "forest_floor", park = "grass",
  grass = "grass", pitch = "pitch", cemetery = "grass", farmland = "farmland", rock = "rock", ice = "snow",
  residential = "urban", commercial = "urban", industrial = "urban", ground = "rural", worn = "worn", worn_wood = "worn_wood", worn_grass = "worn_grass", worn_rural = "worn_rural",
}
M.WALL_TEXTURE = "paving"
-- every texture used, in drawing order (water last; M.add_textures adds more, e.g. buildings)
M.TEXTURES = { "flat" }
do
  local seen = { water = true }
  for _, t in pairs(M.TEXTURE) do if not seen[t] then seen[t] = true; M.TEXTURES[#M.TEXTURES + 1] = t end end
  table.sort(M.TEXTURES)
  M.TEXTURES[#M.TEXTURES + 1] = "water"
  if not seen.rural then M.TEXTURES[#M.TEXTURES + 1] = "rural" end
end
M.MAX_VERTS = 65535
-- more textures to draw (after the ground; see-through ones last)
function M.add_textures(list, last)
  local have = {}
  for _, t in ipairs(M.TEXTURES) do have[t] = true end
  for _, t in ipairs(list) do if not have[t] then have[t] = true; M.TEXTURES[#M.TEXTURES + 1] = t end end
  for _, t in ipairs(last or {}) do
    for i = #M.TEXTURES, 1, -1 do if M.TEXTURES[i] == t then table.remove(M.TEXTURES, i) end end
    M.TEXTURES[#M.TEXTURES + 1] = t
  end
end

-- Skirts: every edge on the cell's border gets a strip hanging straight down under it, so where the neighbouring
-- cell's ground meets it a little higher or lower (their border points are not always in exactly the same places)
-- no gap opens. Hidden under the neighbour's ground otherwise.
M.SKIRT_LAND = 3
M.SKIRT_WATER = 0.6
local function border_edges(r)
  local X, Y, V, N, S = r.X, r.Y, r.V, r.N, r.S
  local out = {}
  local NX = { 2, 3, 1 }
  for t = 1, r.nt do
    local o = 3 * t - 3
    for i = 1, 3 do
      if not N[o + i] then
        local a, b = V[o + i], V[o + NX[i]]
        local xa, ya, xb, yb = X[a], Y[a], X[b], Y[b]
        if (xa == xb and (xa == 0 or xa == S)) or (ya == yb and (ya == 0 or ya == S)) then
          out[#out + 1] = { t, a, b }
        end
      end
    end
  end
  return out
end
M.border_edges = border_edges

local WATER = cell.WATER
-- light from the south-west, fairly high; flat ground gets FLAT of full brightness
local LX, LY, LZ = -0.45, -0.35, 0.82
do local l = sqrt(LX * LX + LY * LY + LZ * LZ); LX, LY, LZ = LX / l, LY / l, LZ / l end
local FLAT = 228

function M.build(r, g, opts)
  local tick = opts.tick or function() end
  local k, U, tm = opts.k, opts.unit or 1, opts.tile_metres or 3.3
  local ox, oy = opts.ox or 0, opts.oy or 0
  local X, Y, V, N, surf, nt = r.X, r.Y, r.V, r.N, r.surf, r.nt
  local land, water = g.land, g.water

  -- smooth normals of the land surface (area weighted), for shading
  local nx, ny, nz = {}, {}, {}
  for t = 1, nt do
    if t % 256 == 0 then tick() end
    if not WATER[surf[t]] then
      local o = 3 * t - 3
      local a, b, c = V[o + 1], V[o + 2], V[o + 3]
      -- metres, y north (cell Y runs south)
      local ux, uy, uz = (X[b] - X[a]) * k, -(Y[b] - Y[a]) * k, land[b] - land[a]
      local vx, vy, vz = (X[c] - X[a]) * k, -(Y[c] - Y[a]) * k, land[c] - land[a]
      local fx, fy, fz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
      if fz < 0 then fx, fy, fz = -fx, -fy, -fz end
      for _, v in ipairs({ a, b, c }) do
        nx[v] = (nx[v] or 0) + fx; ny[v] = (ny[v] or 0) + fy; nz[v] = (nz[v] or 0) + fz
      end
    end
  end
  local shade = {}
  for v, x in pairs(nx) do
    local y, z = ny[v], nz[v]
    local l = sqrt(x * x + y * y + z * z)
    local s = 1
    if l > 0 then s = (x * LX + y * LY + z * LZ) / l / LZ end
    shade[v] = max(80, min(255, floor(FLAT * s + 0.5)))
  end
  tick()

  local groups, cur = {}, {}
  local TM = opts.tex_metres or {}
  -- an aerial photo over the whole cell (opts.photo = { u0, v0, u1, v1 }: the part of the image this cell is):
  -- every ground triangle takes it, the light only shades the slopes a little (the photo has its own)
  local P = opts.photo
  local pu, pv, pdu, pdv
  if P then pu, pv, pdu, pdv = P.u0, P.v0, (P.u1 - P.u0) / (8192 * k), (P.v1 - P.v0) / (8192 * k) end
  local function group(tex)
    if P then tex = "photo" end
    local G = cur[tex]
    if not G or G.n + 6 > M.MAX_VERTS then
      G = { tex = tex, n = 0, d = {}, tm = TM[tex] or tm }
      cur[tex] = G
      groups[#groups + 1] = G
    end
    return G
  end
  local function vert(G, x, y, z, c)
    local d, i = G.d, G.n * 8
    -- textures repeat every tile_metres (or the pack's size for that texture), anchored to the world origin so
    -- they continue across cells
    local gm = G.tm
    d[i + 1], d[i + 2], d[i + 3] = x * U, y * U, z * U
    if P then
      d[i + 4], d[i + 5] = pu + x * pdu, pv - y * pdv
      c = c / FLAT
      c = 255 * (c < 1 and (0.55 + 0.45 * c) or (1 + 0.25 * (c - 1)))
      if c > 255 then c = 255 end
    else
      d[i + 4], d[i + 5] = (ox + x) / gm, -(oy + y) / gm
    end
    d[i + 6], d[i + 7], d[i + 8] = c, c, c
    G.n = G.n + 1
  end

  for t = 1, nt do
    if t % 256 == 0 then tick() end
    local s = surf[t]
    local G = group(M.TEXTURE[s] or "rural")
    local o = 3 * t - 3
    -- counter-clockwise in the cell (y down) is clockwise seen from above with y north: emit a, c, b
    local a, b, c = V[o + 1], V[o + 3], V[o + 2]
    if WATER[s] then
      vert(G, X[a] * k, -Y[a] * k, water[a], 255)
      vert(G, X[b] * k, -Y[b] * k, water[b], 255)
      vert(G, X[c] * k, -Y[c] * k, water[c], 255)
    else
      vert(G, X[a] * k, -Y[a] * k, land[a], shade[a] or FLAT)
      vert(G, X[b] * k, -Y[b] * k, land[b], shade[b] or FLAT)
      vert(G, X[c] * k, -Y[c] * k, land[c], shade[c] or FLAT)
    end
  end

  -- quay walls and banks: from the land edge down to just under the water
  local W
  for i, e in ipairs(g.walls) do
    if i % 256 == 0 then tick() end
    local a, b = e[1], e[2]
    local ax, ay, bx, by = X[a] * k, -Y[a] * k, X[b] * k, -Y[b] * k
    local ta, tb = land[a], land[b]
    local wa, wb = (water[a] or ta) - 0.5, (water[b] or tb) - 0.5
    if ta > wa or tb > wb then
      W = group(M.WALL_TEXTURE)
      -- shade by the wall's facing; texture along the wall's main direction
      local dx, dy = bx - ax, by - ay
      local l = sqrt(dx * dx + dy * dy)
      local c = 150
      if l > 0 then
        local fx, fy = dy / l, -dx / l
        c = max(70, min(200, floor(150 + 70 * abs(fx * LX + fy * LY) / sqrt(LX * LX + LY * LY))))
      end
      local along = abs(dx) > abs(dy)
      local function wv(x, y, z)
        if P then return vert(W, x, y, z, c * FLAT / 255) end
        local d, i8 = W.d, W.n * 8
        d[i8 + 1], d[i8 + 2], d[i8 + 3] = x * U, y * U, z * U
        d[i8 + 4], d[i8 + 5] = ((along and (ox + x) or -(oy + y))) / W.tm, -z / W.tm
        d[i8 + 6], d[i8 + 7], d[i8 + 8] = c, c, c
        W.n = W.n + 1
      end
      if W.n + 6 > M.MAX_VERTS then cur[M.WALL_TEXTURE] = nil; W = group(M.WALL_TEXTURE) end
      wv(ax, ay, ta); wv(bx, by, tb); wv(bx, by, wb)
      wv(ax, ay, ta); wv(bx, by, wb); wv(ax, ay, wa)
    end
  end

  -- skirts, in the texture of the ground above them; where land meets water at the border they reach below both
  -- (the neighbour's shore may be a hand's width to either side)
  local function skirt_bottom(v, top, depth)
    local lo = top
    if land[v] and land[v] < lo then lo = land[v] end
    if water[v] and water[v] < lo then lo = water[v] end
    return lo - depth
  end
  for _, e in ipairs(border_edges(r)) do
    local t, a, b = e[1], e[2], e[3]
    local s = surf[t]
    local wet = WATER[s]
    local Hs = wet and water or land
    local depth = wet and M.SKIRT_WATER or M.SKIRT_LAND
    local G = group(M.TEXTURE[s] or "rural")
    if G.n + 6 > M.MAX_VERTS then cur[G.tex] = nil; G = group(M.TEXTURE[s] or "rural") end
    local ax, ay, bx, by = X[a] * k, -Y[a] * k, X[b] * k, -Y[b] * k
    local ta, tb = Hs[a], Hs[b]
    local ba, bb = skirt_bottom(a, ta, depth), skirt_bottom(b, tb, depth)
    local ca, cb = wet and 255 or (shade[a] or FLAT), wet and 255 or (shade[b] or FLAT)
    vert(G, ax, ay, ta, ca); vert(G, bx, by, tb, cb); vert(G, bx, by, bb, cb)
    vert(G, ax, ay, ta, ca); vert(G, bx, by, bb, cb); vert(G, ax, ay, ba, ca)
  end
  return groups
end

-- the distant ground: one zoom-14 tile as a coarse height grid (no map detail), drawn behind the built cells.
--   mesh.far(H, tx, ty, opts) -> groups (one), positions relative to the tile's north-west corner
M.FAR_TEXTURE = "rural"
function M.far(H, tx, ty, opts)
  local k, U, tm = opts.k, opts.unit or 1, (opts.tile_metres or 3.3) * 4
  local ox, oy = opts.ox or 0, opts.oy or 0
  local n = opts.grid or 48
  local step = 65536 / n
  local gx0, gy0 = tx * 65536, ty * 65536
  local hs = {}
  for j = 0, n do
    for i = 0, n do hs[j * (n + 1) + i] = H:at_soft(gx0 + i * step, gy0 + j * step) or 0 end
    if opts.tick then opts.tick() end
  end
  local sm = step * k
  local P = opts.photo
  local G = { tex = P and "photo" or M.FAR_TEXTURE, n = 0, d = {} }
  local d = G.d
  local function shade(i, j)
    local il, ir = math.max(0, i - 1), math.min(n, i + 1)
    local jl, jr = math.max(0, j - 1), math.min(n, j + 1)
    local dx = (hs[j * (n + 1) + ir] - hs[j * (n + 1) + il]) / ((ir - il) * sm)
    local dy = -(hs[jr * (n + 1) + i] - hs[jl * (n + 1) + i]) / ((jr - jl) * sm)   -- y north
    local nx, ny, nz = -dx, -dy, 1
    local l = sqrt(nx * nx + ny * ny + 1)
    local s = (nx * LX + ny * LY + nz * LZ) / l / LZ
    return max(80, min(255, floor(FLAT * s + 0.5)))
  end
  local function v(i, j)
    local x, y, z = i * sm, -j * sm, hs[j * (n + 1) + i]
    local o = G.n * 8
    d[o + 1], d[o + 2], d[o + 3] = x * U, y * U, z * U
    local c = shade(i, j)
    if P then
      d[o + 4], d[o + 5] = P.u0 + i / n * (P.u1 - P.u0), P.v0 + j / n * (P.v1 - P.v0)
      c = c / FLAT
      c = 255 * (c < 1 and (0.55 + 0.45 * c) or (1 + 0.25 * (c - 1)))
      if c > 255 then c = 255 end
    else
      d[o + 4], d[o + 5] = (ox + x) / tm, -(oy + y) / tm
    end
    d[o + 6], d[o + 7], d[o + 8] = c, c, c
    G.n = G.n + 1
  end
  for j = 0, n - 1 do
    for i = 0, n - 1 do
      -- counter-clockwise seen from above (y north = -j)
      v(i, j); v(i, j + 1); v(i + 1, j + 1)
      v(i, j); v(i + 1, j + 1); v(i + 1, j)
    end
  end
  return { G }
end

-- ---------------------------------------------------------------------------------------------------------
-- Flat style (low-poly, no textures): every surface a colour, lighting baked into the vertex colours.
-- A warm sun from the south-west and a cool sky light; hollows a little darker; open land shaded by its facets,
-- roads and water smooth. One group per cell (tex = "flat"), so a cell is one or two draws.

M.PALETTE = {
  grass = { 124, 176, 86 }, park = { 118, 172, 82 }, cemetery = { 112, 160, 84 }, ground = { 138, 176, 90 },
  farmland = { 198, 186, 118 }, wood = { 92, 138, 72 }, wetland = { 112, 150, 96 }, pitch = { 108, 172, 80 },
  sand = { 230, 212, 160 }, rock = { 160, 152, 140 }, ice = { 236, 240, 246 },
  residential = { 146, 168, 112 }, commercial = { 182, 178, 168 }, industrial = { 170, 168, 162 },
  building = { 176, 160, 146 },
  road = { 112, 112, 120 }, road_unpaved = { 186, 164, 124 }, cycleway = { 188, 112, 96 }, path = { 214, 200, 170 },
  path_unpaved = { 192, 166, 120 }, track = { 184, 158, 114 }, worn = { 150, 150, 92 }, worn_wood = { 118, 122, 74 }, worn_grass = { 150, 150, 92 }, worn_rural = { 158, 146, 98 }, rail = { 126, 112, 104 }, pier = { 176, 140, 104 },
  paved = { 196, 190, 180 },
  water = { 88, 170, 210 }, sea = { 78, 156, 204 }, stream = { 96, 176, 210 },
  wall = { 164, 156, 144 },
}
local SMOOTH = { road = true, road_unpaved = true, cycleway = true, path = true, path_unpaved = true, track = true,
  rail = true, pier = true, paved = true, building = true, residential = true, commercial = true, industrial = true,
  pitch = true }
-- sky (cool) and sun (warm) light; flat ground in the open comes out at about the palette colour
local SKY = { 0.52, 0.58, 0.72 }
local SUN = { 0.58, 0.50, 0.36 }

local function light(base, ndl, ao, var)
  local out = {}
  for i = 1, 3 do
    local v = base[i] * (SKY[i] + SUN[i] * (ndl > 0 and ndl or 0) / LZ) * ao * var
    out[i] = v < 0 and 0 or (v > 255 and 255 or floor(v + 0.5))
  end
  return out
end

-- small steady colour variation by world position (the same in every cell), so big fields are not one flat colour
local function hash(ix, iy)
  local h = (ix * 374761393 + iy * 668265263) % 2147483647
  h = (h * 1274126177) % 2147483647
  return (h % 1000) / 1000
end
-- smooth value noise: big soft patches (about 40 m) plus a little fine variation
local function vnoise(x, y, s)
  local fx, fy = x / s, y / s
  local ix, iy = floor(fx), floor(fy)
  local ax, ay = fx - ix, fy - iy
  ax, ay = ax * ax * (3 - 2 * ax), ay * ay * (3 - 2 * ay)
  local a, b = hash(ix, iy), hash(ix + 1, iy)
  local c, d = hash(ix, iy + 1), hash(ix + 1, iy + 1)
  return (a + (b - a) * ax) * (1 - ay) + (c + (d - c) * ax) * ay
end
local function noise(x, y)
  return 0.9 + 0.14 * vnoise(x, y, 41) + 0.05 * vnoise(x + 1000, y, 11)
end

function M.build_flat(r, g, opts)
  local tick = opts.tick or function() end
  local k, U = opts.k, opts.unit or 1
  local ox, oy = opts.ox or 0, opts.oy or 0
  local X, Y, V, surf, nt = r.X, r.Y, r.V, r.surf, r.nt
  local land, water = g.land, g.water
  local P = M.PALETTE

  -- smooth vertex normals over land, and how much lower each point is than its neighbours (hollows)
  local nx, ny, nz, nsum, ncount = {}, {}, {}, {}, {}
  local fn = {}
  for t = 1, nt do
    if t % 256 == 0 then tick() end
    if not WATER[surf[t]] then
      local o = 3 * t - 3
      local a, b, c = V[o + 1], V[o + 2], V[o + 3]
      local ux, uy, uz = (X[b] - X[a]) * k, -(Y[b] - Y[a]) * k, land[b] - land[a]
      local vx, vy, vz = (X[c] - X[a]) * k, -(Y[c] - Y[a]) * k, land[c] - land[a]
      local fx, fy, fz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
      if fz < 0 then fx, fy, fz = -fx, -fy, -fz end
      local l = sqrt(fx * fx + fy * fy + fz * fz)
      if l > 0 then fn[t] = (fx * LX + fy * LY + fz * LZ) / l else fn[t] = LZ end
      for _, v in ipairs({ a, b, c }) do
        nx[v] = (nx[v] or 0) + fx; ny[v] = (ny[v] or 0) + fy; nz[v] = (nz[v] or 0) + fz
      end
      nsum[a] = (nsum[a] or 0) + land[b] + land[c]; ncount[a] = (ncount[a] or 0) + 2
      nsum[b] = (nsum[b] or 0) + land[a] + land[c]; ncount[b] = (ncount[b] or 0) + 2
      nsum[c] = (nsum[c] or 0) + land[a] + land[b]; ncount[c] = (ncount[c] or 0) + 2
    end
  end
  -- soft borders: open land takes the average colour of the land surfaces around each point (roads, paths,
  -- buildings and water keep sharp edges)
  local BLEND_NO = { road = true, road_unpaved = true, cycleway = true, path = true, path_unpaved = true, track = true,
    rail = true, pier = true, building = true }
  local br, bg, bb, bn = {}, {}, {}, {}
  for t = 1, nt do
    local s = surf[t]
    if not WATER[s] and not BLEND_NO[s] then
      local col = P[s] or P.ground
      local o = 3 * t - 3
      for i = 1, 3 do
        local v = V[o + i]
        br[v] = (br[v] or 0) + col[1]; bg[v] = (bg[v] or 0) + col[2]; bb[v] = (bb[v] or 0) + col[3]; bn[v] = (bn[v] or 0) + 1
      end
    end
  end
  local blend = {}
  for v, n in pairs(bn) do blend[v] = { br[v] / n, bg[v] / n, bb[v] / n } end
  local vn, ao = {}, {}
  for v, x in pairs(nx) do
    local y, z = ny[v], nz[v]
    local l = sqrt(x * x + y * y + z * z)
    vn[v] = l > 0 and (x * LX + y * LY + z * LZ) / l or LZ
    local below = nsum[v] / ncount[v] - land[v]          -- metres lower than the points around it
    local a = 1 - 0.06 * below
    ao[v] = a < 0.72 and 0.72 or (a > 1.04 and 1.04 or a)
  end
  tick()

  local groups = {}
  local G
  local function newgroup() G = { tex = "flat", n = 0, d = {} }; groups[#groups + 1] = G end
  newgroup()
  local function vert(x, y, z, c)
    local d, i = G.d, G.n * 8
    d[i + 1], d[i + 2], d[i + 3] = x * U, y * U, z * U
    d[i + 4], d[i + 5] = 0, 0
    d[i + 6], d[i + 7], d[i + 8] = c[1], c[2], c[3]
    G.n = G.n + 1
  end

  for t = 1, nt do
    if t % 256 == 0 then tick() end
    if G.n + 3 > M.MAX_VERTS then newgroup() end
    local s = surf[t]
    local base = P[s] or P.ground
    local o = 3 * t - 3
    local a, b, c = V[o + 1], V[o + 3], V[o + 2]          -- counter-clockwise seen from above
    if WATER[s] then
      for _, v in ipairs({ a, b, c }) do
        local x, y = X[v] * k, -Y[v] * k
        vert(x, y, water[v], light(base, LZ, 1, noise(ox + x, oy + y) * 0.5 + 0.5))
      end
    else
      local smooth = SMOOTH[s]
      for _, v in ipairs({ a, b, c }) do
        local x, y = X[v] * k, -Y[v] * k
        -- open land: mostly its own facet, a little smooth, so slopes show facets without long slivers standing out
        local ndl = smooth and vn[v] or (0.7 * fn[t] + 0.3 * vn[v])
        local col = (not BLEND_NO[s] and blend[v]) or base
        vert(x, y, land[v], light(col, ndl, ao[v] or 1, noise(ox + x, oy + y)))
      end
    end
  end

  -- quay walls and banks
  for i, e in ipairs(g.walls) do
    if i % 256 == 0 then tick() end
    local a, b = e[1], e[2]
    local ax, ay, bx, by = X[a] * k, -Y[a] * k, X[b] * k, -Y[b] * k
    local ta, tb = land[a], land[b]
    local wa, wb = (water[a] or ta) - 0.5, (water[b] or tb) - 0.5
    if ta > wa or tb > wb then
      if G.n + 6 > M.MAX_VERTS then newgroup() end
      local dx, dy = bx - ax, by - ay
      local l = sqrt(dx * dx + dy * dy)
      local ndl = 0.3
      if l > 0 then ndl = abs((dy / l) * LX + (-dx / l) * LY) end
      local top = light(P.wall, ndl * 0.8, 1, 1)
      local bot = light(P.wall, ndl * 0.8, 0.7, 1)
      vert(ax, ay, ta, top); vert(bx, by, tb, top); vert(bx, by, wb, bot)
      vert(ax, ay, ta, top); vert(bx, by, wb, bot); vert(ax, ay, wa, bot)
    end
  end

  -- skirts, in the colour of the ground above them (reaching below land and water where they meet)
  local function skirt_bottom(v, top, depth)
    local lo = top
    if land[v] and land[v] < lo then lo = land[v] end
    if water[v] and water[v] < lo then lo = water[v] end
    return lo - depth
  end
  for _, e in ipairs(border_edges(r)) do
    local t, a, b = e[1], e[2], e[3]
    local s = surf[t]
    local wet = WATER[s]
    local Hs = wet and water or land
    local depth = wet and M.SKIRT_WATER or M.SKIRT_LAND
    if G.n + 6 > M.MAX_VERTS then newgroup() end
    local ax, ay, bx, by = X[a] * k, -Y[a] * k, X[b] * k, -Y[b] * k
    local col = light(P[s] or P.ground, LZ * 0.8, 1, 1)
    local ta, tb = Hs[a], Hs[b]
    local ba, bb = skirt_bottom(a, ta, depth), skirt_bottom(b, tb, depth)
    vert(ax, ay, ta, col); vert(bx, by, tb, col); vert(bx, by, bb, col)
    vert(ax, ay, ta, col); vert(bx, by, bb, col); vert(ax, ay, ba, col)
  end
  return groups
end

-- the distant ground in the flat style: one zoom-14 tile of elevation as faceted grass-coloured land
function M.far_flat(H, tx, ty, opts)
  local k, U = opts.k, opts.unit or 1
  local ox, oy = opts.ox or 0, opts.oy or 0
  local n = opts.grid or 48
  local step = 65536 / n
  local gx0, gy0 = tx * 65536, ty * 65536
  local hs = {}
  for j = 0, n do
    for i = 0, n do hs[j * (n + 1) + i] = H:at_soft(gx0 + i * step, gy0 + j * step) or 0 end
    if opts.tick then opts.tick() end
  end
  local sm = step * k
  local G = { tex = "flat", n = 0, d = {} }
  local d = G.d
  local base = M.PALETTE.ground
  local function tri(i1, j1, i2, j2, i3, j3)
    local p = { { i1, j1 }, { i2, j2 }, { i3, j3 } }
    local x1, y1, z1 = i1 * sm, -j1 * sm, hs[j1 * (n + 1) + i1]
    local x2, y2, z2 = i2 * sm, -j2 * sm, hs[j2 * (n + 1) + i2]
    local x3, y3, z3 = i3 * sm, -j3 * sm, hs[j3 * (n + 1) + i3]
    local ux, uy, uz = x2 - x1, y2 - y1, z2 - z1
    local vx, vy, vz = x3 - x1, y3 - y1, z3 - z1
    local fx, fy, fz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
    if fz < 0 then fx, fy, fz = -fx, -fy, -fz end
    local l = sqrt(fx * fx + fy * fy + fz * fz)
    local c = light(base, l > 0 and (fx * LX + fy * LY + fz * LZ) / l or LZ, 1, noise(ox + x1, oy + y1))
    for _, q in ipairs(p) do
      local x, y, z = q[1] * sm, -q[2] * sm, hs[q[2] * (n + 1) + q[1]]
      local o = G.n * 8
      d[o + 1], d[o + 2], d[o + 3] = x * U, y * U, z * U
      d[o + 4], d[o + 5] = 0, 0
      d[o + 6], d[o + 7], d[o + 8] = c[1], c[2], c[3]
      G.n = G.n + 1
    end
  end
  for j = 0, n - 1 do
    for i = 0, n - 1 do
      tri(i, j, i, j + 1, i + 1, j + 1)
      tri(i, j, i + 1, j + 1, i + 1, j)
    end
  end
  return { G }
end

-- height of the drawn ground at a point of the cell (cell units), and the surface there; nil outside the cell.
-- Uses a bucket grid built on first use and kept on r.
function M.height_at(r, g, x, y)
  local B = 512
  local grid = r._tgrid
  local X, Y, V = r.X, r.Y, r.V
  if not grid then
    grid = {}
    for t = 1, r.nt do
      local o = 3 * t - 3
      local a, b, c = V[o + 1], V[o + 2], V[o + 3]
      local x0, x1 = min(X[a], X[b], X[c]), max(X[a], X[b], X[c])
      local y0, y1 = min(Y[a], Y[b], Y[c]), max(Y[a], Y[b], Y[c])
      for by = floor(y0 / B), floor(y1 / B) do
        for bx = floor(x0 / B), floor(x1 / B) do
          local kk = by * 64 + bx
          local L = grid[kk]
          if not L then L = {}; grid[kk] = L end
          L[#L + 1] = t
        end
      end
    end
    r._tgrid = grid
  end
  local L = grid[floor(y / B) * 64 + floor(x / B)]
  if not L then return nil end
  for _, t in ipairs(L) do
    local o = 3 * t - 3
    local a, b, c = V[o + 1], V[o + 2], V[o + 3]
    local x1, y1, x2, y2, x3, y3 = X[a], Y[a], X[b], Y[b], X[c], Y[c]
    local d = (y2 - y3) * (x1 - x3) + (x3 - x2) * (y1 - y3)
    if d ~= 0 then
      local l1 = ((y2 - y3) * (x - x3) + (x3 - x2) * (y - y3)) / d
      local l2 = ((y3 - y1) * (x - x3) + (x1 - x3) * (y - y3)) / d
      local l3 = 1 - l1 - l2
      local e = -1e-9
      if l1 >= e and l2 >= e and l3 >= e then
        local s = r.surf[t]
        local H = WATER[s] and g.water or g.land
        return l1 * H[a] + l2 * H[b] + l3 * H[c], s
      end
    end
  end
  return nil
end

return M
