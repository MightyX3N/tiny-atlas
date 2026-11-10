-- Plays the standalone (LÖVE 12) in a fake LÖVE: menu, starting a route, the loading screen, then riding with the
-- keyboard for a while; records frames for tools/gmodcheck/ride.js and checks for Lua errors and FAILED lines.
--   luajit.py test_love.lua <cache dir> <out prefix> <route name | roam:N> [seconds of riding] [frames to record]
local here = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local CACHE, OUT, WHAT = arg[1], arg[2], arg[3]
local SECONDS = tonumber(arg[4]) or 60
local NREC = tonumber(arg[5]) or 6
local GAME = os.tmpname() .. "_love"
local SAVE = os.tmpname() .. "_save"
assert(os.execute('python3 "' .. here .. '../../tools/build_love.py" "' .. GAME .. '" > /dev/null') == 0 or true)
os.execute('mkdir -p "' .. SAVE .. '/tinyatlas" && ln -s "' .. CACHE .. '" "' .. SAVE .. '/tinyatlas/cache"')
local F = dofile(here .. "fakelove.lua")(GAME, SAVE)
local printed = {}
local oldprint = print
print = function(...)
  local t = {} for i, v in ipairs({ ... }) do t[i] = tostring(v) end
  local l = table.concat(t, " ")
  printed[#printed + 1] = l
  if not l:match("FAILED: elevation tile") then oldprint(l) end
end
assert(love.filesystem.load("main.lua"))()
love.load()
F.step(1 / 60)
local G = TinyAtlasGame.G
if os.getenv("TA_TICKPROF") then
  local jobs = package.loaded["jobs"]
  jobs.profile = { worst = 0 }; TA_PROFILE = jobs.profile
end
if os.getenv("TA_LOOK") then G.settings.look = os.getenv("TA_LOOK") end     -- photo / city / default / flat
local want = WHAT:match("^roam:(%d+)") and ("Free roam") or ("Ride: " .. WHAT)
local roam_n = tonumber(WHAT:match("^roam:(%d+)") or "0")
-- walk the menu with the arrow keys like a player: read the label under the cursor from the menu's own list
local function current_label()
  local i = 0
  for idx = 1, 200 do
    local name, val = debug.getupvalue(love.keypressed, idx)
    if not name then break end
    if name == "menu_items" then
      local list = val()
      return list[G.sel] and list[G.sel].label, #list
    end
  end
end
local start_ok = false
local target_seen = 0
for k = 1, 100 do
  local l, n = current_label()
  if l and l:sub(1, #want) == want then
    target_seen = target_seen + 1
    if want ~= "Free roam" or target_seen == roam_n then love.keypressed("return"); start_ok = true; break end
  end
  love.keypressed("down")
end
assert(start_ok, "could not find " .. want .. " in the menu")
local S = TinyAtlasGame.session()
local t0 = os.clock()
local n = 0
while S.phase ~= "riding" and n < 20000 do F.step(1 / 60); n = n + 1 end
assert(S.phase == "riding", "never got ready")
oldprint(string.format("ready after %d frames, %.1f s CPU", n, os.clock() - t0))

-- ride with W held, recording a few frames on the way
local ffi = require("ffi")
local bin = assert(io.open(OUT .. ".bin", "wb"))
local offset, nid, ids, meshes, frames = 0, 0, setmetatable({}, { __mode = "k" }), {}, {}
local function mesh_id(m, tex)
  local id = ids[m]
  if id then return id end
  nid = nid + 1; id = nid; ids[m] = id
  local d = m.data
  local buf = ffi.new("float[?]", m.n * 8)
  for i = 0, m.n * 8 - 1 do buf[i] = d[i + 1] end
  bin:write(ffi.string(buf, m.n * 32))
  -- the texture path relative to the pack's materials folder (ride.html loads it from there)
  local rel = tex and tex:match("materials/(.*)$") or "color/white"
  meshes[#meshes + 1] = string.format('{"id":%d,"tex":"%s","off":%d,"verts":%d}', id, rel, offset, m.n)
  offset = offset + m.n * 32
  return id
end
F.keys.w = true
local frames_total = math.floor(SECONDS * 60)
local every = math.max(1, math.floor(frames_total / NREC))
local worst = 0
for f = 1, frames_total do
  local rec = (f % every == 0)
  F.capture = rec
  F.draws, F.clear_at = {}, 0
  local a = os.clock()
  F.step(1 / 60)
  local ms = (os.clock() - a) * 1000
  if ms > worst then worst = ms end
  F.capture = false
  if rec and S.cam then
    local c = S.cam
    local dx, dy, dz = c.lx - c.x, c.ly - c.y, c.lz - c.z
    local hd = math.sqrt(dx * dx + dy * dy)
    local parts = {}
    for _, d in ipairs(F.draws) do parts[#parts + 1] = string.format("[%d,%.3f,%.3f,%.3f]", mesh_id(d.mesh, d.tex), d.off[1], d.off[2], d.off[3]) end
    frames[#frames + 1] = string.format('{"s":%.1f,"camera":{"pos":[0,0,0],"ang":[%.4f,%.4f,0],"fov":75},"rider":[%.3f,%.3f,%.3f],"heading":%.2f,"grade":0,"clear":%d,"px":1,"draws":[%s]}',
      G.ride.s, -math.deg(math.atan2(dz, hd)), math.deg(math.atan2(dy, dx)), S.x - c.x, S.y - c.y, S.z - c.z,
      math.deg(math.atan2(S.fy, S.fx)), F.clear_at or 0, table.concat(parts, ","))
  end
end
bin:close()
-- photos the game decoded: next to the pack materials, for the picture tool (MAT=<out>_mat)
if next(F.photo_files) then
  local mat = OUT .. "_mat"
  os.execute('mkdir -p "' .. mat .. '/photos" && cp -r "' .. GAME .. '/packs/tinyatlas_pack_city/materials/." "' .. mat .. '/"')
  for name, b in pairs(F.photo_files) do local f = io.open(mat .. "/photos/" .. name, "wb"); f:write(b); f:close() end
  oldprint("photos decoded: " .. F.photo_n .. " (downloads answered: " .. tostring(F.photo_requests) .. "), materials for pictures in " .. mat)
end
local fo = assert(io.open(OUT .. ".json", "w"))
fo:write('{"route":"' .. WHAT .. '","unit":1,"meshes":[' .. table.concat(meshes, ",") .. '],"frames":[' .. table.concat(frames, ",\n") .. ']}\n')
fo:close()
local fails = 0
for _, l in ipairs(printed) do if l:match("FAILED") and not l:match("elevation tile") then fails = fails + 1; oldprint("  " .. l) end end
oldprint(string.format("rode %.2f km in %d s at up to %.1f km/h; %d frames recorded; meshes %d (largest %d vertices); worst frame %.0f ms; Lua errors %d; FAILED lines %d",
  G.ride.s / 1000, SECONDS, (G.ride.speed or 0) * 3.6, #frames, F.mesh_stats.count, F.mesh_stats.max_verts, worst, #F.errors, fails))
if TA_PROFILE then oldprint(string.format("longest stretch without a tick: %.0f ms, ending at:%s", TA_PROFILE.worst * 1000, TA_PROFILE.where or "")) end
for i = 1, math.min(5, #F.errors) do oldprint("  error: " .. F.errors[i]) end
love.quit()
os.execute('rm -rf "' .. GAME .. '" "' .. SAVE .. '"')
