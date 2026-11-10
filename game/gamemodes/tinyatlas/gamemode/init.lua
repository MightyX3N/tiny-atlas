AddCSLuaFile("shared.lua")
AddCSLuaFile("cl_init.lua")
AddCSLuaFile("cl_ride.lua")
AddCSLuaFile("cl_atlas.lua")
AddCSLuaFile("cl_view.lua")
AddCSLuaFile("cl_ui.lua")
AddCSLuaFile("cl_hud.lua")
AddCSLuaFile("cl_menu.lua")
AddCSLuaFile("cl_gmod.lua")
-- the world builder: every shared Lua module in atlas/ (so a new one can never be left out)
for _, f in ipairs(file.Find(GM.FolderName .. "/gamemode/atlas/*.lua", "LUA")) do AddCSLuaFile("atlas/" .. f) end
-- asset packs are addons with lua/tinyatlas/packs/<id>.lua (+ <id>_gmod.lua): send them to clients
for _, f in ipairs(file.Find("tinyatlas/packs/*.lua", "LUA")) do AddCSLuaFile("tinyatlas/packs/" .. f) end
include("shared.lua")
-- the game's pixel fonts (SIL Open Font License: content/resource/fonts/*_OFL.txt) for players joining a server
resource.AddFile("resource/fonts/jersey10.ttf")
resource.AddFile("resource/fonts/micro5.ttf")
