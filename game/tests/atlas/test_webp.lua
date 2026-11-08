dofile((debug.getinfo(1,"S").source:sub(2):match("(.*/)") or "./") .. "common.lua")
local webp = ATLAS_REQUIRE("webp")
local dir = arg[1]
local fails, n = 0, 0
for name in io.lines(dir .. "/list.txt") do
  n = n + 1
  local t0 = os.clock()
  local ok, img = pcall(webp.decode, readfile(dir .. "/" .. name .. ".webp"))
  local ms = (os.clock() - t0) * 1000
  if not ok then print("FAIL", name, img); fails = fails + 1
  else
    local ref = readfile(dir .. "/" .. name .. ".rgba")
    local bad, first = 0, nil
    for i = 0, img.w * img.h - 1 do
      local r, g, b, a = ref:byte(i * 4 + 1, i * 4 + 4)
      if r ~= img.R[i] or g ~= img.G[i] or b ~= img.B[i] or a ~= img.A[i] then
        bad = bad + 1
        if not first then first = string.format("px %d: want %d,%d,%d,%d got %s,%s,%s,%s", i, r, g, b, a, tostring(img.R[i]), tostring(img.G[i]), tostring(img.B[i]), tostring(img.A[i])) end
      end
    end
    if bad > 0 then fails = fails + 1; print("WRONG", name, img.w .. "x" .. img.h, bad .. " pixels", first)
    else print("ok", name, img.w .. "x" .. img.h, string.format("%.0f ms", ms)) end
  end
end
print(string.format("%d images, %d failed", n, fails))
