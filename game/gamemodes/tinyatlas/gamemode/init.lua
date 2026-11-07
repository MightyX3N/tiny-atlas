AddCSLuaFile("shared.lua")
AddCSLuaFile("cl_init.lua")
AddCSLuaFile("cl_ride.lua")
AddCSLuaFile("cl_world.lua")
for _, f in ipairs({ "world_data.lua", "world_mesh.lua", "world_stream.lua", "route.lua", "look.lua" }) do
  AddCSLuaFile("world/" .. f)
end
-- asset packs are addons with lua/tinyatlas/packs/<id>.lua (+ <id>_gmod.lua): send them to clients
for _, f in ipairs(file.Find("tinyatlas/packs/*.lua", "LUA")) do AddCSLuaFile("tinyatlas/packs/" .. f) end
include("shared.lua")
