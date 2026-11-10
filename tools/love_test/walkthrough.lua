-- The standalone played through like a player, with the keys: the title screen and its route riding by itself, the
-- route list, a ride (keys, the ride screen with the other riders, pause, settings, results), my routes, trainer, shared
-- routes and friends (offline here), your kit, roam with steering.
-- Screenshots of every screen go to the out folder. Ends with OK or FAILED.
local L, R = ...
local T = dofile(os.getenv("TA_TEST_LIB"))(L, R, os.getenv("TA_TEST_OUT"))
local V, S, Ride, UI = TinyAtlas.View, TinyAtlas.Screens, TinyAtlas.Ride, TinyAtlas.UI
local bad = 0
local function check(what, ok, detail)
  if not ok then bad = bad + 1 end
  print(string.format("%-56s %s%s", what, ok and "ok" or "WRONG", detail and ("  (" .. detail .. ")") or ""))
end
local function esc() T.press("ESCAPE"); T.frames(3) end

T.until_(function() return V.phase == "riding" end, 120, "the menu's world")
T.seconds(2)
check("title screen", T.screen() == "title", T.screen())
local s0 = Ride.s; T.seconds(1)
check("the menu's route rides by itself", Ride.mode == "auto" and Ride.s > s0)
T.shot("01_title")
T.choose("ride")
check("route list", T.screen() == "routes", T.screen())
T.frames(10); T.shot("02_routes")
T.choose("routes:5")
T.shot("03_loading")
T.until_(function() return T.screen() == "ride" end, 180, "the ride to start")
check("riding Rold Skov", V.route_name == "rold-skov" and Ride.mode == "ride")
T.hold("W", true); T.seconds(5); T.hold("LSHIFT", true); T.seconds(3); T.hold("LSHIFT", false); T.hold("W", false)
check("riders on the road with you (computer riders: no online service here)", #TinyAtlas.Others.list > 0, #TinyAtlas.Others.list)
check("the keys ride", Ride.s > 20 and Ride.stats.time > 7, string.format("%.0f m in %.1f s", Ride.s, Ride.stats.time))
T.shot("04_ride")
esc(); check("pause", T.screen() == "pause", T.screen()); T.shot("05_pause")
local sp = Ride.s; T.seconds(1)
check("stands still while paused", math.abs(Ride.s - sp) < 1e-6)
T.choose("settings"); check("settings from pause", T.screen() == "settings", T.screen()); T.shot("06_settings")
local px = GetConVar("ta_pixelate"):GetFloat()
T.press("RIGHT"); check("pixel size up", GetConVar("ta_pixelate"):GetFloat() == px + 1); T.shot("07_settings_px5")
T.press("LEFT"); check("pixel size back", GetConVar("ta_pixelate"):GetFloat() == px)
esc(); check("back to pause", T.screen() == "pause", T.screen())
T.choose("finish"); check("results", T.screen() == "results", T.screen()); T.shot("08_results")
T.choose("menu"); check("main menu", T.screen() == "title", T.screen())
T.choose("my"); T.frames(10); check("my routes", T.screen() == "myroutes", T.screen()); T.shot("09_myroutes"); esc()
T.choose("trainer"); T.frames(5); check("trainer", T.screen() == "trainer", T.screen()); T.shot("10_trainer"); esc()
T.choose("shared"); T.frames(5); check("shared routes", T.screen() == "shared", T.screen()); T.shot("10d_shared"); esc()
T.choose("friends"); T.frames(5); check("friends", T.screen() == "friends", T.screen()); T.shot("10e_friends"); esc()
T.choose("kit"); T.frames(10); check("your kit", T.screen() == "kit", T.screen()); T.shot("10b_kit")
local k0 = GetConVar("ta_kit_seed"):GetInt()
T.choose("roll"); T.frames(10); check("a new kit", GetConVar("ta_kit_seed"):GetInt() ~= k0); T.shot("10c_kit_new")
esc()
T.choose("roam"); T.frames(5); check("roam", T.screen() == "roam", T.screen()); T.shot("11_roam")
T.choose("places:2")
T.until_(function() return T.screen() == "ride" end, 180, "roam to start")
T.hold("W", true); T.hold("A", true); T.seconds(4); T.hold("A", false); T.hold("W", false)
check("roam: riding and steering", Ride.s > 5 and V.heading > 100, string.format("%.0f m, heading %.0f", Ride.s, V.heading))
T.shot("12_roam_ride")
esc(); T.choose("menu"); check("back to the title", T.screen() == "title", T.screen())
print(bad == 0 and "OK" or ("FAILED: " .. bad .. " checks"))
love.event.quit()
