dofile((debug.getinfo(1,"S").source:sub(2):match("(.*/)") or "./") .. "common.lua")
local inflate, png = ATLAS_REQUIRE("inflate"), ATLAS_REQUIRE("png")
local mode = arg[1]
for i = 2, #arg do
  local s = readfile(arg[i])
  local t0 = os.clock()
  if mode == "png" then
    local img = png.decode(s)
    print(arg[i], img.w, img.h, img.ch, adler(img.px, img.w * img.h * img.ch), string.format("%.1fms", (os.clock() - t0) * 1000))
  elseif mode == "gzip" then
    local t, n = inflate.gzip(s); print(arg[i], n, adler(t, n))
  else
    local t, n = inflate.zlib(s); print(arg[i], n, adler(t, n))
  end
end
