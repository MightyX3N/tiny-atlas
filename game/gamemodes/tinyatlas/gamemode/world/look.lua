-- Everything the world builders need from the asset pack, for one route and one season:
-- atlas cells per ground tag, colours for the distant levels, tree sprites, facades. Engine-agnostic.
local Look = {}

local function hex(s, def)
  if type(s) ~= "string" then return def end
  local r, g, b = s:match("#?(%x%x)(%x%x)(%x%x)")
  if not r then return def end
  return { tonumber(r, 16), tonumber(g, 16), tonumber(b, 16) }
end
Look.hex = hex

-- pack: the pack table (lua/tinyatlas/packs/<id>.lua); atlas: <id>_gmod.lua; rt: route.txt table
function Look.build(pack, atlas, rt, season)
  season = season or "summer"
  local S = (season ~= "summer" and pack.seasons and pack.seasons[season]) or {}
  local AS = (season ~= "summer" and atlas.seasons and atlas.seasons[season]) or {}
  local L = { season = season }
  -- ground
  local cells_by_name = {}
  for tag, cl in pairs(atlas.ground.cells) do cells_by_name[tag] = cl end
  for tag, cl in pairs(AS.ground or {}) do cells_by_name[tag] = cl end
  local colour_by_name = {}
  for tag, c in pairs(atlas.ground.colour) do colour_by_name[tag] = c end
  for tag, c in pairs(AS.ground_colour or {}) do colour_by_name[tag] = c end
  local fallback = cells_by_name.grass or select(2, next(cells_by_name))
  L.tagcells, L.colours, L.tagcells_by_name = {}, {}, cells_by_name
  for i, name in ipairs(rt.tags) do
    L.tagcells[i - 1] = cells_by_name[name] or fallback
    L.colours[i - 1] = colour_by_name[name] or colour_by_name.grass or { 100, 140, 80 }
    if name == "water" then L.water_tag = i - 1 end
  end
  L.fallback_cells = fallback
  -- hard ground: a tree standing on it gets a tree pit
  L.hard = {}
  for i, name in ipairs(rt.tags) do
    if name == "paving" or name == "cobble" or name == "urban" or name == "asphalt" or name == "parking"
      or name == "cycleway" or name == "gravel" then L.hard[i - 1] = true end
  end
  L.pit_soil = (cells_by_name.dirt or cells_by_name.forest_floor or fallback)[1]
  L.fallback_colour = colour_by_name.grass or { 100, 140, 80 }
  L.water_tag = L.water_tag or -1
  L.water_colour = atlas.water_colour or { 60, 110, 150 }
  local W = pack.water or {}
  L.water_frames = (W.still and W.still.frames) or 1
  L.water_sheet_png = (W.still and W.still.sheet) or W.texture
  L.water_sheet_px = (W.still and W.still.frames and W.still.frames * 112) or 1792
  L.water_ms = (W.still and W.still.ms) or 90
  L.water_opacity = W.opacity or 0.86
  -- objects
  L.objects = AS.objects or atlas.objects
  L.objects_png = L.objects.png
  L.buildings = pack.buildings or {}
  L.roof_tints = {}
  for i, t in ipairs(L.buildings.roof_tints or { { 1, 1, 1 } }) do L.roof_tints[i] = t end
  -- quay walls: the pack's wall texture, found among the ground tiles
  local wall = pack.wall or {}
  for tag, files in pairs(pack.ground or {}) do
    for k, f in ipairs(files) do
      if f == wall.texture and atlas.ground.cells[tag] then L.wall_rect = atlas.ground.cells[tag][k] end
    end
  end
  L.wall_rect = L.wall_rect or (cells_by_name.cobble and cells_by_name.cobble[1]) or fallback[1]
  L.wall_tint = wall.tint or { 0.9, 0.88, 0.85 }
  L.bridge_side = hex(pack.bridge and pack.bridge.side, { 185, 168, 143 })
  -- bridge parts (ground atlas cells); packs without them get plain cobble
  local PB, AB = pack.bridge or {}, atlas.bridge or {}
  local plain = cells_by_name.cobble and cells_by_name.cobble[1] or fallback[1]
  L.bridge = { wall = AB.wall or plain, stone = AB.stone or AB.wall or plain, parapet = AB.parapet or AB.wall or plain,
               arch = AB.arch or AB.wall or plain, tile = PB.tile_metres or 1.5, parapet_h = PB.parapet_height or 1.0,
               thick = PB.deck_thickness or 0.7 }
  L.pit_kerb = L.bridge.stone
  -- trees: per route tree kind
  local trees = {}
  for k, v in pairs(pack.trees or {}) do trees[k] = v end
  for k, v in pairs(S.trees or {}) do
    local t = {}; for a, b in pairs(trees[k] or {}) do t[a] = b end
    for a, b in pairs(v) do t[a] = b end
    trees[k] = t
  end
  local function info(kind)
    local t = trees[kind] or trees.broadleaf
    if not t then return nil end
    local rects = {}
    for _, sp in ipairs(t.sprites or {}) do
      local r = L.objects.sprites[sp]
      if r then rects[#rects + 1] = r end
    end
    if #rects == 0 then return nil end
    local h = t.height or { 8, 14 }
    return { rects = rects, hmin = h[1], hmax = h[2] }
  end
  L.trees = { default = info("broadleaf") }
  for i, kind in ipairs(rt.tree_kinds or {}) do L.trees[i] = info(kind) or L.trees.default end
  -- sky
  local sky = pack.sky or {}
  L.sky_top = hex(sky.top, { 111, 166, 220 })
  L.sky_horizon = hex(sky.horizon, { 200, 219, 232 })
  L.haze = hex(sky.haze, L.sky_horizon)
  L.fog_near, L.fog_far = sky.fog_near or 300, sky.fog_far or 7000
  return L
end

return Look
