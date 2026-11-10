-- In Garry's Mod the game looks like itself, not like a GMod gamemode: none of GMod's HUD, crosshair, chat,
-- scoreboard, flashlight or menus' keys, and the GMod player stands still (the game draws its own view and rider).
-- (The LÖVE layer has none of these, so this file does nothing there.)
if TINYATLAS_LOVE then return end

hook.Add("HUDShouldDraw", "TinyAtlas_Hide", function() return false end)
function GM:HUDDrawTargetID() end
function GM:HUDDrawPickupHistory() end
function GM:DrawDeathNotice() end
hook.Add("ChatText", "TinyAtlas_Hide", function() return true end)        -- "joined the game" and such

-- keys that would open GMod's own things (chat, scoreboard, menus) or do player things
local BLOCK = {
  messagemode = true, messagemode2 = true, ["+showscores"] = true, ["+menu"] = true, ["+menu_context"] = true,
  gm_showhelp = true, gm_showteam = true, gm_showspare1 = true, gm_showspare2 = true, ["+zoom"] = true,
  noclip = true, ["impulse 100"] = true, ["impulse 201"] = true, ["+use"] = true, ["+attack"] = true, ["+attack2"] = true,
  ["+reload"] = true, ["+jump"] = true, ["+duck"] = true, lastinv = true,
}
hook.Add("PlayerBindPress", "TinyAtlas_Binds", function(_, bind, pressed)
  if BLOCK[bind] or bind:find("^slot%d") then return true end
end)
-- the GMod player does not walk around under the game (W, A, S, D are the game's keys)
hook.Add("CreateMove", "TinyAtlas_Still", function(cmd)
  cmd:ClearMovement()
  cmd:ClearButtons()
end)
