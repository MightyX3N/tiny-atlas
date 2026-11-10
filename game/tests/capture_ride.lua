-- Rides a route in the fake GMod with the gamemode's real Lua (cl_view.lua + atlas/) and records what the
-- renderer draws every STEP metres, for tools/gmodcheck/ride.js to turn into pictures.
--   luajit.py capture_ride.lua <cache dir> <out prefix> <route id | roam:lat,lon> [step m] [max frames]
-- Writes <out>.json (frames: camera, rider, which meshes with which offsets) and <out>.bin (mesh vertices).
-- Also checks what the real game would choke on: mesh vertex counts, missing textures, Lua errors.
local here = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local CACHE, OUT, WHAT = arg[1], arg[2], arg[3]
local STEP = tonumber(arg[4]) or 25
local MAXF = tonumber(arg[5]) or 1e9
local GAME = here .. ".."
local PACK = here .. "../../packs/tinyatlas_pack_default"
local PACK2 = here .. "../../packs/tinyatlas_pack_city"
local DATA = os.tmpname() .. "_gmdata"
os.execute('mkdir -p "' .. DATA .. '/tinyatlas" && ln -s "' .. CACHE .. '" "' .. DATA .. '/tinyatlas/cache"')
local F = dofile(here .. "fakegmod.lua")(DATA, here .. "../gamemodes/tinyatlas/gamemode")
-- TA_SHADERS=1: as if the outline shader (shaders/fxc/tinyatlas_edges_ps20b.vcs) is installed
if os.getenv("TA_SHADERS") == "1" then F.game_files = { ["shaders/fxc/tinyatlas_edges_ps20b.vcs"] = true } end
dofile(here .. "fakegmod_render.lua")(F, { lua_roots = { here .. "../gamemodes", PACK .. "/lua", PACK2 .. "/lua" },
  material_roots = { PACK .. "/materials", PACK2 .. "/materials" }, screen = { 1280, 720 } })
GM = { FolderName = "tinyatlas" }
F.keep = true
KEY_A, KEY_D = 11, 14
function surface.DrawRect() end
local FO = getmetatable(file.Open("probe.txt", "wb", "DATA")).__index
function FO:Write(s) self.f:write(s) end
-- the "GAME" search path: the game folder (gamemodes/...)
local read0, find0 = file.Read, file.Find
function file.Read(p, where)
  if where == "GAME" then local f = io.open(GAME .. "/" .. p, "rb"); if not f then return nil end; local s = f:read("*a"); f:close(); return s end
  return read0(p, where)
end
function file.Find(p, where)
  if where == "GAME" then
    local dir, pat = p:match("^(.*)/([^/]*)$")
    local out = {}
    local h = io.popen('ls "' .. GAME .. "/" .. dir .. '" 2>/dev/null')
    for l in h:lines() do if l:match("^" .. pat:gsub("%.", "%%."):gsub("%*", ".*") .. "$") then out[#out + 1] = l end end
    h:close()
    return out, {}
  end
  return find0(p, where)
end
-- offline: everything comes from the cache; anything not cached fails like a dead network
http = { Fetch = function(url, ok, fail) timer.Simple(0.05, function() fail("offline test") end) end }
local printed = {}
local oldprint = print
print = function(...)
  local t = {} for i, v in ipairs({ ... }) do t[i] = tostring(v) end
  local l = table.concat(t, " ")
  printed[#printed + 1] = l
  if not l:match("FAILED: elevation tile") then oldprint(l) end
end

-- remember where the renderer clears the depth buffer (distant ground drawn first, then the cells over it)
function render.ClearDepth() if F.capture then F.clear_at = #F.draws end end

CreateClientConVar("ta_online", "0", true, false):SetString("0")     -- no test players in the real online service
include("cl_init.lua")
local V = TinyAtlas.View
for _, kv in ipairs({ { "TA_STYLE", "ta_style" }, { "TA_PACK", "ta_pack" }, { "TA_PIXELATE", "ta_pixelate" }, { "TA_CAM_BACK", "ta_cam_back" }, { "TA_CAM_UP", "ta_cam_up" } }) do
  if os.getenv(kv[1]) then F.set(kv[2], os.getenv(kv[1])) end
end
-- the test moves the rider itself: the gamemode's own rider (trainer / keys) is switched off
F.hooks.Think.TinyAtlas_Ride = nil
TinyAtlas.Ride.s, TinyAtlas.Ride.speed = 0, 8

local function step_frame()
  F.tick(1 / 60)
  F.run_simple()
  F.render_frame(1 / 60)
end

local t0 = os.clock()
if WHAT:match("^roam:") then
  local lat, lon = WHAT:match("roam:([%d%.%-]+),([%d%.%-]+)")
  F.run("ta_roam", lat, lon)
else
  F.run("ta_ride", WHAT)
end
assert(V.on, "the ride did not start")
local n = 0
while V.phase ~= "riding" and n < 400000 do step_frame(); n = n + 1 end
assert(V.phase == "riding", "never got ready (phase " .. tostring(V.phase) .. ")")
oldprint(string.format("ready after %d frames, %.1f s CPU", n, os.clock() - t0))

-- ---- capture ----
local ffi = require("ffi")
local bin = assert(io.open(OUT .. ".bin", "wb"))
local offset = 0
local ids = setmetatable({}, { __mode = "k" })
local meshes, frames = {}, {}
local nid = 0
local function mesh_id(m, mat)
  local id = ids[m]
  if id then return id end
  nid = nid + 1; id = nid; ids[m] = id
  local tex = mat and mat.params and mat.params["$basetexture"]
  tex = type(tex) == "table" and tex.tex or tostring(tex)
  local d = m.data
  local buf = ffi.new("float[?]", m.n * 8)
  for i = 0, m.n * 8 - 1 do buf[i] = d[i + 1] end
  bin:write(ffi.string(buf, m.n * 32))
  meshes[#meshes + 1] = string.format('{"id":%d,"tex":"%s","off":%d,"verts":%d}', id, tex, offset, m.n)
  offset = offset + m.n * 32
  m.data = nil
  return id
end
local length = V.mode == "ride" and V.R.length or (STEP * (MAXF - 1))
local s, fcount, worst_build = tonumber(os.getenv("TA_START") or "0"), 0, 0
while s <= length + 0.01 and fcount < MAXF do
  TinyAtlas.Ride.s = s
  V.plan_t = 0
  -- let the streaming catch up: everything within 450 m built (a rider never sees it being built at riding speed)
  local k = 0
  repeat step_frame(); k = k + 1 until (k > 2 and V.W:missing_near(450) == 0) or k > 20000
  F.capture = true
  F.clear_at = 0
  step_frame()
  F.capture = false
  local c = F.camera
  local parts = {}
  for _, d in ipairs(F.draws) do
    if d.r then     -- turned (the rider): the 3 x 3 rows after the position
      local r = d.r
      parts[#parts + 1] = string.format("[%d,%.2f,%.2f,%.2f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f]", mesh_id(d.mesh, d.mat),
        d.t[1], d.t[2], d.t[3], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9])
    else
      parts[#parts + 1] = string.format("[%d,%.2f,%.2f,%.2f]", mesh_id(d.mesh, d.mat), d.t[1], d.t[2], d.t[3])
    end
  end
  local rb = F.rider_box or { x = 0, y = 0, z = 0 }
  frames[#frames + 1] = string.format('{"s":%.1f,"camera":{"pos":[%.2f,%.2f,%.2f],"ang":[%.4f,%.4f,%.4f],"fov":%.1f},"rider":[%.2f,%.2f,%.2f],"heading":%.2f,"grade":%.2f,"clear":%d,"px":%d,"draws":[%s]}',
    s, c.pos.x, c.pos.y, c.pos.z, c.ang.p, c.ang.y, c.ang.r, c.fov, rb.x, rb.y, rb.z,
    math.deg(math.atan2(V.fy, V.fx)), V.mode == "ride" and V.R:grade(s) or (V.roam_grade or 0), F.clear_at or 0, (F.screen_quad and V.px) or 1, table.concat(parts, ","))
  fcount = fcount + 1
  if fcount % 40 == 0 then oldprint(string.format("  %d frames, %.2f km, %d meshes, %d cells built", fcount, s / 1000, nid, V.W.stats.built)) end
  s = s + STEP
end
bin:close()
local f = assert(io.open(OUT .. ".json", "w"))
f:write('{"route":"' .. WHAT .. '","unit":52.4934,"meshes":[' .. table.concat(meshes, ",") .. '],"frames":[' .. table.concat(frames, ",\n") .. ']}\n')
f:close()
local fails = 0
for _, l in ipairs(printed) do if l:match("FAILED") and not l:match("elevation tile") then fails = fails + 1 end end
oldprint(string.format("captured %d frames, %d meshes (%.1f MB), %d cells built (%.0f ms each), largest mesh %d vertices, Lua errors %d, FAILED lines %d, CPU %.0f s" .. (F.depth_draws and string.format(", outline depth pass %d draws", F.depth_draws) or ""),
  fcount, nid, offset / 1e6, V.W.stats.built, V.W.stats.built > 0 and V.W.stats.ms / V.W.stats.built or 0, F.mesh_stats.max_verts, #F.errors, fails, os.clock() - t0))
for i = 1, math.min(10, #F.errors) do oldprint("  error: " .. F.errors[i]) end
os.execute('rm -rf "' .. DATA .. '"')
