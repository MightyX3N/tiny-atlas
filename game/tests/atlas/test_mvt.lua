dofile((debug.getinfo(1,"S").source:sub(2):match("(.*/)") or "./") .. "common.lua")
local mvt = ATLAS_REQUIRE("mvt")
local function propstr(p)
  local ks = {} for k in pairs(p) do ks[#ks+1] = k end table.sort(ks)
  local o = {} for _, k in ipairs(ks) do local v = p[k]
    if type(v) == "number" then v = (v == math.floor(v)) and string.format("%d", v) or string.format("%.6g", v) end
    o[#o+1] = k .. "=" .. tostring(v) end
  return table.concat(o, ",")
end
local total = 0
for i = 1, #arg do
  local s = readfile(arg[i]); local t0 = os.clock()
  local L = mvt.decode(s); total = total + os.clock() - t0
  local names = {} for k in pairs(L) do names[#names+1] = k end table.sort(names)
  for _, name in ipairs(names) do
    for fi, f in ipairs(L[name].features) do
      local n, h = 0, 0
      for _, part in ipairs(f.parts) do for _, v in ipairs(part) do n = n + 1; h = (h * 31 + v) % 1000000007 end end
      print(arg[i]:match("[^/]+$"), name, fi, f.type, n, h, propstr(f.props))
    end
  end
end
io.stderr:write(string.format("decode total %.1f ms for %d tiles\n", total * 1000, #arg))
