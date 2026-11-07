-- TinyAtlas: shared by client and server.
GM.Name = "Tiny Atlas"
GM.Author = "Tiny Atlas"
GM.Email = ""
GM.Website = ""

TinyAtlas = TinyAtlas or {}

AddCSLuaFile("core/ride_physics.lua")
AddCSLuaFile("core/trainer.lua")
AddCSLuaFile("thirdparty/omniplay_bridge.lua")
RidePhysics = include("core/ride_physics.lua")
Trainer = include("core/trainer.lua")
-- OmniPlay (bike trainers, walking pads): the SDK's bridge. If the player has the omniplay_bridge
-- addon too, it already defined OmniPlay; loading it again just refreshes the same API.
include("thirdparty/omniplay_bridge.lua")
