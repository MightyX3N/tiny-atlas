-- Trees and plants of one built cell (the pack's models: packs/<id>_trees3d.lua from tools/packs/trees3d.py), placed
-- by rules from the ground's own surfaces. Shared by every game; the result is mesh.lua-style groups.
--
--   trees.build(r, g, cx, cy, opts) -> groups, trees, 3D trees, plants, mapped trees
--   r, g     the cell (cell.lua, ground.lua);  cx, cy  its zoom-17 numbers (the same every time it is built)
--   opts.models  the pack's models;  opts.k  metres per global unit;  opts.unit  output units per metre;  opts.tick
--   opts.layers  the cell's zoom-14 tile layers (its .ov_tree, .ov_wood), opts.sub  the cell's place in that tile
--   { 0..7, 0..7 };  opts.lat  its latitude;  opts.elev  its height above sea level (metres)
-- Positions are relative to the cell origin like mesh.lua (x east, y north, z up).
--
-- The rules (all from the ground, nothing placed by hand):
--   trees: dense in woods (in thicker and thinner patches), sparse in parks, on lawns and in gardens, the odd one in the
--     countryside; never on or within CLEAR of a road, path, building or water. Within NEAR_ROAD of a road or path
--     (where a rider passes them) they are 3D (G.lod = 0, drawn within LOD_M) with their picture for farther (G.lod = 1);
--     all others are their picture only, on two crossed planes (always drawn). A forest stays light that way.
--   mapped trees: every single tree and tree row on the map (OpenStreetMap through Overture: street trees, trees in
--     squares and gardens) stands where it is mapped (a row: one every ROW_STEP), moved off a road or path onto the
--     nearest free ground if it is drawn just on one; the trees by the rules keep MAPPED_GAP from them.
--   kinds: broadleaf (CommonTree), conifer (Pine) and birch (Birch) models. In a wood whose leaf type is mapped
--     (OpenStreetMap's leaf_type) that decides; elsewhere the share of conifers comes from the latitude and the height
--     above sea level (more in the north and up the mountains), in stands about STAND metres across rather than
--     sprinkled; birches are a share of the broadleaf trees (more in the north, most on wet ground and heath).
--   plants (grass, ferns, flowers, bushes, mushrooms, rocks, pebbles): only within PLANT_BAND of a road or path (that
--     is all a rider sees close), by the ground they grow on, thickest on the verge right beside a path; 3D, drawn
--     within PLANT_M only (G.lod = 2).
-- Groups with a G.lod are per BLOCK of the cell; G.bx, G.by is the block's middle (metres from the cell origin), and
-- the game picks what to draw by the distance to it.
local cell = ATLAS_REQUIRE("cell")
local mesh = ATLAS_REQUIRE("mesh")
local floor, sqrt, sin, cos, max, min, pi = math.floor, math.sqrt, math.sin, math.cos, math.max, math.min, math.pi

local M = {}
M.LOD_M = 110                  -- metres: nearer than this the 3D trees are drawn (their pictures farther)
M.PLANT_M = 60                 -- metres: nearer than this the plants are drawn
M.BLOCK = 64                   -- metres: trees and plants are grouped in blocks this big, each drawn by its distance
M.CLEAR = 2.5                  -- metres: tree trunks keep this far from roads, paths, buildings and water
M.NEAR_ROAD = 20               -- metres: trees this close to a road or path are 3D
M.PLANT_BAND = 22              -- metres: plants grow this close to a road or path
M.VERGE = 1.6                  -- metres: the verge beside a path (its own, thicker plants)
M.GRID = 2                     -- metres: the cell's ground is looked at on a grid this fine
M.PATCH = 40                   -- metres: woods are thicker in some places and thinner in others, about this big
M.ROW_STEP = 7                 -- metres between the trees of a mapped tree row
M.MAPPED_GAP = 5               -- metres: trees by the rules keep this far from mapped trees
M.NUDGE = 3                    -- metres: a mapped tree drawn on a road is moved at most this far off it
M.STAND = 90                   -- metres: conifers and broadleaf trees grow in stands about this big
M.KIND_SCALE = { broad = 1.0, conifer = 1.5, birch = 0.7 }    -- the models' own sizes to real ones (with GROW's)
M.KIND_SLIM = { conifer = 0.5 }  -- across: the kit's pine is as wide as it is tall, a real spruce or pine much slimmer
M.CONIFER_CLEAR = 4              -- metres: conifers (branches down to the ground) keep this far from roads and paths
M.LEAF_SHARE = { needleleaved = 0.97, broadleaved = 0.03, mixed = 0.5 }    -- conifers in a wood of that leaf type
-- the share of conifers where the leaf type is not mapped: by latitude, more higher up (all near the tree line)
function M.conifer_share(lat, elev)
  local a = math.abs(lat or 50)
  local base = a >= 60 and 0.75 or a >= 55 and 0.45 or a >= 45 and 0.35 or a >= 35 and 0.3 or 0.1
  local up = min(1, max(0, ((elev or 0) - 500) / 1100))
  return base + (0.97 - base) * up
end
function M.birch_share(lat, surf)
  if surf == "wetland" or surf == "scrub" then return 0.5 end
  return math.abs(lat or 50) >= 50 and 0.25 or 0.1
end
-- trees: spacing (metres between possible trees), the chance one grows at each, how tall they grow there
M.GROW = {
  wood = { 4.2, 0.9, 1.3 }, park = { 9, 0.35, 1.0 }, cemetery = { 8, 0.35, 1.0 }, grass = { 10, 0.12, 1.0 },
  residential = { 14, 0.10, 1.0 }, ground = { 16, 0.05, 1.0 }, wetland = { 12, 0.08, 0.9 },
}
-- plants: per kind of ground, { models, height in metres (from, to), how many per 100 m2 }
local FLOOR = {
  { { "Fern_1", "Fern_2" }, { 0.6, 1.2 }, 9 },
  { { "Grass_Wispy_Tall", "Grass_Common_Tall" }, { 0.4, 0.75 }, 10 },
  { { "Plant_1", "Plant_2", "Plant_6" }, { 0.35, 0.8 }, 4 },
  { { "Bush_Long_1", "Bush_Large" }, { 0.9, 1.6 }, 1.2 },
  { { "Clover_1" }, { 0.15, 0.25 }, 2 },
  { { "Mushroom_Common", "Mushroom_RedCap" }, { 0.1, 0.18 }, 0.8 },
  { { "Rock_Medium_1", "Rock_Medium_2", "Rock_Medium_3" }, { 0.4, 0.9 }, 0.15 },
}
local LAWN = {
  { { "Grass_Common_Short", "Grass_Wide_Short" }, { 0.2, 0.35 }, 3 },
  { { "Flower_1_Group", "Flower_2_Group", "Flower_3_Group", "Flower_4_Group", "Flower_7_Group" }, { 0.25, 0.45 }, 1.0 },
  { { "Clover_1" }, { 0.15, 0.25 }, 1.5 },
  { { "Bush_Common_Flowers", "Bush_Long_1" }, { 0.7, 1.2 }, 0.35 },
}
local ROUGH = {
  { { "Grass_Wispy_Tall", "Grass_Common_Tall", "Grass_Wispy_Short" }, { 0.35, 0.7 }, 7 },
  { { "Flower_1_Group", "Flower_2_Group", "Flower_4_Group", "Flower_7_Group" }, { 0.3, 0.5 }, 1.5 },
  { { "Bush_Large", "Bush_Long_1" }, { 0.8, 1.4 }, 0.5 },
  { { "Rock_Medium_1", "Rock_Medium_3" }, { 0.3, 0.7 }, 0.1 },
}
local VERGE = {
  { { "Grass_Common_Short", "Grass_Wispy_Short", "Grass_Wide_Short" }, { 0.25, 0.5 }, 30 },
  { { "Pebble_Round_1", "Pebble_Round_3", "Pebble_Square_2", "Pebble_Square_4" }, { 0.08, 0.18 }, 6 },
  { { "Flower_2_Group", "Flower_3_Group" }, { 0.2, 0.35 }, 2 },
}
M.PLANTS = { wood = FLOOR, park = LAWN, grass = LAWN, cemetery = LAWN, residential = LAWN,
  ground = ROUGH, wetland = ROUGH, scrub = ROUGH }
local SUN = { 0.45, -0.35, 0.82 }           -- towards the sun (x east, y north, z up), as the ground's baked light
do local l = sqrt(SUN[1] ^ 2 + SUN[2] ^ 2 + SUN[3] ^ 2); SUN[1], SUN[2], SUN[3] = SUN[1] / l, SUN[2] / l, SUN[3] / l end

-- every texture the models use, for the game to draw
function M.textures(models)
  local list, seen = {}, {}
  for _, m in pairs(models.models) do
    for _, L in ipairs(m.lods) do
      for _, p in ipairs(L.parts) do if not seen[p.tex] then seen[p.tex] = true; list[#list + 1] = p.tex end end
    end
    if m.picture and not seen[m.picture.tex] then seen[m.picture.tex] = true; list[#list + 1] = m.picture.tex end
  end
  table.sort(list)
  return list
end

-- a little random number generator of its own (the same every time a cell is built)
local function rng(seed)
  local s = seed % 2147483646 + 1
  return function()
    s = (s * 16807) % 2147483647
    return s / 2147483647
  end
end

local function hash(i, j)
  local h = (i * 374761393 + j * 668265263) % 2147483647
  h = (h * h * 1103515245 + 12345) % 2147483647
  return h / 2147483647
end

function M.build(r, g, cx, cy, opts)
  local models = opts.models
  if not models then return {}, 0, 0, 0 end
  local k, U, tick = opts.k, opts.unit or 1, opts.tick or function() end
  local CELL = 8192
  local size = CELL * k                                    -- the cell's size in metres
  local rand = rng(cx * 73856093 + cy * 19349663)
  local trees_list, have = {}, {}
  local kinds = { broad = {}, conifer = {}, birch = {} }
  for name, m in pairs(models.models) do
    have[name] = true
    if not m.plant then
      trees_list[#trees_list + 1] = name
      local kd = name:find("^Pine") and "conifer" or name:find("^Birch") and "birch" or "broad"
      kinds[kd][#kinds[kd] + 1] = name
    end
  end
  table.sort(trees_list)
  if #trees_list == 0 then return {}, 0, 0, 0 end
  for _, l in pairs(kinds) do table.sort(l) end
  if #kinds.broad == 0 then kinds.broad = trees_list end

  -- the cell's ground on a grid: surface, height, and the distance to the nearest road or path
  local G2 = M.GRID
  local nx, ny = floor(size / G2) + 1, floor(size / G2) + 1
  local S, Z, D = {}, {}, {}
  local function at(x, y)
    local lx, ly = x / k, -y / k
    if lx < 0 or lx >= CELL or ly < 0 or ly >= CELL then return nil end
    return mesh.height_at(r, g, lx, ly)
  end
  for j = 0, ny - 1 do
    for i = 0, nx - 1 do
      local z, s = at(i * G2 + G2 / 2, -(j * G2 + G2 / 2))
      local id = j * nx + i
      S[id], Z[id] = s, z
      D[id] = (s and cell.ROADLIKE[s]) and 0 or 1e9
    end
    if j % 16 == 0 then tick() end
  end
  -- distances (two passes over the grid, 8 neighbours)
  local d1, d2 = G2, G2 * 1.4142
  for j = 0, ny - 1 do
    for i = 0, nx - 1 do
      local id = j * nx + i
      local v = D[id]
      if i > 0 then v = min(v, D[id - 1] + d1) end
      if j > 0 then
        v = min(v, D[id - nx] + d1)
        if i > 0 then v = min(v, D[id - nx - 1] + d2) end
        if i < nx - 1 then v = min(v, D[id - nx + 1] + d2) end
      end
      D[id] = v
    end
  end
  for j = ny - 1, 0, -1 do
    for i = nx - 1, 0, -1 do
      local id = j * nx + i
      local v = D[id]
      if i < nx - 1 then v = min(v, D[id + 1] + d1) end
      if j < ny - 1 then
        v = min(v, D[id + nx] + d1)
        if i < nx - 1 then v = min(v, D[id + nx + 1] + d2) end
        if i > 0 then v = min(v, D[id + nx - 1] + d2) end
      end
      D[id] = v
    end
  end
  tick()
  local function grid(x, y)
    local i, j = floor(x / G2), floor(-y / G2)
    if i < 0 or j < 0 or i >= nx or j >= ny then return nil end
    return j * nx + i
  end
  -- nothing grows on these (or right beside them, for trees)
  local function bare(s) return not s or cell.ROADLIKE[s] or cell.WATER[s] or s == "building" or s == "paved" or s == "pier" end
  local function clear(x, y, rr)
    for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 0.7, 0.7 }, { -0.7, 0.7 }, { 0.7, -0.7 }, { -0.7, -0.7 } }) do
      local id = grid(x + d[1] * rr, y + d[2] * rr)
      if id and bare(S[id]) then return false end
    end
    return true
  end
  -- patches: a smooth random field over the world (the same across cell borders), 0..1
  local gx0, gy0 = cx * CELL * k, cy * CELL * k
  local function patch(x, y)
    local fx, fy = (gx0 + x) / M.PATCH, (gy0 - y) / M.PATCH
    local i, j = floor(fx), floor(fy)
    local tx, ty = fx - i, fy - j
    tx, ty = tx * tx * (3 - 2 * tx), ty * ty * (3 - 2 * ty)
    local a = hash(i, j) + (hash(i + 1, j) - hash(i, j)) * tx
    local b = hash(i, j + 1) + (hash(i + 1, j + 1) - hash(i, j + 1)) * tx
    return a + (b - a) * ty
  end
  -- the stands of conifers (a field like patch, larger and of its own)
  local function stand(x, y)
    local fx, fy = (gx0 + x) / M.STAND + 1000.5, (gy0 - y) / M.STAND + 1000.5
    local i, j = floor(fx), floor(fy)
    local tx, ty = fx - i, fy - j
    tx, ty = tx * tx * (3 - 2 * tx), ty * ty * (3 - 2 * ty)
    local a = hash(i + 7919, j) + (hash(i + 7920, j) - hash(i + 7919, j)) * tx
    local b = hash(i + 7919, j + 1) + (hash(i + 7920, j + 1) - hash(i + 7919, j + 1)) * tx
    return a + (b - a) * ty
  end
  -- mapped leaf types: the woods' outlines in metres, looked up per 16 m square
  local woods = {}
  local WL = opts.layers and opts.layers.ov_wood
  if WL and opts.sub then
    local SU = WL.extent / 8
    local ux0, uy0 = opts.sub[1] * SU, opts.sub[2] * SU
    local mu = CELL / SU * k
    for _, f in ipairs(WL.features) do
      for _, poly in ipairs(f.polys or { f.parts }) do
        local rings = {}
        local inside_box = false
        for ri, ring in ipairs(poly) do
          local rr = {}
          for i = 1, #ring - 1, 2 do
            local x, y = (ring[i] - ux0) * mu, -(ring[i + 1] - uy0) * mu
            rr[#rr + 1] = x; rr[#rr + 1] = y
            if x > -50 and x < size + 50 and y < 50 and y > -size - 50 then inside_box = true end
          end
          rings[ri] = rr
        end
        if inside_box then woods[#woods + 1] = { rings = rings, leaf = f.props.leaf } end
      end
    end
  end
  local function in_rings(rings, x, y)
    local c = false
    for _, r in ipairs(rings) do
      local n = #r
      local jx, jy = r[n - 1], r[n]
      for i = 1, n - 1, 2 do
        local ix, iy = r[i], r[i + 1]
        if (iy > y) ~= (jy > y) and x < ix + (y - iy) / (jy - iy) * (jx - ix) then c = not c end
        jx, jy = ix, iy
      end
    end
    return c
  end
  local leaf_at = {}
  local function leaf(x, y)
    if #woods == 0 then return nil end
    local key = floor(x / 16) * 4096 + floor(-y / 16)
    local v = leaf_at[key]
    if v == nil then
      v = false
      local cx2, cy2 = (floor(x / 16) + 0.5) * 16, -(floor(-y / 16) + 0.5) * 16
      for _, w in ipairs(woods) do if in_rings(w.rings, cx2, cy2) then v = w.leaf; break end end
      leaf_at[key] = v
    end
    return v or nil
  end
  local share0 = M.conifer_share(opts.lat, opts.elev)
  -- which model grows at (x, y) on ground s; r() a random number 0..1
  local function choose(x, y, s, r)
    local lt = s == "wood" and leaf(x, y)
    local share = lt and M.LEAF_SHARE[lt] or share0
    if s == "park" or s == "grass" or s == "cemetery" or s == "ground" then share = share * 0.3      -- parks, fields
    elseif s ~= "wood" and s ~= "wetland" and s ~= "scrub" then share = share * 0.08 end            -- streets, gardens
    local kd
    local wild = s == "wood" or s == "wetland" or s == "scrub"
    -- in woods in stands; elsewhere (few, planted one by one) the odd one
    if #kinds.conifer > 0 and ((wild and stand(x, y) + (r() - 0.5) * 0.3 < share) or (not wild and r() < share)) then kd = "conifer"
    elseif #kinds.birch > 0 and r() < M.birch_share(opts.lat, s) then kd = "birch"
    else kd = "broad" end
    local l = kinds[kd]
    return l[1 + floor(r() * #l)], M.KIND_SCALE[kd] or 1, M.KIND_SLIM[kd] or 1, kd
  end

  -- ---- trees ----
  local trees = {}
  -- mapped ones first
  local taken = {}                         -- grid cells near a mapped tree
  local L = opts.layers and opts.layers.ov_tree
  if L and opts.sub then
    local mrand = rng(cx * 19349663 + cy * 83492791 + 7)
    local SU = L.extent / 8                -- tile units per cell
    local ux0, uy0 = opts.sub[1] * SU, opts.sub[2] * SU
    local mu = CELL / SU * k               -- metres per tile unit
    local function free(s) return s and not cell.ROADLIKE[s] and not cell.WATER[s] and s ~= "building" and s ~= "pier" end
    local function place(px, py, height)
      if px < 0 or px >= size or py > 0 or py <= -size then return end
      local id = grid(px, py)
      if not id then return end
      if not free(S[id]) then
        -- drawn on a road (the map's road is wider than the real one there): the nearest free ground
        local found
        for rr = 0.5, M.NUDGE, 0.5 do
          for q = 0, 15 do
            local a = q * pi / 8
            local qx, qy = px + cos(a) * rr, py + sin(a) * rr
            local qid = grid(qx, qy)
            if qid and free(S[qid]) then found = true; px, py, id = qx, qy, qid; break end
          end
          if found then break end
        end
        if not found then return end
      end
      local z = at(px, py) or Z[id]
      if not z then return end
      local name, ks, slim = choose(px, py, S[id], mrand)
      local m = models.models[name]
      local sc = (0.85 + mrand() * 0.45) * ks
      if height and height > 2 and m.height > 0 then sc = min(2.5, max(0.5, height / m.height)) end
      trees[#trees + 1] = { px, py, z, mrand() * 2 * pi, sc, name, D[id] <= M.NEAR_ROAD, slim }
      local r = floor(M.MAPPED_GAP / G2)
      local i0, j0 = floor(px / G2), floor(-py / G2)
      for j = j0 - r, j0 + r do for i = i0 - r, i0 + r do taken[j * nx + i] = true end end
    end
    for fi, f in ipairs(L.features) do
      local pp = f.parts[1]
      if f.type == 1 then
        place((pp[1] - ux0) * mu, -(pp[2] - uy0) * mu, f.props.height)
      elseif f.type == 2 then
        -- a row: one tree every ROW_STEP along it, starting half a step in
        local carry = M.ROW_STEP / 2
        for i = 1, #pp - 3, 2 do
          local ax, ay = (pp[i] - ux0) * mu, -(pp[i + 1] - uy0) * mu
          local bx, by = (pp[i + 2] - ux0) * mu, -(pp[i + 3] - uy0) * mu
          local len = sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
          local t = carry
          while t <= len do
            local f2 = t / len
            place(ax + (bx - ax) * f2, ay + (by - ay) * f2, f.props.height)
            t = t + M.ROW_STEP
          end
          carry = t - len
        end
      end
      if fi % 64 == 0 then tick() end
    end
  end
  local mapped = #trees
  local step = 4.2
  local y = 0
  while y > -size do
    local x = 0
    while x < size do
      local px, py = x + rand() * step, y - rand() * step
      local id = grid(px, py)
      local s = id and S[id]
      local rule = s and M.GROW[s]
      if rule then
        local keep = (step / rule[1]) ^ 2 * rule[2] * (0.35 + 1.0 * patch(px, py))
        if rand() < keep and not taken[id] and clear(px, py, M.CLEAR) then
          local z = at(px, py) or Z[id]
          local name, ks, slim, kd = choose(px, py, s, rand)
          if kd == "conifer" and D[id] < M.CONIFER_CLEAR then
            local l = kinds.broad
            name, ks, slim = l[1 + floor(rand() * #l)], M.KIND_SCALE.broad, 1
          end
          trees[#trees + 1] = { px, py, z, rand() * 2 * pi, (0.75 + rand() * 0.55) * rule[3] * ks, name, D[id] <= M.NEAR_ROAD, slim }
        end
      end
      x = x + step
    end
    y = y - step
    tick()
  end

  -- ---- plants: near roads and paths only ----
  local plants = {}
  local function sow(list, px, py, area)
    for _, kind in ipairs(list) do
      if rand() < kind[3] * area / 100 then
        local names = kind[1]
        local name = names[1 + floor(rand() * #names)]
        if have[name] then
          local hgt = kind[2][1] + rand() * (kind[2][2] - kind[2][1])
          plants[#plants + 1] = { px + (rand() - 0.5) * G2, py + (rand() - 0.5) * G2, nil, rand() * 2 * pi, hgt, name }
        end
      end
    end
  end
  for j = 0, ny - 1 do
    for i = 0, nx - 1 do
      local id = j * nx + i
      local d = D[id]
      local s = S[id]
      if d > 0 and d <= M.PLANT_BAND and not bare(s) then
        local px, py = i * G2 + G2 / 2, -(j * G2 + G2 / 2)
        if d <= M.VERGE or (s and s:sub(1, 4) == "worn") then sow(VERGE, px, py, G2 * G2) end
        local list = M.PLANTS[s]
        if list then sow(list, px, py, G2 * G2) end
      end
    end
    if j % 8 == 0 then tick() end
  end
  -- the ground under each plant, and none on a road after its little jitter
  local kept = {}
  for _, p in ipairs(plants) do
    local z, s = at(p[1], p[2])
    if z and not bare(s) then p[3] = z; kept[#kept + 1] = p end
  end
  plants = kept
  tick()

  -- ---- meshes ----
  local groups, by = {}, {}
  local B = M.BLOCK
  local function group(tex, lod, need, x, y)
    local bi, bj = lod and floor(x / B) or 0, lod and floor(-y / B) or 0
    local key = tex .. "#" .. tostring(lod) .. "#" .. bi .. "#" .. bj
    local G = by[key]
    if G and G.n + need > mesh.MAX_VERTS then G = nil end
    if not G then
      G = { tex = tex, n = 0, d = {}, lod = lod }
      if lod then G.bx, G.by = (bi + 0.5) * B, -(bj + 0.5) * B end
      by[key] = G
      groups[#groups + 1] = G
    end
    return G
  end
  -- a model at (x, y, z), turned by a, scaled by sc; lit like the ground (sun and sky), leaves lighter outside and on top
  local function model(m, x, y, z, a, sc, lod, slim)
    local sx = sc * (slim or 1)
    local c, s = cos(a), sin(a)
    local h = m.height * sc
    local L = m.lods[1]
    for _, p in ipairs(L.parts) do
      local v, idx = p.v, p.i
      local G = group(p.tex, lod, #idx, x, y)
      local d, n = G.d, G.n
      for q = 1, #idx do
        local o = idx[q] * 8
        local vx, vy, vz = v[o + 1] * sx, v[o + 2] * sx, v[o + 3] * sc
        local nx_, ny_, nz_ = v[o + 4], v[o + 5], v[o + 6]
        local rx, ry = vx * c - vy * s, vx * s + vy * c
        local rnx, rny = nx_ * c - ny_ * s, nx_ * s + ny_ * c
        local sun = rnx * SUN[1] + rny * SUN[2] + nz_ * SUN[3]
        if sun < 0 then sun = 0 end
        local light
        if p.leaf then
          local up = vz / h
          local out = sqrt(vx * vx + vy * vy) / (h * 0.35 * (slim or 1))
          light = 0.50 + 0.28 * min(1, up) + 0.12 * min(1, out) + 0.18 * sun
        else
          light = 0.55 + 0.30 * sun
        end
        if light > 1.08 then light = 1.08 end
        local w = (n + q - 1) * 8
        d[w + 1], d[w + 2], d[w + 3] = (x + rx) * U, (y + ry) * U, (z - 0.05 * h + vz) * U
        d[w + 4], d[w + 5] = v[o + 7], v[o + 8]
        local T = p.tint
        if T then
          -- painted from root to tip, as the kit's own material does
          local f = min(1, max(0, vz / h))
          d[w + 6] = min(255, floor(light * 255 * (T[1] + (T[4] - T[1]) * f)))
          d[w + 7] = min(255, floor(light * 255 * (T[2] + (T[5] - T[2]) * f)))
          d[w + 8] = min(255, floor(light * 255 * (T[3] + (T[6] - T[3]) * f)))
        else
          local col = min(255, floor(light * 236))
          d[w + 6], d[w + 7], d[w + 8] = col, col, col
        end
      end
      G.n = n + #idx
    end
  end
  -- a tree's picture on two crossed planes (its light is in the picture)
  local function picture(t, m, lod)
    local P = m.picture
    if not P then return end
    local G = group(P.tex, lod, 12, t[1], t[2])
    local d, n = G.d, G.n
    local sc, a = t[5], t[4]
    local hw, h = P.w * sc * (t[8] or 1) / 2, P.h * sc
    local u0, v0, u1, v1 = P.uv[1], P.uv[2], P.uv[3], P.uv[4]
    for q = 0, 1 do
      local c, s = cos(a + q * pi / 2) * hw, sin(a + q * pi / 2) * hw
      local x0, y0, x1, y1 = t[1] - c, t[2] - s, t[1] + c, t[2] + s
      local zb, zt = t[3] - 0.1 * sc, t[3] - 0.1 * sc + h
      for _, vv in ipairs({ { x0, y0, zb, u0, v1 }, { x1, y1, zb, u1, v1 }, { x1, y1, zt, u1, v0 },
                            { x0, y0, zb, u0, v1 }, { x1, y1, zt, u1, v0 }, { x0, y0, zt, u0, v0 } }) do
        local w = n * 8
        d[w + 1], d[w + 2], d[w + 3] = vv[1] * U, vv[2] * U, vv[3] * U
        d[w + 4], d[w + 5] = vv[4], vv[5]
        d[w + 6], d[w + 7], d[w + 8] = 255, 255, 255
        n = n + 1
      end
    end
    G.n = n
  end
  local n3d = 0
  for _, t in ipairs(trees) do
    local m = models.models[t[6]]
    if t[7] then
      n3d = n3d + 1
      picture(t, m, 1)
      model(m, t[1], t[2], t[3], t[4], t[5], 0, t[8])
    else
      picture(t, m, nil)
    end
    tick()
  end
  for i, p in ipairs(plants) do
    local m = models.models[p[6]]
    model(m, p[1], p[2], p[3], p[4], p[5] / m.height, 2)
    if i % 64 == 0 then tick() end
  end
  return groups, #trees, n3d, #plants, mapped
end

return M
