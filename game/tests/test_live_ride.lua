-- Rides a whole route live in the fake GMod with the real gamemode files, like a player would: the world is built
-- while riding, at 60 frames a second with the normal build budget. Checks that it starts quickly, never falls
-- behind the rider, and how long the longest frame of building is.
--   luajit.py test_live_ride.lua <cache dir> <route id | gpx file> <km/h> [max km]
-- A GPX file path is copied into data/tinyatlas/gpx/ first, the way a player adds their own route.
local here = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local CACHE, WHAT, KMH, MAXKM = arg[1], arg[2], tonumber(arg[3]) or 30, tonumber(arg[4]) or 1e9
local PACK = here .. "../../packs/tinyatlas_pack_default"
local DATA = os.tmpname() .. "_gmdata"
os.execute('mkdir -p "' .. DATA .. '/tinyatlas/gpx" && ln -s "' .. CACHE .. '" "' .. DATA .. '/tinyatlas/cache"')
local name = WHAT
if WHAT:match("%.gpx$") then
  name = WHAT:match("([^/]+)%.gpx$")
  os.execute('cp "' .. WHAT .. '" "' .. DATA .. '/tinyatlas/gpx/' .. name .. '.gpx"')
end
local F = dofile(here .. "fakegmod.lua")(DATA, here .. "../gamemodes/tinyatlas/gamemode")
dofile(here .. "fakegmod_render.lua")(F, { lua_roots = { here .. "../gamemodes", PACK .. "/lua" },
  material_roots = { PACK .. "/materials" }, screen = { 1280, 720 } })
GM = { FolderName = "tinyatlas" }
KEY_A, KEY_D = 11, 14
function surface.DrawRect() end
local FO = getmetatable(file.Open("probe.txt", "wb", "DATA")).__index
function FO:Write(s) self.f:write(s) end
local GAME = here .. ".."
local read0, find0 = file.Read, file.Find
function file.Read(p, where)
  if where == "GAME" then local f = io.open(GAME .. "/" .. p, "rb"); if not f then return nil end; local s = f:read("*a"); f:close(); return s end
  return read0(p, where)
end
function file.Find(p, where) if where == "GAME" then return {}, {} end return find0(p, where) end
http = { Fetch = function(url, ok, fail) timer.Simple(0.05, function() fail("offline test") end) end }
local lines = {}
local oldprint = print
print = function(...)
  local t = {} for i, v in ipairs({ ... }) do t[i] = tostring(v) end
  local l = table.concat(t, " ")
  lines[#lines + 1] = l
  if not l:match("FAILED: elevation tile") then oldprint(string.format("%7.1f s  %s", F.t, l)) end
end
include("cl_init.lua")
local V = TinyAtlas.View
-- which pieces of work run longer than a frame can take in one go (they cannot yield in the middle)
local spans = {}
local function wrap(t, k, label)
  local f = t[k]
  t[k] = function(...)
    local t0 = os.clock()
    local a, b, c = f(...)
    local ms = (os.clock() - t0) * 1000
    local S = spans[label] or { n = 0, worst = 0, over = 0 }
    spans[label] = S
    S.n = S.n + 1
    if ms > S.worst then S.worst = ms end
    if ms > 12 then S.over = S.over + 1 end
    return a, b, c
  end
end
wrap(ATLAS_REQUIRE("mvt"), "decode", "map tile decode")
wrap(ATLAS_REQUIRE("route"), "finish_heights", "route heights")
local world_mod = ATLAS_REQUIRE("world")
local new0 = world_mod.new
world_mod.new = function(o) wrap(o, "make", "GMod meshes"); return new0(o) end
TinyAtlas.Ride = { s = 0, speed = 0 }

-- one frame of the game at 60 fps: Think runs the build jobs; measure how long that frame's Lua took
local worst_frame, frames, slow = 0, 0, 0
local function frame()
  local t0 = os.clock()
  F.tick(1 / 60)
  F.run_simple()
  F.render_frame(1 / 60)
  local ms = (os.clock() - t0) * 1000
  frames = frames + 1
  return ms
end

-- sample where the build job is when one of its slices has already run 12 ms past its start (cannot yield there)
local prof = require("jit.profile")
local stuck = {}
if os.getenv("PROFILE_STUCK") then
  prof.start("li1", function(th, samples, vmstate)
    local job = V.job
    if job and job.running and job.slice_start and os.clock() - job.slice_start > 0.012 and os.clock() - job.slice_start < 2 then
      local d = prof.dumpstack(th, "l;", 6)
      stuck[d] = (stuck[d] or 0) + samples
    end
  end)
end
F.run("ta_ride", name)
assert(V.on, "the ride did not start")
local n = 0
while V.phase ~= "riding" and n < 60 * 600 do frame(); n = n + 1 end
assert(V.phase == "riding", "never got ready")
local start_s = n / 60
local v = KMH / 3.6
local R = V.R
local limit = math.min(R.length, MAXKM * 1000)
local min_ahead, behind_frames = 1e9, 0
local ms_list = {}
while TinyAtlas.Ride.s < limit do
  TinyAtlas.Ride.s = TinyAtlas.Ride.s + v / 60
  TinyAtlas.Ride.speed = v
  local ms = frame()
  ms_list[#ms_list + 1] = ms
  if ms > worst_frame then worst_frame = ms end
  if ms > 25 then slow = slow + 1 end
  local ahead, all = V.W:route_ready_ahead(TinyAtlas.Ride.s)
  if not all then
    if ahead < min_ahead then min_ahead = ahead end
    if ahead < 50 then behind_frames = behind_frames + 1 end
  end
end
table.sort(ms_list)
local fails = 0
for _, l in ipairs(lines) do if l:match("FAILED") and not l:match("elevation tile") then fails = fails + 1 end end
oldprint(string.format("RESULT %s at %d km/h: ready after %.1f s of game time, rode %.2f km in %.0f s; world ahead of the rider: least %.0f m, frames with under 50 m: %d; Lua per frame: median %.1f ms, 99th %.1f ms, worst %.1f ms, frames over 25 ms: %d of %d; cells built %d (%.0f ms each); Lua errors %d; FAILED lines %d",
  name, KMH, start_s, limit / 1000, limit / v, min_ahead == 1e9 and 0 or min_ahead, behind_frames,
  ms_list[math.floor(#ms_list / 2) + 1], ms_list[math.floor(#ms_list * 0.99) + 1], worst_frame, slow, #ms_list,
  V.W.stats.built, V.W.stats.built > 0 and V.W.stats.ms / V.W.stats.built or 0, #F.errors, fails))
prof.stop()
local st = {} for k, v in pairs(stuck) do st[#st + 1] = { k, v } end
table.sort(st, function(a, b) return a[2] > b[2] end)
for i = 1, math.min(12, #st) do oldprint(string.format("  stuck %5d  %s", st[i][2], st[i][1])) end
for label, S in pairs(spans) do oldprint(string.format("  %-16s %5d calls, worst %.1f ms, %d over 12 ms", label, S.n, S.worst, S.over)) end
for i = 1, math.min(5, #F.errors) do oldprint("  error: " .. F.errors[i]) end
os.execute('rm -rf "' .. DATA .. '"')
