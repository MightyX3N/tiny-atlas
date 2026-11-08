-- Runs the gamemode's new-builder bench (cl_atlas.lua: ta_buildbench) in the fake GMod, with downloads served
-- from local files. usage: test_atlas_bench.lua DATA_DIR TILE_FILE TILEJSON_FILE [lat lon]
local here = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local DATA, TILE, TJ = arg[1], arg[2], arg[3]
local lat, lon = tonumber(arg[4]) or 52.3731, tonumber(arg[5]) or 4.8925
os.execute('rm -rf "' .. DATA .. '" && mkdir -p "' .. DATA .. '"')
local GMDIR = here .. "../gamemodes/tinyatlas/gamemode"
local F = dofile(here .. "fakegmod.lua")(DATA, GMDIR)
dofile(here .. "fakegmod_render.lua")(F, { lua_roots = { here .. "../gamemodes" } })
GM = { FolderName = "tinyatlas" }
local FO = getmetatable(file.Open("probe.txt", "wb", "DATA")).__index
function FO:Write(s) self.f:write(s) end
local function rd(p) local f = assert(io.open(p, "rb")); local s = f:read("*a"); f:close(); return s end
local requests = {}
http = { Fetch = function(url, ok, fail)
  requests[#requests + 1] = url
  local body
  if url == "https://tiles.openfreemap.org/planet" then body = rd(TJ)
  elseif url:match("/14/%d+/%d+%.pbf$") then body = rd(TILE) end
  -- answer on a later frame, like the real thing
  timer.Simple(0.1, function() if body then ok(body, #body, {}, 200) else fail("404 in test") end end)
end }
local printed = {}
local oldprint = print
print = function(...) local t = {} for i, v in ipairs({ ... }) do t[i] = tostring(v) end printed[#printed + 1] = table.concat(t, " ") end

include("cl_atlas.lua")
local function run(label, paused)
  printed = {}
  F.run("ta_buildbench", tostring(lat), tostring(lon))
  local frames = 0
  repeat
    frames = frames + 1
    if paused then F.t = F.t + 1 / 60; hook.Run("PostRender") else F.tick(1 / 60) end   -- paused: no Think
    F.run_simple()
  until frames > 200000 or (printed[#printed] or ""):match("report written")
  oldprint("--- " .. label .. " (" .. frames .. " frames)")
  for _, l in ipairs(printed) do oldprint(l) end
  assert((printed[#printed] or ""):match("report written"), "bench did not finish")
end
run("first run: downloads")
assert(#requests == 2, "expected the TileJSON and one tile, got " .. #requests)
run("second run: cache, game paused (only PostRender runs)", true)
assert(#requests == 2, "second run should not download")
assert(#F.errors == 0, "errors: " .. table.concat(F.errors, "; "))
-- a place whose tile is not cached, with the network down: must say FAILED by itself
http.Fetch = function(url, ok, fail) timer.Simple(0.1, function() fail("unreachable in test") end) end
printed = {}
F.run("ta_buildbench", "40.0", "-3.0")
for _ = 1, 30 do F.tick(1 / 60); F.run_simple() end
oldprint("--- third run: network down")
for _, l in ipairs(printed) do oldprint(l) end
assert((printed[#printed] or ""):match("FAILED"), "a failed download must print FAILED")
oldprint("OK: requests " .. #requests .. ", errors 0")
