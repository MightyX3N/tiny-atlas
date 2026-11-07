-- Scene pixels to image pixels: one string.gsub over a frame turns its
-- bytes (Codes: element, colour, what lies under it) into an image's
-- bytes, in the sprite's colour mode.
--
-- Every element belongs to an opacity group. The water's own pixels (the
-- surfaces, deep water, the falls and their slits) let what is under the
-- layer show through; everything on them (streaks, lines, foam, rings...)
-- is laid over the water beneath it, so half-clear foam is foam mixed into
-- the water, not a hole. Over the ground foam and spray are see-through by
-- their own opacity; mist is a haze, thin mist at half of it.

local G = ... or _WOWE

local Styles = G.require("styles")
local Codes  = G.require("codes")

local Paint = {}

local floor = math.floor

local BASE = 3
local E = Codes.E

-- Nearest palette entry to a colour (indexed sprites).
local function nearest(pal, r, g, b, skip)
  local best, bi = math.huge, 0
  for i = 0, #pal - 1 do
    if i ~= skip then
      local c = pal:getColor(i)
      local dr, dg, db = c.red - r, c.green - g, c.blue - b
      local d = dr * dr * 3 + dg * dg * 4 + db * db * 2
      if d < best then best, bi = d, i end
    end
  end
  return bi
end

-- Opacity 0 .. 1 of every group, from percents.
local function opacities(alpha)
  local A = {}
  for _, name in ipairs(Codes.GROUPS) do
    local v = alpha and tonumber(alpha[name]) or 100
    A[name] = math.max(0, math.min(100, v)) / 100
  end
  return A
end

-- The colour (0 .. 255 each) and opacity (0 .. 1) a pixel byte stands
-- for, or nil for none.
local function resolve(code, colors, A)
  local lv, el, under = Codes.decode(code)
  if lv < 1 or el < 0 then return nil end
  local r, g, b = Styles.rgb(colors[lv])
  local a = A[Codes.GROUP[el]]
  if el == E.MIST then
    if under == 1 then a = a * 0.5 end
  elseif under > 0 and not Codes.ALONE[el] then
    local ab = A[(under == 1) and "fall" or "water"]
    local br, bg, bb = Styles.rgb(colors[BASE])
    local oa = a + ab * (1 - a)
    if oa > 0 then
      local k = ab * (1 - a)
      r = (r * a + br * k) / oa
      g = (g * a + bg * k) / oa
      b = (b * a + bb * k) / oa
    end
    a = oa
  end
  return floor(r + 0.5), floor(g + 0.5), floor(b + 0.5), a
end

-- byte -> pixel bytes, for `colors` (six hex strings), `alpha` (percent per
-- group; nil: all opaque) and a target { colorMode, palette, transparent }
-- (RGB when nil).
function Paint.map(colors, target, alpha)
  local mode = target and target.colorMode or ColorMode.RGB
  local A = opacities(alpha)
  local t = target and target.transparent or 0
  local clear
  if mode == ColorMode.INDEXED then clear = string.char(t)
  elseif mode == ColorMode.GRAY then clear = "\0\0"
  else clear = "\0\0\0\0" end
  local map = {}
  for code = 0, 255 do
    local r, g, b, a = resolve(code, colors, A)
    local px = clear
    if r then
      if mode == ColorMode.INDEXED then
        if a >= 0.5 then px = string.char(nearest(target.palette, r, g, b, t)) end
      elseif mode == ColorMode.GRAY then
        px = string.char(floor(r * 0.299 + g * 0.587 + b * 0.114 + 0.5), floor(a * 255 + 0.5))
      elseif a > 0 then
        px = string.char(r, g, b, floor(a * 255 + 0.5))
      end
    end
    map[string.char(code)] = px
  end
  return map
end

-- An image of w x h from a frame's bytes.
function Paint.image(levels, w, h, map, target)
  local mode = target and target.colorMode or ColorMode.RGB
  local img
  if mode == ColorMode.INDEXED then
    img = Image(ImageSpec{ width = w, height = h, colorMode = mode,
                           transparentColor = target.transparent or 0 })
  else
    img = Image(w, h, mode)
  end
  img.bytes = (levels:gsub(".", map))
  return img
end

-- Where to write for a sprite: its colour mode, palette, transparent index.
function Paint.target(spr)
  if not spr then return nil end
  local t = { colorMode = spr.colorMode }
  if spr.colorMode == ColorMode.INDEXED then
    t.palette = spr.palettes[1]
    t.transparent = spr.transparentColor
  end
  return t
end

return Paint
