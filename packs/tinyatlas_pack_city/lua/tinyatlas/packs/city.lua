-- Tiny Atlas asset pack: ground and building textures from ambientCG (CC0) and the OSM Wiki Texture Library (public
-- domain). Buildings are made by atlas/bne_buildings.lua (BeamNG.Earth's rules); the wall and roof textures are
-- grey so each building's colour tints them (brick keeps its own colour). Format: docs/FORMATS.md
local GROUND = {
  asphalt = { "asphalt.png", 1.2 }, paving = { "paving_stone.png", 1 }, cobble = { "sett.png", 1.5 },
  gravel = { "gravel.png", 0.6 }, cycleway = { "asphalt.png", 1.2 }, dirt = { "earth.png", 1 },
  rail = { "rail_ballast.png", 0.6 }, grass = { "grass.png", 1 }, forest_floor = { "terrain_default.png", 1 },
  meadow = { "grass.png", 1 }, farmland = { "earth.png", 1 }, sand = { "sand.png", 0.5 }, rock = { "rock.png", 5 },
  snow = { "snow.png", 1.5 }, wetland = { "grass.png", 1 }, pitch = { "grass.png", 1 },
  urban = { "terrain_default.png", 1 }, rural = { "terrain_default.png", 1 }, water = { "water.png", 100 },
  scrub = { "scrub.png", 1.5 }, parking = { "asphalt.png", 1.2 }, orchard = { "grass.png", 1 },
  dry_grass = { "grass.png", 1 },
}
local BUILDING = { "bld_plaster", "bld_brick", "bld_concrete", "bld_wood", "bld_metal", "bld_stone", "bld_glass",
  "bld_roof_tiles", "bld_roof_slate", "bld_roof_flat", "bld_plain" }
local pack = {
  id = "city",
  name = "City (ambientCG)",
  author = "ambientCG (textures), Tiny Atlas",
  version = "0.1.0",
  license = "CC0 / public domain (ambientCG, OSM Wiki Texture Library), see SOURCES.md",
  local_only = false,
  tile_metres = 1,
  far_metres = 6,
  buildings = true,
  ground = {}, tex_metres = {},
}
for key, g in pairs(GROUND) do pack.ground[key] = { "ground/" .. g[1] }; pack.tex_metres[key] = g[2] end
for _, name in ipairs(BUILDING) do pack.ground[name] = { "bld/" .. name .. ".png" } end
return pack
