-- Test helpers: load the shared atlas modules outside any game.
local here = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
ATLAS_DIR = here .. "../../gamemodes/tinyatlas/gamemode/atlas/"
local loaded = {}
function ATLAS_REQUIRE(name)
  if loaded[name] == nil then loaded[name] = dofile(ATLAS_DIR .. name .. ".lua") end
  return loaded[name]
end
function readfile(p) local f = assert(io.open(p, "rb")); local s = f:read("*a"); f:close(); return s end
function adler(t, n)
  local a, b = 1, 0
  for i = 1, n do a = (a + t[i]) % 65521; b = (b + a) % 65521 end
  return b * 65536 + a
end
