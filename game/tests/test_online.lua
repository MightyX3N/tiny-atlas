-- The online features in the fake GMod with the real gamemode files, against a running copy of the online service
-- (online/: npx wrangler dev). Played like a player: your friend code, adding a friend, a short route of your own
-- with another rider's ghost on it (and the game's computer riders on a route with none), riding it to the finish,
-- the leaderboard, your own best kept as a ghost, sharing the route, the shared routes list, and riding live with
-- another player on the same GMod server.
--   luajit.py test_online.lua <cache dir> <service URL>
local here = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local CACHE, URL = arg[1], arg[2] or "http://127.0.0.1:8787"
local PACK = here .. "../../packs/tinyatlas_pack_default"
local DATA = os.tmpname() .. "_gmdata"
os.execute('mkdir -p "' .. DATA .. '/tinyatlas/gpx" && ln -s "' .. CACHE .. '" "' .. DATA .. '/tinyatlas/cache"')
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

-- two short routes of the player's own, cut from the game's Rold Skov route: one another rider has ridden, one
-- nobody has
local route_lib = dofile(here .. "../gamemodes/tinyatlas/gamemode/atlas/route.lua")
local f = io.open(here .. "../gamemodes/tinyatlas/routes/rold-skov.gpx"); local full = f:read("*a"); f:close()
local pts = route_lib.parse_gpx(full).points
local function first_metres(m, from)
  local out, d = { pts[from] }, 0
  for i = from + 1, #pts do
    local p, q = pts[i], pts[i - 1]
    d = d + math.sqrt(((p[1] - q[1]) * 110540) ^ 2 + ((p[2] - q[2]) * 111320 * math.cos(math.rad(p[1]))) ^ 2)
    out[#out + 1] = p
    if d >= m then break end
  end
  return out, d
end
local short, short_len = first_metres(260, 1)
-- this run's own copy (a hair to the side): its own ID, so earlier runs' rides are not on its leaderboard
math.randomseed(os.time())
local shift = math.random(1, 900) * 1e-6
for i, p in ipairs(short) do short[i] = { p[1] + shift, p[2], p[3] } end
local quiet = first_metres(200, 1)
quiet[#quiet] = nil                          -- a different route (and ID) from the first
local function write(name, p) local g = io.open(DATA .. "/tinyatlas/gpx/" .. name .. ".gpx", "w"); g:write(route_lib.to_gpx(name, p)); g:close() end
write("short sprint", short)
write("quiet lane", quiet)
local rid = route_lib.id(route_lib.parse_gpx(route_lib.to_gpx("x", short)).points)

-- another rider ("Ghosty") has ridden it: their ride (and ghost) go to the service first
local json = dofile(here .. "../gamemodes/tinyatlas/gamemode/thirdparty/json.lua")
local function post(name, body)
  local tmp = os.tmpname()
  local g = io.open(tmp, "w"); g:write(json.encode(body)); g:close()
  local p = io.popen("curl -s -X POST -H 'Content-Type: application/json' --data-binary @" .. tmp .. " " .. URL .. "/v1/" .. name)
  local out = p:read("*a"); p:close(); os.remove(tmp)
  return json.decode(out)
end
local gkey = string.format("%032x", os.time()) .. "ghosty"
local secs = 40
local samples = {}
for i = 0, secs do samples[#samples + 1] = string.format("%.1f,%d,85", math.min(short_len, short_len * i / secs), 65) end
local gr = post("ride", { key = gkey, name = "Ghosty", kit = "4242||3|5", route = rid, time = secs, length = short_len,
  source = "keys", ghost = "v1;" .. table.concat(samples, ";") })
assert(gr and gr.ok, "seeding the other rider's ride: " .. json.encode(gr or {}))
local ghosty = post("hello", { key = gkey, name = "Ghosty" }).id

CreateClientConVar("ta_online_url", URL, true, false)
GetConVar("ta_online_url"):SetString(URL)
CreateClientConVar("ta_name", "Tester", true, false)
GetConVar("ta_name"):SetString("Tester")
include("cl_init.lua")
hook.Run("InitPostEntity")
local S, UI, V, Ride, On, OT, Live = TinyAtlas.Screens, TinyAtlas.UI, TinyAtlas.View, TinyAtlas.Ride, TinyAtlas.Online,
  TinyAtlas.Others, TinyAtlas.Live

local bad = 0
local function check(what, ok, detail)
  if not ok then bad = bad + 1 end
  oldprint(string.format("%-62s %s%s", what, ok and "ok" or "WRONG", detail and ("  (" .. tostring(detail) .. ")") or ""))
end
local function frame() F.tick(1 / 60); F.run_simple(); F.render_frame(1 / 60) end
local function frames(n) for _ = 1, n do frame() end end
local function press(k) F.keys[_G["KEY_" .. k]] = true; frames(2); F.keys[_G["KEY_" .. k]] = nil; frames(2) end
local function choose(id)
  for _ = 1, 30 do if UI.focused(id) then break end; press("DOWN") end
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
local function esc() F.keys[KEY_ESCAPE] = true; hook.Run("OnPauseMenuShow"); frames(2); F.keys[KEY_ESCAPE] = nil; frames(2) end

check("online: says hello and gets a friend code", wait(function() return On.id ~= nil end, 5), On.id)

-- friends
check("'Friends'", choose("friends") and S.screen == "friends", S.screen)
frames(5)
check("your friend code is shown", On.id and shown(On.id))
for _ = 1, 20 do if UI.focused("add_code") then break end; press("DOWN") end
S.add_code = ghosty
frames(3)
check("adding a friend by their code", choose("add_friend") and wait(function() return S.add_note ~= nil end, 3), S.add_note)
check("the friend is listed", wait(function() return #(On.friends or {}) == 1 and On.friends[1].name == "Ghosty" end, 3))
esc()

-- the route with a ghost: the leaderboard on its card, then riding it
check("'My routes'", choose("my") and S.screen == "myroutes", S.screen)
local idx
for i, r in ipairs((function() local l = {}; for _, r in ipairs(S.list()) do if r.own then l[#l + 1] = r end end; return l end)()) do
  if r.id == "short sprint" then idx = i end
end
for _ = 1, 20 do if UI.focused("own:" .. idx) then break end; press("DOWN") end
check("the route's leaderboard on its card", wait(function() frame(); return shown("Ghosty") end, 5))
press("ENTER")
check("riding it", wait(function() return S.screen == "ride" end, 120), S.screen)
check("the other rider's ghost is on the road", wait(function()
  for _, e in ipairs(OT.list) do if e.kind == "ghost" and e.name == "Ghosty" then return true end end
end, 5), #OT.list)
F.keys[KEY_W] = true
frames(240)
local g
for _, e in ipairs(OT.list) do if e.name == "Ghosty" then g = e end end
check("the ghost rides along (with the ride's clock)", g and g.s > 10, g and string.format("%.0f m", g.s))
check("its name over it", shown("Ghosty"))
-- riding live: our game tells the server where we are; another player on the server is drawn
local sent
for _, n in ipairs(F.nets) do if n.name == "tinyatlas_live" and n.text and n.text:find(rid, 1, true) then sent = n end end
check("riding live: where you are goes to the server", sent ~= nil)
F.net_in = { "76561190000000042", json.encode({ i = "ZZFRIEND", n = "Livia", k = "77||2|2", r = rid, s = (V.s or 0) + 6, v = 7, c = 88 }) }
F.net_recv.tinyatlas_live()
frames(3)
local livia
for _, e in pairs(Live.riders) do if e.name == "Livia" then livia = e end end
check("a player on the same server rides beside you", livia ~= nil and livia.s and livia.s > 0)
check("in the riders list", shown("Livia"))
check("the ride to the finish", wait(function() return S.screen == "results" end, 120), string.format("%s at %.0f of %.0f m", S.screen, V.s or 0, V.R and V.R.length or 0))
F.keys[KEY_W] = nil
local res = S.result and S.result.online
check("the ride goes to the leaderboard", wait(function() return res and res.state == "sent" end, 5), res and (res.state .. " " .. tostring(res.err)))
check("your place is shown", shown("Leaderboard:"), res and res.rank)
check("your best kept on your computer as a ghost", OT.own_best(rid, "keys") ~= nil)
local board = post("route", { key = gkey, route = rid, source = "keys" })
local mine
for _, b in ipairs(board.board or {}) do if b.id == On.id then mine = b end end
check("the service has your ride", mine ~= nil and math.abs(mine.time - (S.result.time or 0)) <= 1, mine and mine.time)
choose("menu")

-- riding it again: your own best rides with you, from your computer
check("your own best rides with you the next time", (function()
  OT.start(rid, "keys")
  for _, e in ipairs(OT.list) do if e.kind == "ghost" and e.why == "you" then return true end end
end)())
OT.stop()

-- a route nobody has ridden: the game's computer riders
check("a route with no ghosts gets computer riders", (function()
  local qid = route_lib.id(route_lib.parse_gpx(route_lib.to_gpx("x", quiet)).points)
  OT.start(qid, "keys")
  frames(30)
  local n = 0
  for _, e in ipairs(OT.list) do if e.kind == "bot" then n = n + 1 end end
  OT.stop()
  return n == OT.BOTS
end)())

-- sharing the route
check("'My routes' again", choose("my") and S.screen == "myroutes", S.screen)
for _ = 1, 20 do if UI.focused("own:" .. idx) then break end; press("DOWN") end
check("'Share'", choose("share") and S.screen == "share" and S.share_route.id == "short sprint", S.share_route and S.share_route.id)
for _ = 1, 10 do if UI.focused("share_mine") then break end; press("DOWN") end
press("RIGHT")
check("'This is my own route' first", S.share_mine == "yes")
check("'Share it'", choose("share_go") and wait(function() return S.share_ok end, 5), S.share_state)
esc(); esc()
check("'Shared routes'", choose("shared") and S.screen == "shared", S.screen)
check("the shared route is listed", wait(function() return S.shared_state == "ready" and #(S.shared_list or {}) >= 1 end, 5))
local listed
for _, r in ipairs(S.shared_list or {}) do if r.id == rid then listed = r end end
check("yours among them, by its name and with your ride counted", listed and listed.name == "short sprint" and listed.rides >= 1,
  listed and (listed.name .. ", " .. listed.rides .. " rides"))
esc()
check("the settings show the online state", choose("settings") and wait(function() frame(); return shown("Online as Tester") end, 2))
esc()

oldprint(#F.errors == 0 and "no Lua errors" or ("Lua errors: " .. table.concat(F.errors, "\n  ")))
oldprint((bad == 0 and #F.errors == 0) and "OK" or ("FAILED: " .. bad .. " checks"))
os.execute('rm -rf "' .. DATA .. '"')
