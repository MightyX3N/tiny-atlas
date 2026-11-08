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
  residential = "urban", commercial = "urban", industrial = "urban", ground = "rural",
}
M.WALL_TEXTURE = "paving"
-- every texture used, in drawing order (water last)
M.TEXTURES = {}
do
  local seen = { water = true }
  for _, t in pairs(M.TEXTURE) do if not seen[t] then seen[t] = true; M.TEXTURES[#M.TEXTURES + 1] = t end end
  table.sort(M.TEXTURES)
  M.TEXTURES[#M.TEXTURES + 1] = "water"
  if not seen.rural then M.TEXTURES[#M.TEXTURES + 1] = "rural" end
end
M.MAX_VERTS = 65535

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
  local function group(tex)
    local G = cur[tex]
    if not G or G.n + 3 > M.MAX_VERTS then
      G = { tex = tex, n = 0, d = {} }
      cur[tex] = G
      groups[#groups + 1] = G
    end
    return G
  end
  local function vert(G, x, y, z, c)
    local d, i = G.d, G.n * 8
    -- textures repeat every tile_metres, anchored to the world origin so they continue across cells
    d[i + 1], d[i + 2], d[i + 3] = x * U, y * U, z * U
    d[i + 4], d[i + 5] = (ox + x) / tm, -(oy + y) / tm
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
        local d, i8 = W.d, W.n * 8
        d[i8 + 1], d[i8 + 2], d[i8 + 3] = x * U, y * U, z * U
        d[i8 + 4], d[i8 + 5] = ((along and (ox + x) or -(oy + y))) / tm, -z / tm
        d[i8 + 6], d[i8 + 7], d[i8 + 8] = c, c, c
        W.n = W.n + 1
      end
      if W.n + 6 > M.MAX_VERTS then cur[M.WALL_TEXTURE] = nil; W = group(M.WALL_TEXTURE) end
      wv(ax, ay, ta); wv(bx, by, tb); wv(bx, by, wb)
      wv(ax, ay, ta); wv(bx, by, wb); wv(ax, ay, wa)
    end
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
  local G = { tex = M.FAR_TEXTURE, n = 0, d = {} }
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
    d[o + 4], d[o + 5] = (ox + x) / tm, -(oy + y) / tm
    local c = shade(i, j)
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
