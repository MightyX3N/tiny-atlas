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
  r.title, r.gpx, r.rid = g.name or id, g, route_lib.id(g.points)
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
    { "ride", "Ride a route" }, { "shared", "Shared routes" }, { "roam", "Roam" }, { "my", "My routes" },
    { "friends", "Friends" }, { "kit", "Your kit" }, { "trainer", "Trainer" }, { "settings", "Settings" }, { "quit", "Quit" },
  }
  local y = 70
  for _, it in ipairs(items) do
    if UI.menu_item(it[1], it[2], 24, y, 132) then
      if it[1] == "ride" then S.go("routes")
      elseif it[1] == "roam" then S.go("roam")
      elseif it[1] == "my" then S.go("myroutes")
      elseif it[1] == "trainer" then S.go("trainer")
      elseif it[1] == "kit" then S.go("kit")
      elseif it[1] == "shared" then S.go("shared")
      elseif it[1] == "friends" then S.go("friends")
      elseif it[1] == "settings" then S.back_to = "title"; S.go("settings")
      elseif it[1] == "quit" then S.quit() end
    end
    y = y + 20
  end
  -- the chosen route, and starting it
  local r = S.route_info(cv_last:GetString())
  local px, pw = UI.W - 218, 202
  route_card(r, px, 64, pw)
  if r and r.state ~= "failed" and UI.button("start", "Start ride", px + pw - 86, 200, 86, "go") then S.ride(r.id) end
  S.board_line(r, px, 224, pw)
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
  -- the focused route's card (and the last one focused while the focus is on its buttons)
  local fr
  local key = own and "own" or "routes"
  for i, r in ipairs(list) do if UI.focused(key .. ":" .. i) then fr = r end end
  S.picked = S.picked or {}
  if fr then S.picked[key] = fr.id end
  if not fr then for _, r in ipairs(list) do if r.id == S.picked[key] then fr = r end end end
  fr = fr or list[1]
  if fr then
    route_card(fr, UI.W - 218, 64, 202, "Route")
    if UI.button("start", "Start ride", UI.W - 104, 200, 86, "go") then S.ride(fr.id) end
    if own and fr.rid and TinyAtlas.Online.enabled() and UI.button("share", "Share", UI.W - 218, 200, 70) then
      S.share_route = fr; S.share_state = nil; S.go("share")
    end
    S.board_line(fr, UI.W - 218, 224, 202)
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

-- ---- your kit: made from a number (roll a new one), parts of it fixed, your rider's looks ----
local function kit_cv(name, v)
  local c = TinyAtlas.Rider.cv[name]
  RunConsoleCommand(c:GetName(), tostring(v)); c:SetString(tostring(v))
end
local function cap(n) return (n:gsub("_", " "):gsub("^%l", string.upper)) end
local function colour_name(c)
  if not c then return nil end
  if c.name then return c.name end
  for _, e in ipairs(TinyAtlas.Rider.Kit.COLOURS) do if e[2] == c[1] and e[3] == c[2] and e[4] == c[3] then return e[1] end end
end
-- a part of the kit, fixed (a choice) or left to the kit's number ("any", showing what the number gives now)
local function kit_part(id, label, key, list, K, locks, x, y, w)
  local cur = K[key]
  local now = type(cur) == "table" and (colour_name(cur) or "custom") or tostring(cur)
  local value = locks[key] ~= nil and (type(locks[key]) == "table" and (colour_name(locks[key]) or "custom") or tostring(locks[key])) or "any"
  local choices = { false }
  for _, c in ipairs(list) do
    choices[#choices + 1] = { c[1], cap(c[2] or c[1]) }
    if c[1] == now then now = c[2] or c[1] end
  end
  choices[1] = { "any", "Any: " .. cap(now) }
  local v, ch = UI.setting(id, label, value, choices, x, y, w)
  if ch then
    if v == "any" then locks[key] = nil
    elseif key == "pattern" or key == "sleeves" then locks[key] = v
    else
      for _, e in ipairs(TinyAtlas.Rider.Kit.COLOURS) do if e[1] == v then locks[key] = { e[2], e[3], e[4] } end end
    end
    kit_cv("locks", TinyAtlas.Rider.write_locks(locks))
  end
end
S.kit_history = S.kit_history or {}
function draw.kit()
  local RD = TinyAtlas.Rider
  local Kit = RD.Kit
  local K = RD.local_kit()
  local seed = RD.cv.seed:GetInt()
  header("Your kit", "Every kit comes from a number: roll one, keep the parts you like")
  -- what it is, and its colours
  UI.panel(18, 64, 150, 34)
  UI.text(UI.fit(cap(Kit.describe(K)), "M1", 140), 24, 68, "M1", C.text)
  local sw = { K.jersey, K.accent, K.accent2, K.shorts, K.socks, K.shoes }
  for i, c in ipairs(sw) do
    UI.rect(24 + (i - 1) * 14, 81, 12, 12, C.edge)
    UI.rect(25 + (i - 1) * 14, 82, 10, 10, Color(c[1], c[2], c[3]))
  end
  local px, pw = UI.W - 218, 202
  UI.panel(px, 60, pw, 168)
  local function roll(to)
    kit_cv("seed", to)
  end
  if UI.button("roll", "New kit", px + 6, 64, 92, "go") or (UI.pressed.SPACE and not UI.focused("kit_seed")) then
    S.kit_history[#S.kit_history + 1] = seed
    local n
    repeat n = math.random(1, 2000000000) until n ~= seed
    roll(n)
  end
  if #S.kit_history > 0 and UI.button("undo", "Last one", px + 104, 64, 92) then
    roll(table.remove(S.kit_history))
  end
  -- the number, to share or type in
  UI.text("Kit number", px + 8, 87, "M1", C.dim)
  local typing = UI.focused("kit_seed")
  if not typing then S.kit_text = tostring(RD.cv.seed:GetInt()) end
  local before = S.kit_text
  S.kit_text = UI.textfield("kit_seed", (S.kit_text or ""):gsub("%D", ""):sub(1, 10), px + 70, 84, pw - 76, "a number")
  local typed = tonumber(S.kit_text)
  if typing and S.kit_text ~= before and typed and typed >= 1 and typed <= 2147483646 then roll(floor(typed)) end
  local locks = RD.parse_locks(RD.cv.locks:GetString())
  local y = 106
  local pats = {}
  for _, p in ipairs(Kit.PATTERNS) do pats[#pats + 1] = { p[1] } end
  local cols = {}
  for _, c in ipairs(Kit.COLOURS) do cols[#cols + 1] = { c[1] } end
  kit_part("k_pattern", "Pattern", "pattern", pats, K, locks, px + 4, y, pw - 8); y = y + 20
  kit_part("k_jersey", "Jersey", "jersey", cols, K, locks, px + 4, y, pw - 8); y = y + 20
  kit_part("k_accent", "Pattern colour", "accent", cols, K, locks, px + 4, y, pw - 8); y = y + 20
  kit_part("k_sleeves", "Sleeves", "sleeves", { { "jersey", "jersey" }, { "accent", "pattern" } }, K, locks, px + 4, y, pw - 8); y = y + 20
  local v, ch = UI.setting("k_skin", "Skin", RD.cv.skin:GetInt(), { min = 1, max = #Kit.SKINS, step = 1, fmt = "%d" }, px + 4, y, pw - 8)
  if ch then kit_cv("skin", v) end
  y = y + 20
  v, ch = UI.setting("k_hair", "Hair", RD.cv.hair:GetInt(), { min = 1, max = #Kit.HAIRS, step = 1, fmt = "%d" }, px + 4, y, pw - 8)
  if ch then kit_cv("hair", v) end
  back_button("title")
  hint("Space: new kit   Left / right: fix a part   Esc: back")
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

-- a route's leaderboard in one line: the best time, and your place (from the online service, when there is one)
function S.board_line(r, x, y, w)
  local On = TinyAtlas.Online
  if not r or not r.rid or not On.enabled() then return end
  local b = On.route(r.rid, S.source())
  UI.panel(x, y, w, 17)
  if not b then
    UI.text(On.online == false and "Leaderboard: offline" or "Leaderboard...", x + 6, y + 3, "M1", C.dim)
    return
  end
  local best = b.board and b.board[1]
  local left = best and string.format("Best %s  %s", UI.clock(best.time), UI.fit(best.name, "M1", 70)) or "No times yet: be the first"
  UI.text(left, x + 6, y + 3, "M1", best and C.text or C.dim)
  if b.me then UI.text(string.format("you %d of %d", b.me.rank, b.riders or 0), x + w - 6, y + 3, "M1", C.sign, "right")
  elseif (b.riders or 0) > 0 then UI.text(string.format("%d riders", b.riders), x + w - 6, y + 3, "M1", C.dim, "right") end
end

-- ---- sharing one of your routes ----
function draw.share()
  UI.fade_left(UI.W, 0.55)
  local r = S.share_route
  header("Share a route", r and r.title or "")
  local x, y, w = 18, 64, 300
  UI.panel(x, y, w, 96)
  UI.text("Everyone will be able to ride it, with its leaderboard.", x + 8, y + 6, "M1", C.text)
  UI.text("Before it goes up, the first and last 300 m are cut off (where", x + 8, y + 20, "M1", C.dim)
  UI.text("a ride often starts: your home), and only the track is kept:", x + 8, y + 31, "M1", C.dim)
  UI.text("no times, heart rate or device.", x + 8, y + 42, "M1", C.dim)
  S.share_mine = UI.setting("share_mine", "This is my own route", S.share_mine or "no", { { "no", "No" }, { "yes", "Yes" } }, x + 4, y + 60, w - 8)
  if S.share_state then UI.text(S.share_state, x + 8, y + 82, "M1", S.share_ok and C.green or C.sign) end
  if S.share_mine == "yes" and r and not S.share_busy and UI.button("share_go", "Share it", x + w - 90, y + 104, 90, "go") then
    local pts = route_lib.trim(r.gpx.points, 300)
    local gpx = route_lib.to_gpx(r.title, pts)
    local rid = route_lib.id(route_lib.parse_gpx(gpx).points)
    S.share_busy, S.share_state, S.share_ok = true, "Sharing...", false
    TinyAtlas.Online.call("share", { gpx = gpx, name = r.title, route = rid }, function(res, err)
      S.share_busy = false
      if res then
        S.share_ok = true
        S.share_state = res.already and "It was shared already." or "Shared! It is in Shared routes now."
        -- the shared (cut) version is the one everyone rides: keep it, so your rides count on its leaderboard
        file.CreateDir("tinyatlas/shared")
        file.Write("tinyatlas/shared/" .. res.route .. ".gpx", gpx)
        S.list_t = 0
      else S.share_state = "Could not share it: " .. tostring(err) end
    end)
  end
  back_button("myroutes")
  hint("Left / right: change   Esc: back")
end

-- ---- shared routes: from the online service, downloaded when you ride one ----
S.shared_sort = S.shared_sort or "popular"
function S.fetch_shared()
  S.shared_state = "loading"
  TinyAtlas.Online.call("routes", { sort = S.shared_sort }, function(res, err)
    if res then S.shared_list, S.shared_state = res.routes or {}, "ready"
    else S.shared_state, S.shared_err = "failed", err end
  end)
end
function S.ride_shared(rid, cb)
  local id = "shared/" .. rid
  if V.read_gpx(id) then S.list_t = 0; return S.ride(id) end
  S.shared_dl = rid
  TinyAtlas.Online.call("route_gpx", { route = rid }, function(res, err)
    S.shared_dl = nil
    if not res then S.shared_err = err; return end
    file.CreateDir("tinyatlas/shared")
    file.Write("tinyatlas/shared/" .. rid .. ".gpx", res.gpx)
    S.list_t = 0
    S.ride(id)
  end)
end
function draw.shared()
  UI.fade_left(UI.W, 0.45)
  header("Shared routes", "Routes other riders shared: ride one and race their ghosts")
  local On = TinyAtlas.Online
  if not On.enabled() then
    UI.panel(18, 64, 300, 40)
    UI.text("Online is off (Settings), or there is no online service.", 26, 72, "M1", C.dim)
    back_button("title"); return
  end
  if not S.shared_state then S.fetch_shared() end
  local v, ch = UI.setting("shared_sort", "Show", S.shared_sort, { { "popular", "Most ridden" }, { "new", "Newest" } }, 18, 62, 200)
  if ch then S.shared_sort = v; S.fetch_shared() end
  local list = S.shared_list or {}
  if S.shared_state == "loading" then UI.text("Getting the routes...", 22, 86, "M1", C.dim)
  elseif S.shared_state == "failed" then UI.text("Could not get them: " .. tostring(S.shared_err), 22, 86, "M1", C.red)
  elseif #list == 0 then UI.text("Nobody has shared a route yet. Share yours from My routes.", 22, 86, "M1", C.dim) end
  local chosen = UI.list("shared", list, 18, 84, 200, 140, 20, function(r, x, y, w, h, f)
    if f then UI.sign(x, y + 1, w, h - 2, C.sign, C.signDark) else UI.panel(x, y + 1, w - 8, h - 2) end
    UI.text(UI.fit(r.name or "Route", "M2", w - 64), x + 5, y + 3, "M2", f and C.ink or C.text)
    local km, ku = UI.km(r.length or 0)
    UI.text(km .. " " .. ku, x + w - 14, y + 6, "M1", f and C.ink or C.dim, "right")
  end)
  local fr
  for i, r in ipairs(list) do if UI.focused("shared:" .. i) then fr = r end end
  fr = fr or list[1]
  if fr then
    local px, pw = UI.W - 218, 202
    UI.panel(px, 64, pw, 92)
    UI.text("Shared route", px + 8, 69, "M1", C.dim)
    UI.text(UI.fit(fr.name or "Route", "J1", pw - 16), px + 8, 79, "J1", C.text)
    local km, ku = UI.km(fr.length or 0)
    local cl, cu = UI.height(fr.climb or 0)
    UI.text(km, px + 8, 101, "J1", C.sign); UI.text(ku, px + 10 + UI.textw(km, "J1"), 107, "M1", C.text)
    UI.text(cl, px + 78, 101, "J1", C.sign); UI.text(cu .. " up", px + 80 + UI.textw(cl, "J1"), 107, "M1", C.text)
    UI.text(string.format("%d rides   shared by %s", fr.rides or 0, UI.fit(fr.owner or "someone", "M1", 90)), px + 8, 128, "M1", C.dim)
    if S.shared_dl then UI.text("Downloading...", px + 8, 142, "M1", C.sign) end
    if UI.button("ride_shared", "Ride it", px + pw - 86, 162, 86, "go") then S.ride_shared(fr.id) end
    S.board_line({ rid = fr.id }, px, 186, pw)
  end
  if chosen then S.ride_shared(list[chosen].id) end
  back_button("title")
  hint("Enter: ride it   Esc: back")
end

-- ---- friends: your code, adding theirs, riding with them ----
function draw.friends()
  UI.fade_left(UI.W, 0.5)
  header("Friends", "Add friends by their code, and ride with them when they ride")
  local On = TinyAtlas.Online
  local x, y, w = 18, 64, 210
  if not On.enabled() then
    UI.panel(x, y, 300, 40)
    UI.text("Online is off (Settings), or there is no online service.", x + 8, y + 8, "M1", C.dim)
    back_button("title"); return
  end
  if not On.id and not S.hello_asked then S.hello_asked = true; On.hello() end
  if not S.friends_t or RealTime() > S.friends_t then S.friends_t = RealTime() + 20; On.friends_now() end
  UI.panel(x, y, w, 112)
  UI.text("Your name", x + 8, y + 5, "M1", C.dim)
  if UI.text_focus ~= "my_name" then S.name_text = On.my_name() end
  local nt = UI.textfield("my_name", (S.name_text or ""):sub(1, 24), x + 8, y + 15, w - 16, "Rider")
  if nt ~= S.name_text then S.name_text = nt; RunConsoleCommand("ta_name", nt); On.cv.name:SetString(nt); S.name_dirty = true end
  UI.text("Your friend code", x + 8, y + 38, "M1", C.dim)
  UI.text(On.id or (On.last_error and "offline" or "..."), x + 8, y + 47, "J1", C.sign)
  UI.text("Add a friend's code", x + 8, y + 68, "M1", C.dim)
  S.add_code = UI.textfield("add_code", (S.add_code or ""):upper():gsub("[^A-Z0-9]", ""):sub(1, 8), x + 8, y + 78, w - 76, "CODE")
  if #S.add_code == 8 and UI.button("add_friend", "Add", x + w - 62, y + 77, 54, "sign") then
    On.call("friend_add", { code = S.add_code }, function(res, err)
      if res then On.friends, S.add_note = res.friends, "Added " .. res.friend.name; S.add_code = ""
      else S.add_note = tostring(err) end
    end)
  end
  if S.add_note then UI.text(UI.fit(S.add_note, "M1", w - 16), x + 8, y + 99, "M1", C.dim) end
  -- the list
  local list = On.friends or {}
  local lx = UI.W - 218
  if #list == 0 then UI.panel(lx, y, 202, 30); UI.text("No friends added yet.", lx + 8, y + 10, "M1", C.dim) end
  local chosen = UI.list("friend", list, lx, y, 202, 150, 26, function(f, x2, y2, w2, h2, foc)
    if foc then UI.sign(x2, y2 + 1, w2, h2 - 2, C.sign, C.signDark) else UI.panel(x2, y2 + 1, w2 - 8, h2 - 2) end
    UI.text(UI.fit(f.name, "M2", w2 - 20), x2 + 5, y2 + 1, "M2", foc and C.ink or C.text)
    local where = f.riding and (f.route_name and ("riding " .. f.route_name) or "riding in roam") or "not riding"
    UI.text(UI.fit(where, "M1", w2 - 20), x2 + 6, y2 + 15, "M1", foc and C.ink or (f.riding and C.green or C.dim))
  end)
  if chosen then
    local f = list[chosen]
    if f.riding and f.route then
      -- ride their route (yours, a game route or a shared one), and connect to their game if they host
      S.join_addr = f.addr
      local found
      for _, r in ipairs(S.list()) do if r.rid == f.route then found = r end end
      if found then S.ride(found.id) else S.ride_shared(f.route) end
      if f.addr and TinyAtlas.Live then TinyAtlas.Live.join(f.addr) end
    elseif f.riding and f.addr and TinyAtlas.Live then
      TinyAtlas.Live.join(f.addr)
      S.add_note = "Connecting to " .. f.name .. " (start Roam near them)"
    end
  end
  if back_button("title") and S.name_dirty then S.name_dirty = nil; On.hello() end
  hint("Enter on a friend who rides: ride with them   Esc: back")
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
  -- online
  local On, Live = TinyAtlas.Online, TinyAtlas.Live
  local ox, ow = UI.W - 186, 172
  local oy = 60
  UI.panel(ox - 4, oy - 4, ow + 8, 132)
  local onoff = { { 1, "On" }, { 0, "Off" } }
  v, ch = UI.setting("online", "Online", On.cv.on:GetBool() and 1 or 0, onoff, ox, oy, ow)
  if ch then RunConsoleCommand("ta_online", tostring(v)); On.cv.on:SetString(tostring(v)); if v == 1 then On.hello() end end
  v, ch = UI.setting("visible", "Ride with others", On.cv.visible:GetBool() and 1 or 0, onoff, ox, oy + 22, ow)
  if ch then RunConsoleCommand("ta_visible", tostring(v)); On.cv.visible:SetString(tostring(v)) end
  local status
  if TINYATLAS_LOVE then
    v, ch = UI.setting("host", "Host (playit.gg)", Live.cv_host:GetBool() and 1 or 0, { { 0, "Off" }, { 1, "On" } }, ox, oy + 44, ow)
    if ch then RunConsoleCommand("ta_host", tostring(v)); Live.cv_host:SetString(tostring(v)); Live.host(v == 1) end
    local P = Live.playit()
    local st = P and P.state or "off"
    status = ({ off = "Not hosting: you join riders who host", download = "Getting playit...",
      claim = "Approve Tiny Atlas on the playit page that opened", starting = "Starting playit...",
      ready = "Others can reach you: " .. tostring(P and P.addr), unsupported = tostring(P and P.err),
      failed = "playit: " .. tostring(P and P.err) })[st]
  else
    status = "Riding live: with the players on this server"
  end
  local service = not On.enabled() and (On.cv.on:GetBool() and "No online service set" or "Online is off")
    or On.online == false and "Can't reach the online service" or On.id and ("Online as " .. On.my_name() .. " (" .. On.id .. ")")
    or "Connecting..."
  UI.text(UI.fit(service, "M1", ow), ox, oy + 70, "M1", On.online == false and C.sign or C.dim)
  local lines, line = {}, ""
  for word in tostring(status or ""):gmatch("%S+") do
    if UI.textw(line .. " " .. word, "M1") > ow and line ~= "" then lines[#lines + 1] = line; line = word
    else line = line == "" and word or (line .. " " .. word) end
  end
  lines[#lines + 1] = line
  for i, l in ipairs(lines) do if i <= 3 then UI.text(l, ox, oy + 82 + (i - 1) * 10, "M1", C.dim) end end
  local P = Live.playit and Live.playit()
  if P and P.state == "claim" and P.claim_url then UI.text(UI.fit(P.claim_url, "M1", ow), ox, oy + 114, "M1", C.sign) end
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
    -- the others on the road: ghosts of this route (or computer riders); none in roam
    local OT = TinyAtlas.Others
    if V.mode == "ride" then OT.start(V.route_id, S.source()) else OT.stop() end
  end
  if UI.pressed.ESCAPE then V.Stop(); S.go("title") end
end

function draw.ride()
  if TinyAtlas.HUD then TinyAtlas.HUD.draw() end
  -- the finish
  if V.mode == "ride" and V.R and V.s >= V.R.length - 1 then
    Ride.mode = "paused"
    S.result = S.snapshot()
    S.result.online = TinyAtlas.Others.finish()
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

-- how this ride counts on the leaderboards: on a trainer, or with the keys (their own boards)
function S.source()
  local T = Ride.trainer
  return T and T:device() and "trainer" or "keys"
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
  local on = r.online
  if on and on.time then
    local msg, col = nil, C.text
    if on.state == "sending" then msg = "Sending your ride to the leaderboard..."
    elseif on.state == "sent" then
      msg = string.format("Leaderboard: %d of %d%s", on.rank or 0, on.riders or 0, on.best and "  - your best!" or ""); col = C.green
    elseif on.state == "failed" then msg = "Not on the leaderboard: " .. tostring(on.err); col = C.sign
    elseif on.new_own_best then msg = "Your best on this route: saved as your ghost" end
    if on.new_own_best and on.state == "sent" then msg = msg .. "  (and your ghost)" end
    if msg then UI.stext(msg, 18, y + 144, "M1", col) end
  end
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
  V.kit_view = scr == "kit"
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
