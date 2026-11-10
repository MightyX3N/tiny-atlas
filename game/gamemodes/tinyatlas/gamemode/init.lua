AddCSLuaFile("shared.lua")
AddCSLuaFile("cl_init.lua")
AddCSLuaFile("cl_ride.lua")
AddCSLuaFile("cl_atlas.lua")
AddCSLuaFile("cl_view.lua")
AddCSLuaFile("cl_ui.lua")
AddCSLuaFile("cl_rider.lua")
AddCSLuaFile("core/kit.lua")
AddCSLuaFile("cl_hud.lua")
AddCSLuaFile("cl_menu.lua")
AddCSLuaFile("cl_gmod.lua")
AddCSLuaFile("cl_online.lua")
AddCSLuaFile("cl_others.lua")
AddCSLuaFile("cl_live.lua")
AddCSLuaFile("core/ghost.lua")
AddCSLuaFile("core/bots.lua")
AddCSLuaFile("thirdparty/json.lua")
-- the world builder: every shared Lua module in atlas/ (so a new one can never be left out)
for _, f in ipairs(file.Find(GM.FolderName .. "/gamemode/atlas/*.lua", "LUA")) do AddCSLuaFile("atlas/" .. f) end
-- asset packs are addons with lua/tinyatlas/packs/<id>.lua (+ <id>_gmod.lua): send them to clients
for _, f in ipairs(file.Find("tinyatlas/packs/*.lua", "LUA")) do AddCSLuaFile("tinyatlas/packs/" .. f) end
include("shared.lua")
-- the game's pixel fonts (SIL Open Font License: content/resource/fonts/*_OFL.txt) for players joining a server
resource.AddFile("resource/fonts/jersey10.ttf")
resource.AddFile("resource/fonts/micro5.ttf")

-- riding live together on this server: each player's game sends where its rider is a few times a second; the
-- server passes it on to everyone else (cl_live.lua). A message is a short text; a player sending too fast is slowed.
util.AddNetworkString("tinyatlas_live")
local last = {}
net.Receive("tinyatlas_live", function(len, ply)
  if not IsValid(ply) or len > 8 * 1024 then return end
  local now = SysTime()
  if last[ply] and now - last[ply] < 0.1 then return end
  last[ply] = now
  local text = net.ReadString()
  net.Start("tinyatlas_live")
  net.WriteString(ply:SteamID64() or tostring(ply:EntIndex()))
  net.WriteString(text)
  net.SendOmit(ply)
end)
hook.Add("PlayerDisconnected", "TinyAtlas_Live", function(ply) last[ply] = nil end)
