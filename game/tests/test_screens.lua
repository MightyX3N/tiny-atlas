-- The game's screens in the fake GMod with the real gamemode files, played with the keys like a player would:
-- the title screen and its route, the route list, starting a ride and riding it with the keys, pause, settings
-- (and an asset pack fixing or moving the look's settings), ending the ride and the results, roam, trainer, my
-- routes (with a GPX file the player added). Also that GMod's own HUD, chat and keys are kept out of the way.
--   luajit.py test_screens.lua <cache dir>
local here = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local CACHE = arg[1]
local PACK = here .. "../../packs/tinyatlas_pack_default"
local DATA = os.tmpname() .. "_gmdata"
os.execute('mkdir -p "' .. DATA .. '/tinyatlas/gpx" && ln -s "' .. CACHE .. '" "' .. DATA .. '/tinyatlas/cache"')
-- a route of the player's own
os.execute('cp "' .. here .. '../gamemodes/tinyatlas/routes/rold-skov.gpx" "' .. DATA .. '/tinyatlas/gpx/my evening loop.gpx"')
local F = dofile(here .. "fakegmod.lua")(DATA, here .. "../gamemodes/tinyatlas/gamemode")
dofile(here .. "fakegmod_render.lua")(F, { lua_roots = { here .. "../gamemodes", PACK .. "/lua" },
  material_roots = { PACK .. "/materials" }, screen = { 1920, 1080 } })
GM = { FolderName = "tinyatlas" }
local GAME = here .. ".."
local read0, find0 = file.Read, file.Find
function file.Read(p, where)
  if where == "GAME" then local f = io.open(GAME .. "/" .. p, "rb"); if not f then return nil end; local s = f:read("*a"); f:close(); return s end
  return read0(p, where)
end
function file.Find(p, where)
  if where == "GAME" then
    local dir, mask = p:match("^gamemodes/(.*)/([^/]*)$")
    local out = {}
    if dir then
      local pi = io.popen('ls "' .. GAME .. '/gamemodes/' .. dir .. '" 2>/dev/null')
      local lua = "^" .. mask:gsub("%.", "%%."):gsub("%*", ".*") .. "$"
      for l in pi:lines() do if l:match(lua) then out[#out + 1] = l end end
      pi:close()
    end
    return out, {}
  end
  return find0(p, where)
end
http = { Fetch = function(url, ok, fail) timer.Simple(0.05, function() fail("offline test") end) end }
local oldprint = print
print = function(...) end
include("cl_init.lua")
hook.Run("InitPostEntity")
local S, UI, V, Ride = TinyAtlas.Screens, TinyAtlas.UI, TinyAtlas.View, TinyAtlas.Ride

local bad = 0
local function check(what, ok, detail)
  if not ok then bad = bad + 1 end
  oldprint(string.format("%-62s %s%s", what, ok and "ok" or "WRONG", detail and ("  (" .. detail .. ")") or ""))
end
local function frame() F.tick(1 / 60); F.run_simple(); F.render_frame(1 / 60) end
local function frames(n) for _ = 1, n do frame() end end
local function press(k) F.keys[_G["KEY_" .. k]] = true; frames(2); F.keys[_G["KEY_" .. k]] = nil; frames(2) end
local function choose(id)
  for _ = 1, 20 do if UI.focused(id) then break end; press("DOWN") end
  local ok = UI.focused(id)
  press("ENTER"); frames(3)
  return ok
end
local function shown(text)
  for _, t in ipairs(F.texts) do if t:find(text, 1, true) then return true end end
  return false
end
local function wait(fn, seconds)
  for _ = 1, (seconds or 60) * 60 do if fn() then return true end; frame() end
  return false
end

-- GMod's own pieces are hidden
check("GMod's HUD hidden", hook.Run("HUDShouldDraw", "CHudHealth") == false)
check("GMod's chat key taken", hook.Run("PlayerBindPress", nil, "messagemode", true) == true)
check("GMod's scoreboard key taken", hook.Run("PlayerBindPress", nil, "+showscores", true) == true)
check("GMod's Esc menu taken while the game's menus are up", (function() frames(1); return hook.Run("OnPauseMenuShow") == false end)())

-- the title screen: the last route's world rides by itself behind it
frames(5)
check("starts on the title screen", S.screen == "title", S.screen)
check("the menu shows the game's name", shown("Tiny Atlas"))
check("the mouse pointer is on for the menus", F.cursor == true)
check("the menu's background route is loading", V.on and V.route_name == "alpe-dhuez" and V.preview == true, tostring(V.route_name))
check("the background world gets built", wait(function() return V.phase == "riding" end, 120))
local s0 = Ride.s; frames(60)
check("the background rides by itself", Ride.mode == "auto" and Ride.s > s0, string.format("%.1f m", Ride.s - s0))
check("the route card shows its name", shown("Alpe d'Huez"))
check("the route card shows the climb", wait(function() return shown("m up") end, 5))

-- the route list
check("'Ride a route' reached with the keys", choose("ride"))
check("the route list is up", S.screen == "routes", S.screen)
frames(10)
local names = 0
for _, n in ipairs({ "Alpe d", "Amsterda", "City Run", "Copenhag", "Rold Sko" }) do if shown(n) then names = names + 1 end end
check("all five routes listed", names == 5, names .. " of 5: " .. table.concat(F.texts, " | "):sub(1, 400))
check("the player's own file is not in the game's list", not shown("evening loop"))
check("Rold Skov chosen", choose("routes:5"))
check("loading screen", S.screen == "loading", S.screen)
check("loading says what it is doing", shown("Building the world around you"))
check("the ride starts by itself when the world is ready", wait(function() return S.screen == "ride" end, 120), S.screen)
check("riding the right route", V.route_name == "rold-skov" and Ride.mode == "ride", tostring(V.route_name) .. " " .. tostring(Ride.mode))
frames(2)
check("the mouse pointer is off while riding", F.cursor == false, tostring(F.cursor) .. " " .. S.screen)
-- ride with the keys
F.keys[KEY_W] = true; frames(60 * 8); F.keys[KEY_W] = nil
check("W rides", Ride.s > 20 and Ride.speed > 3, string.format("%.0f m, %.1f m/s", Ride.s, Ride.speed))
check("the ride screen shows the speed in km/h", shown("km/h"))
check("the ride screen shows the distance", shown("/ 20.3 km") or shown("/ 20.2 km"))
check("the time counts", Ride.stats.time > 7, string.format("%.1f s", Ride.stats.time))

-- pause
F.keys[KEY_ESCAPE] = true; hook.Run("OnPauseMenuShow"); frames(2); F.keys[KEY_ESCAPE] = nil; frames(2)
check("Esc pauses", S.screen == "pause", S.screen)
local sp = Ride.s; frames(60)
check("nothing moves while paused", math.abs(Ride.s - sp) < 1e-6)
check("'Settings' from the pause menu", choose("settings") and S.screen == "settings", S.screen)
local px0 = GetConVar("ta_pixelate"):GetFloat()
press("RIGHT"); frames(2)
check("right raises the pixel size", GetConVar("ta_pixelate"):GetFloat() == px0 + 1, GetConVar("ta_pixelate"):GetString())
press("LEFT"); frames(2)
check("left lowers it again", GetConVar("ta_pixelate"):GetFloat() == px0)
-- an asset pack fixing / moving the look
local pack0 = V.pack
V.pack = setmetatable({ look = { pixelate = { force = 1 }, outlines = { add = -0.2 } } }, { __index = pack0 })
check("a pack can fix the pixel size", V.look_setting("pixelate", V.pack) == 1)
check("a pack can move the outlines", math.abs(V.look_setting("outlines", V.pack) - 0.3) < 1e-6, tostring(V.look_setting("outlines", V.pack)))
frames(2)
check("the settings say the pack sets it", shown("the asset pack sets this one"))
V.pack = pack0
F.keys[KEY_ESCAPE] = true; hook.Run("OnPauseMenuShow"); frames(2); F.keys[KEY_ESCAPE] = nil; frames(2)
check("Esc goes back to the pause menu", S.screen == "pause", S.screen)
check("'End the ride'", choose("finish") and S.screen == "results", S.screen)
check("the results show the distance and time", shown("distance") and shown("time"))
check("the results show the average power", shown("average power"))
check("'Main menu' from the results", choose("menu") and S.screen == "title", S.screen)
check("the menu rides the last route by itself again", V.preview == true and V.route_name == "rold-skov" and Ride.mode == "auto",
  tostring(V.route_name) .. " " .. tostring(Ride.mode))

-- my routes
check("'My routes'", choose("my") and S.screen == "myroutes", S.screen)
frames(5)
check("the player's own GPX file is listed", shown("Rold Skov") or shown("evening"))
F.keys[KEY_ESCAPE] = true; hook.Run("OnPauseMenuShow"); frames(2); F.keys[KEY_ESCAPE] = nil; frames(2)
check("Esc back to the title", S.screen == "title", S.screen)

-- trainer
check("'Trainer'", choose("trainer") and S.screen == "trainer", S.screen)
check("no trainer: says how to ride with the keys", shown("W ride"))
local d0 = GetConVar("ta_trainer_difficulty"):GetFloat()
press("RIGHT")
check("the hills setting changes", GetConVar("ta_trainer_difficulty"):GetFloat() == d0 + 10, GetConVar("ta_trainer_difficulty"):GetString())
press("LEFT")
F.keys[KEY_ESCAPE] = true; hook.Run("OnPauseMenuShow"); frames(2); F.keys[KEY_ESCAPE] = nil; frames(2)


-- your kit
check("'Your kit'", choose("kit") and S.screen == "kit", S.screen)
frames(5)
local RD = TinyAtlas.Rider
local seed0 = GetConVar("ta_kit_seed"):GetInt()
check("a kit of its own from the start", seed0 ~= 0, tostring(seed0))
check("the kit is named", shown(RD.Kit.describe(RD.local_kit()):gsub("^%l", string.upper)))
check("the rider is drawn", RD.M ~= nil and V.kit_view == true)
check("'New kit' rolls another", choose("roll") and GetConVar("ta_kit_seed"):GetInt() ~= seed0)
check("'Last one' goes back", choose("undo") and GetConVar("ta_kit_seed"):GetInt() == seed0)
for _ = 1, 20 do if UI.focused("k_pattern") then break end; press("DOWN") end
press("RIGHT"); press("RIGHT")
local fixed = RD.parse_locks(GetConVar("ta_kit_locks"):GetString()).pattern
check("a pattern fixed", fixed ~= nil, GetConVar("ta_kit_locks"):GetString())
choose("roll")
check("a new kit keeps the fixed pattern", RD.local_kit().pattern == fixed and GetConVar("ta_kit_seed"):GetInt() ~= seed0)
for _ = 1, 20 do if UI.focused("k_pattern") then break end; press("DOWN") end
for _ = 1, #RD.Kit.PATTERNS - 1 do press("RIGHT") end
check("back to any pattern", RD.parse_locks(GetConVar("ta_kit_locks"):GetString()).pattern == nil, GetConVar("ta_kit_locks"):GetString())
F.keys[KEY_ESCAPE] = true; hook.Run("OnPauseMenuShow"); frames(2); F.keys[KEY_ESCAPE] = nil; frames(2)
check("Esc back to the title", S.screen == "title" and not V.kit_view, S.screen)

-- roam
check("'Roam'", choose("roam") and S.screen == "roam", S.screen)
check("places listed", shown("Copenhagen"))
-- type coordinates
for _ = 1, 20 do if UI.focused("coords") then break end; press("DOWN") end
check("the coordinates field reached", UI.focused("coords"))
for c in ("55.68,12.57"):gmatch(".") do
  local k = c == "." and "PERIOD" or c == "," and "COMMA" or c
  press(k)
end
check("typed coordinates", S.coords == "55.68,12.57", S.coords)
check("'Go there' offered for valid coordinates", shown("Go there"))
check("'Go there' starts roaming", choose("go_coords") and S.screen == "loading", S.screen)
check("roam is ready", wait(function() return S.screen == "ride" end, 120), S.screen)
check("roaming", V.mode == "roam")
F.keys[KEY_W] = true; F.keys[KEY_A] = true; frames(60 * 4); F.keys[KEY_W] = nil; F.keys[KEY_A] = nil
check("riding and steering in roam", Ride.s > 5 and V.heading > 100, string.format("%.0f m, heading %.0f", Ride.s, V.heading))
F.keys[KEY_ESCAPE] = true; hook.Run("OnPauseMenuShow"); frames(2); F.keys[KEY_ESCAPE] = nil; frames(2)
check("'Main menu' from roam's pause", choose("menu") and S.screen == "title", S.screen)

-- the developer commands still work
F.run("ta_ride", "alpe-dhuez")
frames(2)
check("ta_ride starts a ride through the screens", S.screen == "loading" or S.screen == "ride", S.screen)
F.run("ta_stop"); frames(2)
check("ta_stop goes back to the title", S.screen == "title", S.screen)

oldprint(#F.errors == 0 and "no Lua errors" or ("Lua errors: " .. table.concat(F.errors, "\n  ")))
oldprint((bad == 0 and #F.errors == 0) and "OK" or ("FAILED: " .. bad .. " checks"))
os.execute('rm -rf "' .. DATA .. '"')
