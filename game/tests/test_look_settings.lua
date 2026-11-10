-- The pixel-art look's settings in the fake GMod with the real gamemode files: the player's own values, an asset
-- pack fixing or moving them (its look table), and the settings window (ta_settings / F1) with its sliders.
--   luajit.py test_look_settings.lua
local here = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local PACK = here .. "../../packs/tinyatlas_pack_default"
local DATA = os.tmpname() .. "_gmdata"
os.execute('mkdir -p "' .. DATA .. '/tinyatlas"')
local F = dofile(here .. "fakegmod.lua")(DATA, here .. "../gamemodes/tinyatlas/gamemode")
dofile(here .. "fakegmod_render.lua")(F, { lua_roots = { here .. "../gamemodes", PACK .. "/lua" },
  material_roots = { PACK .. "/materials" }, screen = { 1280, 720 } })
GM = { FolderName = "tinyatlas" }
http = { Fetch = function(url, ok, fail) fail("offline test") end }
include("cl_init.lua")
local V = TinyAtlas.View
local bad = 0
local function check(what, got, want)
  local ok = math.abs(got - want) < 1e-6
  if not ok then bad = bad + 1 end
  print(string.format("%-58s %s  (%s, want %s)", what, ok and "ok" or "WRONG", tostring(got), tostring(want)))
end
check("pixel size by default", V.look_setting("pixelate"), 4)
check("outlines by default", V.look_setting("outlines"), 0.5)
F.set("ta_pixelate", 6); F.set("ta_outlines", 0.8)
check("player's pixel size", V.look_setting("pixelate"), 6)
check("pack forcing pixel size 1 (off)", V.look_setting("pixelate", { look = { pixelate = { force = 1 } } }), 1)
check("pack adding -2 to the pixel size", V.look_setting("pixelate", { look = { pixelate = { add = -2 } } }), 4)
check("pack adding +0.5 to outlines (kept within 0..1)", V.look_setting("outlines", { look = { outlines = { add = 0.5 } } }), 1)
check("pack forcing outlines off", V.look_setting("outlines", { look = { outlines = { force = 0 } } }), 0)
check("a pack without a look table", V.look_setting("outlines", { ground = {} }), 0.8)
F.set("ta_pixelate", 99)
check("player value out of range is kept within 1..8", V.look_setting("pixelate"), 8)
-- the window: from the command and from F1
F.run("ta_settings")
local frames, sliders = 0, {}
for _, p in ipairs(F.panels) do
  if p.class == "DFrame" then frames = frames + 1 end
  if p.class == "DNumSlider" then for _, c in ipairs(p.calls) do if c[1] == "SetConVar" then sliders[#sliders + 1] = c[2] end end end
end
check("settings window opened (ta_settings)", frames, 1)
print("sliders for: " .. table.concat(sliders, ", "))
if table.concat(sliders, ",") ~= "ta_pixelate,ta_outlines" then bad = bad + 1; print("WRONG sliders") end
local r = hook.Run("PlayerBindPress", nil, "gm_showhelp", true)
local open = 0
for _, p in ipairs(F.panels) do if p.class == "DFrame" and not p.removed then open = open + 1 end end
check("F1 opens it again (the old one closed)", open, 1)
check("F1 is taken by the window", r == true and 1 or 0, 1)
print(#F.errors == 0 and "no Lua errors" or ("Lua errors: " .. table.concat(F.errors, "; ")))
print((bad == 0 and #F.errors == 0) and "OK" or "FAILED")
