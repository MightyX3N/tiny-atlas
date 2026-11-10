-- The game's screens: title / main menu, route picker, roam picker, your own routes, trainer setup, settings, the
-- loading screen, the ride (cl_hud.lua), pause and results. Drawn with the UI kit (cl_ui.lua) over the world; the
-- menu's background is the chosen route ridden by itself. GMod and LÖVE run this same file.
TinyAtlas.Screens = TinyAtlas.Screens or {}
local S = TinyAtlas.Screens
local UI = TinyAtlas.UI
local V = TinyAtlas.View
local Ride = TinyAtlas.Ride
local C = UI.C
local route_lib = ATLAS_REQUIRE("route")
local profile_lib = ATLAS_REQUIRE("profile")
local floor, max, min = math.floor, math.max, math.min

S.screen = S.screen or "title"
S.back_to = S.back_to or "title"

local cv_last = CreateClientConVar("ta_last_route", "alpe-dhuez", true, false, "The route the main menu shows")
local cv_units = CreateClientConVar("ta_units", "metric", true, false, "Units: metric or imperial")

-- places to roam
S.PLACES = {
  { "Copenhagen, the lakes", 55.6810, 12.5600 }, { "Amsterdam, Dam square", 52.3731, 4.8925 },
  { "Berlin, Brandenburg Gate", 52.5163, 13.3777 }, { "Paris, the Seine", 48.8584, 2.2945 },
  { "London, Hyde Park", 51.5073, -0.1657 }, { "Alpe d'Huez, the village", 45.0918, 6.0700 },
  { "Rold Skov forest", 56.8000, 9.8600 }, { "New York, Central Park", 40.7812, -73.9665 },
  { "Kyoto, Kamo river", 35.0116, 135.7681 }, { "Lake Bled", 46.3625, 14.0938 },
}

-- ---- routes: names, lengths, climbs and profiles (worked out in the background, once) ----
S.routes = S.routes or {}
local info_queue, info_job = {}, nil
function S.route_info(id)
  local r = S.routes[id]
  if r then return r end
  r = { id = id, title = id, state = "reading" }
  S.routes[id] = r
  local text = V.read_gpx(id)
  if not text then r.state = "failed"; r.err = "file not found"; return r end
  local g, err = route_lib.parse_gpx(text)
  if not g then r.state = "failed"; r.err = err; return r end
  r.title, r.gpx = g.name or id, g
  local sum = profile_lib.cached(g, TinyAtlasFetch)
  if sum then r.sum, r.state = sum, "ready"
  else
    r.sum = route_lib.summary(g)         -- the length now, the heights when they are in
    r.state = "heights"
    info_queue[#info_queue + 1] = r
  end
  return r
end
local function pump_info()
  if info_job or #info_queue == 0 or not TinyAtlasJobs then return end
  local r = table.remove(info_queue, 1)
  info_job = TinyAtlasJobs.add(function(job)
    job.quiet = true
    job.where = "the height profile of " .. r.id
    local ok, res = pcall(profile_lib.of, r.gpx, TinyAtlasFetch, job.tick)
    if ok then r.sum, r.state = res, "ready" else r.state = "no heights"; r.err = tostring(res) end
    info_job = nil
  end)
end
function S.list()
  -- the folders are looked at every two seconds, not every frame
  local now = RealTime()
  if not S.list_cache or now > S.list_t then S.list_cache, S.list_t = V.list_routes(), now + 2 end
  local out = {}
  for _, e in ipairs(S.list_cache) do
    local r = S.route_info(e.id)
    r.own = e.own
    out[#out + 1] = r
  end
  return out
end

-- ---- moving between screens ----
function S.go(name)
  S.prev = S.screen
  S.screen = name
  UI.text_focus = nil
  if name == "title" or name == "routes" or name == "myroutes" or name == "roam" or name == "trainer" then
    S.background()
  end
end
-- the menu's background: the chosen route, ridden by itself
function S.background()
  local id = cv_last:GetString()
  if V.read_gpx(id) then V.Preview(id) end
end
function S.ride(id)
  RunConsoleCommand("ta_last_route", id)
  cv_last:SetString(id)
  V.paused = false
  if V.RideRoute(id) then S.go("loading") end
end
function S.roam(lat, lon)
  V.Stop()
  V.paused = false
  if V.StartRoam(lat, lon) then S.go("loading") end
end
function S.failed(err)
  S.error = tostring(err)
  S.screen = "title"
end

-- ---- pieces ----
local function title_block()
  UI.stext("Tiny Atlas", 18, 18, "J2", C.sign)
  UI.stext("Ride the real world, anywhere.", 19, 52, "M1", C.text)
end
local function hint(text) UI.text(text, 18, UI.H - 16, "M1", C.dim) end
local function header(text, sub)
  UI.stext(text, 18, 14, "J2", C.sign)
  if sub then UI.stext(sub, 19, 48, "M1", C.text) end
end
-- a route's card: name, facts, the profile
local function route_card(r, x, y, w, label)
  local h = 128
  UI.panel(x, y, w, h)
  UI.text(label or "Next ride", x + 8, y + 5, "M1", C.dim)
  UI.text(UI.fit(r and r.title or "No route", "J1", w - 16), x + 8, y + 15, "J1", C.text)
  if not r then return end
  if r.own then UI.text("your own route", x + 8, y + 35, "M1", C.dim) end
  local sum = r.sum
  if sum then
    local km, ku = UI.km(sum.length)
    local facts = { { km, ku } }
    if sum.heights then
      local cl, cu = UI.height(sum.climb)
      facts[#facts + 1] = { cl, cu .. " up" }
      if sum.length > 0 then facts[#facts + 1] = { string.format("%.1f", sum.climb / sum.length * 100), "% avg" } end
    end
    for i, f in ipairs(facts) do
      local fx = x + 8 + (i - 1) * floor((w - 16) / 3)
      UI.text(f[1], fx, y + 47, "J1", C.sign)
      UI.text(f[2], fx + UI.textw(f[1], "J1") + 3, y + 53, "M1", C.text)
    end
    if sum.heights then
      UI.profile(sum.profile, x + 8, y + 74, w - 16, 34)
      UI.rect(x + 8, y + 108, w - 16, 1, C.edge)
      local lo, lu = UI.height(sum.low)
      local hi, hu = UI.height(sum.high)
      UI.text(lo .. " " .. lu, x + 8, y + 111, "M1", C.dim)
      UI.text(hi .. " " .. hu, x + w - 8, y + 111, "M1", C.dim, "right")
    else
      UI.text(r.state == "heights" and "Getting the heights..." or "No height data", x + 8, y + 84, "M1", C.dim)
    end
  elseif r.state == "failed" then
    UI.text("Can't read this file: " .. tostring(r.err), x + 8, y + 50, "M1", C.red)
  end
end
-- the trainer's state, bottom right
local function trainer_chip()
  local T = Ride.trainer
  local d = T and T:device()
  local text, col
  if d then
    local kind = d.device and d.device.kind or "bike"
    text = string.format("%s connected   %d W", kind == "bike" and "Trainer" or "Treadmill", floor(d.power or 0))
    col = C.green
  elseif OmniPlay and OmniPlay.IsConnected and OmniPlay.IsConnected() then
    text, col = "OmniPlay: no machine paired", C.sign
  else
    text, col = "Keyboard: W ride, Shift sprint", C.dim
  end
  local w = UI.textw(text, "M1") + 18
  UI.panel(UI.W - w - 10, UI.H - 24, w, 15)
  UI.rect(UI.W - w - 3, UI.H - 18, 4, 4, col)
  UI.text(text, UI.W - w + 5, UI.H - 21, "M1", C.text)
end
local function back_button(to)
  if UI.button("back", "Back", 18, UI.H - 42, 70) or UI.pressed.ESCAPE then S.go(to or "title"); return true end
end

-- ---- the screens ----
local draw = {}

function draw.title()
  UI.fade_left(190, 0.62)
  title_block()
  local items = {
    { "ride", "Ride a route" }, { "roam", "Roam" }, { "my", "My routes" }, { "trainer", "Trainer" },
    { "settings", "Settings" }, { "quit", "Quit" },
  }
  local y = 76
  for _, it in ipairs(items) do
    if UI.menu_item(it[1], it[2], 24, y, 132) then
      if it[1] == "ride" then S.go("routes")
      elseif it[1] == "roam" then S.go("roam")
      elseif it[1] == "my" then S.go("myroutes")
      elseif it[1] == "trainer" then S.go("trainer")
      elseif it[1] == "settings" then S.back_to = "title"; S.go("settings")
      elseif it[1] == "quit" then S.quit() end
    end
    y = y + (UI.focused(it[1]) and 25 or 21)
  end
  -- the chosen route, and starting it
  local r = S.route_info(cv_last:GetString())
  local px, pw = UI.W - 218, 202
  route_card(r, px, 64, pw)
  if r and r.state ~= "failed" and UI.button("start", "Start ride", px + pw - 86, 200, 86, "go") then S.ride(r.id) end
  if S.error then UI.text("Something went wrong: " .. S.error:sub(1, 70), 18, UI.H - 30, "M1", C.red) end
  hint("Arrow keys or mouse  -  Enter to choose")
  trainer_chip()
end

local function routes_screen(own)
  UI.fade_left(UI.W, 0.45)
  header(own and "My routes" or "Ride a route", own and "Your own GPX files" or "Pick a route to ride")
  local list = {}
  for _, r in ipairs(S.list()) do if (r.own == true) == own then list[#list + 1] = r end end
  local lx, ly, lw = 18, 64, 200
  if #list == 0 then
    UI.panel(lx, ly, lw + 230, 74)
    UI.text("No routes of your own yet.", lx + 8, ly + 6, "M2", C.text)
    UI.text("Put .gpx files (from Strava, Komoot, Garmin...) in:", lx + 8, ly + 26, "M1", C.dim)
    UI.text(S.gpx_folder(), lx + 8, ly + 38, "M1", C.sign)
    UI.text("They show up here by themselves.", lx + 8, ly + 52, "M1", C.dim)
  end
  local chosen = UI.list(own and "own" or "routes", list, lx, ly, lw, 160, 20, function(r, x, y, w, h, f)
    if f then UI.sign(x, y + 1, w, h - 2, C.sign, C.signDark) else UI.panel(x, y + 1, w - 8, h - 2) end
    local col = f and C.ink or C.text
    UI.text(UI.fit(r.title, "M2", w - 64), x + 5, y + 3, "M2", col)
    if r.sum then
      local km, ku = UI.km(r.sum.length)
      UI.text(km .. " " .. ku, x + w - 14, y + 6, "M1", f and C.ink or C.dim, "right")
    end
  end)
  -- the focused route's card
  local fr
  for i, r in ipairs(list) do if UI.focused((own and "own" or "routes") .. ":" .. i) then fr = r end end
  fr = fr or list[1]
  if fr then
    route_card(fr, UI.W - 218, 64, 202, "Route")
    if UI.button("start", "Start ride", UI.W - 104, 200, 86, "go") then S.ride(fr.id) end
  end
  if chosen then S.ride(list[chosen].id) end
  back_button("title")
  hint("Enter: ride it   Esc: back")
  trainer_chip()
end
function draw.routes() routes_screen(false) end
function draw.myroutes() routes_screen(true) end

S.coords = S.coords or ""
function draw.roam()
  UI.fade_left(UI.W, 0.45)
  header("Roam", "Ride anywhere, no route: A and D steer")
  local chosen = UI.list("places", S.PLACES, 18, 64, 196, 144, 18, function(p, x, y, w, h, f)
    if f then UI.sign(x, y + 1, w, h - 2, C.sign, C.signDark) else UI.panel(x, y + 1, w - 8, h - 2) end
    UI.text(UI.fit(p[1], "M2", w - 22), x + 5, y + 2, "M2", f and C.ink or C.text)
  end)
  if chosen then local p = S.PLACES[chosen]; S.roam(p[2], p[3]) end
  local px = UI.W - 218
  UI.panel(px, 64, 202, 64)
  UI.text("Or a place by coordinates", px + 8, 69, "M1", C.dim)
  S.coords = UI.textfield("coords", S.coords, px + 8, 82, 186, "55.676, 12.568")
  local lat, lon = S.coords:match("^%s*([-%d%.]+)%s*[, ]%s*([-%d%.]+)%s*$")
  lat, lon = tonumber(lat), tonumber(lon)
  if lat and lon and math.abs(lat) <= 85 and math.abs(lon) <= 180 then
    if UI.button("go_coords", "Go there", px + 116, 104, 78, "go") then S.roam(lat, lon) end
  else
    UI.text("latitude, longitude", px + 8, 106, "M1", C.dim)
  end
  back_button("title")
  hint("Enter: ride there   Esc: back")
  trainer_chip()
end

function draw.trainer()
  UI.fade_left(UI.W, 0.5)
  header("Trainer", "A smart trainer or walking pad through OmniPlay, or the keyboard")
  local T = Ride.trainer
  local d = T and T:device()
  local x, y, w = 18, 64, 230
  UI.panel(x, y, w, 76)
  if d then
    local kind = d.device and d.device.kind or "bike"
    UI.text((kind == "bike" and "Bike trainer" or kind == "treadmill" and "Walking pad" or "Footpod") .. " connected", x + 8, y + 5, "M2", C.green)
    local cells = { { floor(d.power or 0), "W" }, { floor(d.cadence or 0), "rpm" }, { floor(d.hr or 0), "bpm" },
      { string.format("%.1f", d.speed_kmh or 0), "km/h" } }
    for i, c in ipairs(cells) do
      local cx = x + 8 + (i - 1) * 55
      UI.text(tostring(c[1]), cx, y + 26, "J1", C.sign)
      UI.text(c[2], cx, y + 48, "M1", C.dim)
    end
    UI.text(d.device and d.device.hills and "Hills go to the trainer" or "OmniPlay: allow \"Games may set hills\" for hills", x + 8, y + 62, "M1", C.dim)
  elseif OmniPlay and OmniPlay.IsConnected and OmniPlay.IsConnected() then
    UI.text("OmniPlay is running", x + 8, y + 5, "M2", C.sign)
    UI.text("Pair your trainer or walking pad in OmniPlay.", x + 8, y + 28, "M1", C.text)
  else
    UI.text("No trainer", x + 8, y + 5, "M2", C.text)
    UI.text("Start OmniPlay to ride with a smart trainer,", x + 8, y + 26, "M1", C.dim)
    UI.text("or ride with the keys:", x + 8, y + 38, "M1", C.dim)
    UI.text("W ride   Shift sprint   S brake", x + 8, y + 52, "M1", C.sign)
  end
  -- settings for the ride
  local sx, sy, sw = UI.W - 218, 64, 202
  UI.panel(sx, sy, sw, 84)
  local cv = Ride.cv
  local v, ch = UI.setting("difficulty", "Hills", cv.difficulty:GetFloat(), { min = 0, max = 100, step = 10, fmt = "%d %%" }, sx + 4, sy + 4, sw - 8)
  if ch then RunConsoleCommand("ta_trainer_difficulty", tostring(v)); cv.difficulty:SetFloat(v); S.trainer_dirty = true end
  v, ch = UI.setting("weight", "Your weight", cv.weight:GetFloat(), { min = 40, max = 150, step = 1, fmt = "%d kg" }, sx + 4, sy + 30, sw - 8)
  if ch then RunConsoleCommand("ta_rider_kg", tostring(v)); cv.weight:SetFloat(v); S.trainer_dirty = true end
  v, ch = UI.setting("bike", "Bike", cv.bike:GetString(), { { "road", "Road" }, { "mtb", "Mountain" }, { "bmx", "BMX" } }, sx + 4, sy + 56, sw - 8)
  if ch then RunConsoleCommand("ta_bike", v); cv.bike:SetString(v); S.trainer_dirty = true end
  UI.text("Hills: how much of each real hill the trainer gives you", sx, sy + 90, "M1", C.dim)
  if back_button("title") and S.trainer_dirty then Ride.make_trainer(); S.trainer_dirty = nil end
  hint("Left / right: change   Esc: back")
  trainer_chip()
end

-- the asset packs there are (lua/tinyatlas/packs/<id>.lua, not the files that come with one)
function S.packs()
  local out = {}
  for _, f in ipairs(file.Find("tinyatlas/packs/*.lua", "LUA") or {}) do
    local id = f:gsub("%.lua$", "")
    if not id:find("_") then out[#out + 1] = { id, id:sub(1, 1):upper() .. id:sub(2) } end
  end
  if #out == 0 then out[1] = { "default", "Default" } end
  return out
end

function draw.settings()
  UI.fade_left(UI.W, 0.55)
  header("Settings")
  local x, y, w = 18, 60, 260
  UI.panel(x - 4, y - 4, w + 8, 7 * 26 + 4)
  local function line(id, label, value, choices, note)
    local v, ch = UI.setting(id, label, value, choices, x, y, w, note)
    y = y + 26
    return v, ch
  end
  local LS = V.LOOK_SETTINGS
  local pv, pforced = V.look_setting("pixelate", V.pack)
  local v, ch = line("pixelate", "Pixel size", LS.pixelate.cv:GetFloat(), { min = 1, max = 8, step = 1, fmt = "%d" },
    pforced and "the asset pack sets this one" or "1 = off")
  if ch then RunConsoleCommand("ta_pixelate", tostring(v)); LS.pixelate.cv:SetFloat(v) end
  local _, oforced = V.look_setting("outlines", V.pack)
  v, ch = line("outlines", "Outlines", LS.outlines.cv:GetFloat(), { min = 0, max = 1, step = 0.1, fmt = "%.1f" },
    oforced and "the asset pack sets this one" or "0 = off")
  if ch then RunConsoleCommand("ta_outlines", tostring(v)); LS.outlines.cv:SetFloat(v) end
  v, ch = line("style", "World", V.cv.style:GetString(), { { "textured", "Textured" }, { "flat", "Flat colours" } })
  if ch then RunConsoleCommand("ta_style", v); V.cv.style:SetString(v); S.world_dirty = true end
  v, ch = line("pack", "Asset pack", V.cv.pack:GetString(), S.packs())
  if ch then RunConsoleCommand("ta_pack", v); V.cv.pack:SetString(v); S.world_dirty = true end
  v, ch = line("units", "Units", cv_units:GetString(), { { "metric", "km, m" }, { "imperial", "miles, ft" } })
  if ch then RunConsoleCommand("ta_units", v); cv_units:SetString(v) end
  v, ch = line("cam_back", "Camera distance", V.cv.back:GetFloat(), { min = 2, max = 30, step = 1, fmt = "%d m" })
  if ch then RunConsoleCommand("ta_cam_back", tostring(v)); V.cv.back:SetFloat(v) end
  v, ch = line("cam_up", "Camera height", V.cv.up:GetFloat(), { min = 1, max = 20, step = 1, fmt = "%d m" })
  if ch then RunConsoleCommand("ta_cam_up", tostring(v)); V.cv.up:SetFloat(v) end
  if S.world_dirty then UI.text("The world look changes from the next ride.", x, y + 4, "M1", C.sign) end
  if back_button(S.back_to) and S.world_dirty and S.back_to == "title" then
    S.world_dirty = nil
    V.Stop(); S.background()
  end
  hint("Left / right: change   Esc: back")
end

function draw.loading()
  local W = V.W
  UI.fade_left(UI.W, 0.35)
  local title = V.mode == "roam" and "Roam" or (V.route_title or "")
  UI.stext(title, floor(UI.W / 2), floor(UI.H / 2) - 44, "J1", C.text, "center")
  local done, total = 0, 1
  if W then local miss, tot = W:missing_near(300); done, total = tot - miss, max(tot, 1) end
  local bw = 220
  local bx, by = floor((UI.W - bw) / 2), floor(UI.H / 2) - 6
  UI.panel(bx - 3, by - 3, bw + 6, 16)
  UI.rect(bx, by, floor(bw * min(1, done / total)), 10, C.sign)
  UI.stext(string.format("Building the world around you: %d of %d", done, total), floor(UI.W / 2), by + 18, "M1", C.text, "center")
  if V.phase == "riding" and not V.paused then
    S.go("ride")
    Ride.mode = "ride"
    UI.text_focus = nil
  end
  if UI.pressed.ESCAPE then V.Stop(); S.go("title") end
end

function draw.ride()
  if TinyAtlas.HUD then TinyAtlas.HUD.draw() end
  -- the finish
  if V.mode == "ride" and V.R and V.s >= V.R.length - 1 then
    Ride.mode = "paused"
    S.result = S.snapshot()
    S.go("results")
  end
  if UI.pressed.ESCAPE then
    Ride.mode = "paused"; V.paused = true
    S.go("pause")
  end
end

function draw.pause()
  if TinyAtlas.HUD then TinyAtlas.HUD.draw() end
  UI.rect(0, 0, UI.W, UI.H, Color(10, 16, 22, 150))
  UI.stext("Paused", floor(UI.W / 2), 50, "J2", C.sign, "center")
  local x, y = floor(UI.W / 2) - 60, 100
  local function resume() Ride.mode = "ride"; V.paused = false; S.go("ride") end
  if UI.menu_item("resume", "Resume", x, y, 132) then resume() end
  y = y + (UI.focused("resume") and 25 or 21)
  if UI.menu_item("settings", "Settings", x, y, 132) then S.back_to = "pause"; S.go("settings") end
  y = y + (UI.focused("settings") and 25 or 21)
  if UI.menu_item("finish", "End the ride", x, y, 132) then S.result = S.snapshot(); S.go("results") end
  y = y + (UI.focused("finish") and 25 or 21)
  if UI.menu_item("menu", "Main menu", x, y, 132) then V.paused = false; V.Stop(); S.go("title") end
  if UI.pressed.ESCAPE then resume() end
end

-- the ride's numbers, kept for the results
function S.snapshot()
  local st = Ride.stats or {}
  local res = {
    title = V.mode == "roam" and "Roam" or (V.route_title or ""), time = st.time or 0, dist = st.dist or 0,
    climb = st.climb or 0, avg_power = (st.time or 0) > 0 and (st.energy or 0) / st.time or 0, max_power = st.max_power or 0,
    avg_hr = (st.hr_time or 0) > 0 and st.hr_sum / st.hr_time or nil, avg_cad = (st.cad_time or 0) > 0 and st.cad_sum / st.cad_time or nil,
    energy = st.energy or 0, finished = V.mode == "ride" and V.R and V.s >= V.R.length - 1, route = V.route_name,
  }
  local info = V.route_name and S.routes[V.route_name]
  res.profile = info and info.sum and info.sum.heights and info.sum.profile
  return res
end

function draw.results()
  local r = S.result or {}
  UI.rect(0, 0, UI.W, UI.H, Color(10, 16, 22, 170))
  UI.stext(r.finished and "Finished!" or "Ride over", 18, 14, "J2", C.sign)
  UI.stext(r.title or "", 19, 48, "M1", C.text)
  local x, y, w = 18, 64, UI.W - 36
  UI.panel(x, y, w, 132)
  local km, ku = UI.km(r.dist or 0, 2)
  local sp, su = UI.speed((r.time or 0) > 0 and r.dist / r.time or 0)
  local cl, cu = UI.height(r.climb or 0)
  local cells = {
    { km, ku, "distance" }, { UI.clock(r.time), "", "time" }, { sp, su, "average" },
    { cl, cu, "climbed" }, { tostring(floor(r.avg_power or 0)), "W", "average power" }, { tostring(floor(r.max_power or 0)), "W", "best power" },
    { r.avg_hr and tostring(floor(r.avg_hr)) or "-", r.avg_hr and "bpm" or "", "heart rate" },
    { string.format("%.0f", (r.energy or 0) / 1000 * 0.239 / 0.24), "kcal", "energy" },
  }
  for i, c in ipairs(cells) do
    local col, row = (i - 1) % 4, floor((i - 1) / 4)
    local cx, cy = x + 10 + col * floor((w - 20) / 4), y + 8 + row * 40
    UI.text(c[1], cx, cy, "J1", C.sign)
    if c[2] ~= "" then UI.text(c[2], cx + UI.textw(c[1], "J1") + 3, cy + 6, "M1", C.text) end
    UI.text(c[3], cx, cy + 22, "M1", C.dim)
  end
  if r.profile then UI.profile(r.profile, x + 10, y + 88, w - 20, 36, r.finished and math.huge or r.dist) end
  if r.route and UI.button("again", "Ride again", UI.W - 210, y + 140, 90, "go") then S.ride(r.route) end
  if UI.button("menu", "Main menu", UI.W - 112, y + 140, 94) or UI.pressed.ESCAPE then V.paused = false; V.Stop(); S.go("title") end
end

-- ---- every frame ----
function S.draw()
  UI.metrics()
  UI.imperial = cv_units:GetString() == "imperial"
  UI.read_input()
  pump_info()
  local scr = S.screen
  if not draw[scr] then scr = "title"; S.screen = scr end
  -- the mouse pointer while a menu is up; Esc belongs to the game's menus
  local menu = scr ~= "ride"
  if UI.cursor ~= menu then UI.cursor = menu; gui.EnableScreenClicker(menu) end
  UI.wants_escape = true
  if scr == "title" and not S.started then S.started = true; S.background() end
  UI.begin(scr)
  draw[scr]()
  UI.finish()
end

-- where the player's own GPX files go
function S.gpx_folder()
  if TINYATLAS_LOVE then return TINYATLAS_LOVE.save_folder .. "/tinyatlas/gpx/" end
  return "garrysmod/data/tinyatlas/gpx/"
end
function S.quit()
  if TINYATLAS_LOVE then TINYATLAS_LOVE.quit() else RunConsoleCommand("disconnect") end
end
file.CreateDir("tinyatlas/gpx")
