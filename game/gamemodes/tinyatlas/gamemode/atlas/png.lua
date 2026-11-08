-- PNG decoder in plain Lua (8-bit greyscale, RGB, palette, grey+alpha, RGBA; not interlaced).
-- Used for elevation tiles (Terrarium encoding). Shared by every game.
--
--   png.decode(s) -> { w, h, ch, px }   px[1..w*h*ch], rows top to bottom; palette images come out as RGB(A)
local inflate = ATLAS_REQUIRE("inflate")
local byte, sub, abs = string.byte, string.sub, math.abs

local M = {}

local function u32(s, p)
  local a, b, c, d = byte(s, p, p + 3)
  return ((a * 256 + b) * 256 + c) * 256 + d
end

local CHANNELS = { [0] = 1, [2] = 3, [3] = 1, [4] = 2, [6] = 4 }

function M.decode(s)
  if sub(s, 1, 8) ~= "\137PNG\r\n\26\n" then error("png: not a PNG file") end
  local p, w, h, depth, ctype, interlace = 9
  local idat, pal, trns = {}, nil, nil
  while p <= #s do
    local len, kind = u32(s, p), sub(s, p + 4, p + 7)
    local d0 = p + 8
    if kind == "IHDR" then
      w, h = u32(s, d0), u32(s, d0 + 4)
      depth, ctype = byte(s, d0 + 8), byte(s, d0 + 9)
      interlace = byte(s, d0 + 12)
    elseif kind == "PLTE" then
      pal = sub(s, d0, d0 + len - 1)
    elseif kind == "tRNS" then
      trns = sub(s, d0, d0 + len - 1)
    elseif kind == "IDAT" then
      idat[#idat + 1] = sub(s, d0, d0 + len - 1)
    elseif kind == "IEND" then
      break
    end
    p = d0 + len + 4
  end
  if not w then error("png: no IHDR") end
  if depth ~= 8 then error("png: only 8-bit images are supported (got " .. tostring(depth) .. ")") end
  if interlace ~= 0 then error("png: interlaced images are not supported") end
  local ch = CHANNELS[ctype]
  if not ch then error("png: bad colour type") end

  local raw, n = inflate.zlib(table.concat(idat))
  local stride = w * ch
  if n < h * (stride + 1) then error("png: image data too short") end
  local px = {}
  local q = 0                                -- index into raw (0-based, before the filter byte)
  for y = 0, h - 1 do
    local f = raw[q + 1]
    local o = y * stride                     -- output offset of this row (px is 1-based: px[o + i])
    local up = o - stride
    if f == 0 then
      for i = 1, stride do px[o + i] = raw[q + 1 + i] end
    elseif f == 1 then
      for i = 1, stride do
        local a = i > ch and px[o + i - ch] or 0
        px[o + i] = (raw[q + 1 + i] + a) % 256
      end
    elseif f == 2 then
      for i = 1, stride do
        local b = y > 0 and px[up + i] or 0
        px[o + i] = (raw[q + 1 + i] + b) % 256
      end
    elseif f == 3 then
      for i = 1, stride do
        local a = i > ch and px[o + i - ch] or 0
        local b = y > 0 and px[up + i] or 0
        px[o + i] = (raw[q + 1 + i] + math.floor((a + b) / 2)) % 256
      end
    elseif f == 4 then
      for i = 1, stride do
        local a = i > ch and px[o + i - ch] or 0
        local b = y > 0 and px[up + i] or 0
        local c = (i > ch and y > 0) and px[up + i - ch] or 0
        local pp = a + b - c
        local pa, pb, pc = abs(pp - a), abs(pp - b), abs(pp - c)
        local pr = (pa <= pb and pa <= pc) and a or (pb <= pc and b or c)
        px[o + i] = (raw[q + 1 + i] + pr) % 256
      end
    else
      error("png: bad filter type " .. tostring(f))
    end
    q = q + stride + 1
  end

  if ctype == 3 then                         -- expand the palette to RGB, or RGBA if it has transparency
    if not pal then error("png: palette image without PLTE") end
    local out, oc = {}, trns and 4 or 3
    for i = 1, w * h do
      local k = px[i]
      local r, g, b = byte(pal, k * 3 + 1, k * 3 + 3)
      local o = (i - 1) * oc
      out[o + 1], out[o + 2], out[o + 3] = r or 0, g or 0, b or 0
      if trns then out[o + 4] = byte(trns, k + 1) or 255 end
    end
    px, ch = out, oc
  end
  return { w = w, h = h, ch = ch, px = px }
end

-- Terrarium elevation (metres) at pixel x, y (0-based) of a decoded RGB(A) tile.
function M.terrarium(img, x, y)
  local o = (y * img.w + x) * img.ch
  local px = img.px
  return px[o + 1] * 256 + px[o + 2] + px[o + 3] / 256 - 32768
end

return M
