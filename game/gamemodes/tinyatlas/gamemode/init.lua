AddCSLuaFile("shared.lua")
AddCSLuaFile("cl_init.lua")
AddCSLuaFile("cl_ride.lua")
AddCSLuaFile("cl_atlas.lua")
AddCSLuaFile("cl_view.lua")
-- the new world builder: shared Lua modules
for _, f in ipairs({ "inflate", "png", "webp", "mvt", "cdt", "cell", "fetch", "height", "ground", "mesh", "route", "world", "buildings",
  "bne_buildings", "photos", "photo_sources", "zstd", "parquet", "wkb", "overture", "overture_index", "ov_layers" }) do AddCSLuaFile("atlas/" .. f .. ".lua") end
-- asset packs are addons with lua/tinyatlas/packs/<id>.lua (+ <id>_gmod.lua): send them to clients
for _, f in ipairs(file.Find("tinyatlas/packs/*.lua", "LUA")) do AddCSLuaFile("tinyatlas/packs/" .. f) end
include("shared.lua")
