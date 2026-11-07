-- The look both windows share: a dark grey ground, blue for what is on, a
-- light accent for section titles, and small text drawn straight on the
-- canvas.
--
-- Text is measured once and remembered; text that is cut is cut on whole
-- UTF-8 characters (a layer name can hold any), since a broken character
-- brings Aseprite down when it is measured or drawn.

local Style = {}

local floor, max, min = math.floor, math.max, math.min

local function rgb(r, g, b, a) return Color{ r = r, g = g, b = b, a = a or 255 } end
Style.rgb = rgb

Style.BG        = rgb(52, 54, 58)
Style.HEAD      = rgb(45, 47, 51)
Style.LINE      = rgb(35, 36, 40)
Style.FIELD     = rgb(38, 40, 44)
Style.FIELD_HI  = rgb(58, 61, 67)
Style.FILL      = rgb(56, 88, 138)
Style.FILL_HI   = rgb(71, 114, 179)
Style.FILL_OFF  = rgb(70, 74, 82)
Style.ACCENT    = rgb(122, 164, 230)
Style.KNOB      = rgb(232, 234, 238)
Style.KNOB_OFF  = rgb(128, 131, 138)
Style.TEXT      = rgb(220, 222, 228)
Style.TEXT_DIM  = rgb(150, 153, 160)
Style.WHITE     = rgb(255, 255, 255)
Style.BLACK     = rgb(0, 0, 0)
Style.CHECK_A   = rgb(45, 45, 50)
Style.CHECK_B   = rgb(60, 60, 65)
Style.TIP_BG    = rgb(24, 25, 28, 235)
Style.TIP_TEXT  = rgb(232, 234, 238)
Style.DANGER    = rgb(214, 76, 76, 245)
Style.HOT       = rgb(255, 214, 90)
Style.BUTTON    = rgb(40, 42, 46, 215)
Style.BUTTON_HI = rgb(84, 88, 96, 235)
Style.BUTTON_ON = rgb(71, 114, 179, 245)
Style.ICON      = rgb(214, 216, 222)
Style.ICON_DIM  = rgb(128, 131, 138)
Style.VIEW_BG   = rgb(38, 40, 44)

--------------------------------------------------------------------------
-- Text
--------------------------------------------------------------------------

-- Text as the canvas can take it: any broken UTF-8 piece is dropped.
function Style.safe(s)
  s = tostring(s or "")
  if utf8.len(s) then return s end
  local out = {}
  for ch in s:gmatch("[\0-\127\194-\244][\128-\191]*") do
    if utf8.len(ch) == 1 then out[#out + 1] = ch end
  end
  return table.concat(out)
end

local sizeCache, sizeCount = {}, 0

-- Width and height of a text; about 6 px a character where the canvas
-- cannot measure.
function Style.measure(gc, s)
  s = Style.safe(s)
  local e = sizeCache[s]
  if e then return e[1], e[2] end
  local w, h = #s * 6, 10
  if gc and gc.measureText then
    local ok, size = pcall(gc.measureText, gc, s)
    if ok and size then w, h = size.width or w, size.height or h end
  end
  w, h = floor(w + 0.5), floor(h + 0.5)
  if sizeCount > 4000 then sizeCache, sizeCount = {}, 0 end
  sizeCache[s] = { w, h }
  sizeCount = sizeCount + 1
  return w, h
end

-- The longest start of `s` that fits in `width`, with "..." when cut.
function Style.fit(gc, s, width)
  s = Style.safe(s)
  if Style.measure(gc, s) <= width then return s end
  local chars = {}
  for c in s:gmatch("[\0-\127\194-\244][\128-\191]*") do chars[#chars + 1] = c end
  local lo, hi = 0, #chars
  while lo < hi do
    local mid = (lo + hi + 1) // 2
    local t = table.concat(chars, "", 1, mid) .. "..."
    if Style.measure(gc, t) <= width then lo = mid else hi = mid - 1 end
  end
  return table.concat(chars, "", 1, lo) .. "..."
end

-- Words laid into lines no wider than width. Splits on real blanks only:
-- in some Windows locales %s also takes byte 0xA0, a piece of many UTF-8
-- characters.
function Style.wrap(gc, s, width)
  local lines, cur = {}, nil
  for word in tostring(s or ""):gmatch("[^ \t\r\n]+") do
    local try = cur and (cur .. " " .. word) or word
    if cur and Style.measure(gc, try) > width then
      lines[#lines + 1] = cur
      cur = word
    else
      cur = try
    end
  end
  if cur then lines[#lines + 1] = cur end
  return lines
end

--------------------------------------------------------------------------
-- Boxes and text
--------------------------------------------------------------------------

function Style.fillRect(gc, x, y, w, h, color)
  if w <= 0 or h <= 0 then return end
  gc.color = color
  gc:fillRect(Rectangle(floor(x), floor(y), floor(w), floor(h)))
end

local roundOK = true

-- A filled box with rounded corners; square ones where the canvas has no
-- rounded rectangles or the box is too small.
function Style.fillRound(gc, x, y, w, h, r, color)
  if w <= 0 or h <= 0 then return end
  gc.color = color
  if roundOK and r and r > 0 and w >= 2 * r + 2 and h >= 2 * r + 2 then
    local ok = pcall(function()
      gc:beginPath()
      gc:roundedRect(Rectangle(floor(x), floor(y), floor(w), floor(h)), r, r)
      gc:fill()
    end)
    if ok then return end
    roundOK = false
    gc.color = color
  end
  gc:fillRect(Rectangle(floor(x), floor(y), floor(w), floor(h)))
end

-- A 1 px frame just inside the box.
function Style.frame(gc, x, y, w, h, color)
  Style.fillRect(gc, x, y, w, 1, color)
  Style.fillRect(gc, x, y + h - 1, w, 1, color)
  Style.fillRect(gc, x, y + 1, 1, h - 2, color)
  Style.fillRect(gc, x + w - 1, y + 1, 1, h - 2, color)
end

function Style.text(gc, s, x, y, color)
  gc.color = color
  gc:fillText(Style.safe(s), floor(x), floor(y))
end

-- Text centred on a box's height, from x.
function Style.textMid(gc, s, x, y, h, color)
  local _, th = Style.measure(gc, s)
  Style.text(gc, s, x, y + floor((h - th) / 2), color)
end

-- Text centred in a box.
function Style.textCenter(gc, s, x, y, w, h, color)
  local tw, th = Style.measure(gc, s)
  Style.text(gc, s, x + floor((w - tw) / 2), y + floor((h - th) / 2), color)
end

-- Text on a dark band, for lines over a picture.
function Style.label(gc, s, x, y, color)
  local tw, th = Style.measure(gc, s)
  Style.fillRound(gc, x - 4, y - 2, tw + 8, th + 4, 2, Style.TIP_BG)
  Style.text(gc, s, x, y, color or Style.TEXT)
end

-- A tooltip beside a point: to its right for side "right", its left for
-- "left", above it for "above" and below it for "below"; kept inside the
-- canvas. Long tips are broken into lines.
function Style.tip(gc, s, x, y, side, cw, ch)
  local lines = Style.wrap(gc, s, 240)
  local tw, th = 0, 0
  for _, l in ipairs(lines) do
    local w, h = Style.measure(gc, l)
    tw, th = max(tw, w), max(th, h)
  end
  local lh = th + 2
  local bw, bh = tw + 10, #lines * lh + 5
  local tx, ty
  if side == "left" then
    tx, ty = x - 6 - bw, floor(y - bh / 2)
  elseif side == "above" then
    tx, ty = floor(x - bw / 2), y - bh - 4
  elseif side == "below" then
    tx, ty = floor(x - bw / 2), y + 4
  else
    tx, ty = x + 6, floor(y - bh / 2)
  end
  tx = max(3, min(tx, (cw or 9999) - bw - 3))
  if ty + bh > (ch or 9999) - 2 then ty = (ch or 9999) - bh - 2 end
  if ty < 2 then ty = 2 end
  Style.fillRound(gc, tx, ty, bw, bh, 3, Style.TIP_BG)
  for i, l in ipairs(lines) do
    Style.text(gc, l, tx + 5, ty + 3 + (i - 1) * lh, Style.TIP_TEXT)
  end
end

--------------------------------------------------------------------------
-- Colours
--------------------------------------------------------------------------

function Style.hexOf(c)
  if not c then return "-" end
  return string.format("#%02X%02X%02X", c.red, c.green, c.blue)
end

function Style.colorOf(hex)
  hex = tostring(hex or ""):gsub("#", "")
  if #hex == 3 then hex = hex:gsub("(%x)", "%1%1") end
  if #hex ~= 6 or not hex:match("^%x+$") then return rgb(128, 128, 128) end
  return rgb(tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16))
end

-- Black or white, whichever reads better on c.
function Style.inkOn(c)
  local l = 0.299 * c.red + 0.587 * c.green + 0.114 * c.blue
  return (l > 150) and Style.BLACK or Style.WHITE
end

-- A checker for see-through colours.
function Style.checker(gc, x, y, w, h, cell)
  cell = cell or 4
  for cy = 0, h - 1, cell do
    for cx = 0, w - 1, cell do
      local even = ((cx // cell) + (cy // cell)) % 2 == 0
      Style.fillRect(gc, x + cx, y + cy, min(cell, w - cx), min(cell, h - cy), even and Style.CHECK_A or Style.CHECK_B)
    end
  end
end

function Style.swatch(gc, x, y, w, h, color)
  if not color then
    Style.checker(gc, x, y, w, h)
    return
  end
  if (color.alpha or 255) < 255 then Style.checker(gc, x, y, w, h) end
  Style.fillRect(gc, x, y, w, h, color)
end

function Style.clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

return Style
