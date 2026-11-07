-- The six water colours from one colour, as the tree and bush generators
-- build their ramps: the colour given is the water's own tone (base), the
-- darker tones lean toward blue and the lighter ones toward yellow,
-- whichever way round the hue wheel is shorter, and the foam is nearly
-- white. The offsets come from the four looks' palettes (made from the
-- reference pictures), measured against their base tone.

local Palette = {}

local floor, max, min, abs = math.floor, math.max, math.min, math.abs

local LIGHT_HUE, DARK_HUE = 60, 240

-- shadow, deep, base, light, highlight (foam apart)
local V_OFF = { -0.28, -0.13, 0, 0.10, 0.23 }
-- Saturation as a share of the base's (the four looks: darker tones a
-- little richer, lighter ones paler).
local S_MUL = { 1.2, 1.1, 1, 0.85, 0.57 }
-- How far toward blue (darker) or yellow (lighter), times the hue shift.
local H_OFF = { 1.6, 0.7, 0, 0.3, 0.8 }

Palette.DEFAULTS = { hue = 12, sat = 18, range = 100 }

local function rgbToHsv(r, g, b)
  r, g, b = r / 255, g / 255, b / 255
  local mx, mn = max(r, g, b), min(r, g, b)
  local d = mx - mn
  local h = 0
  if d > 0 then
    if mx == r then h = ((g - b) / d) % 6
    elseif mx == g then h = (b - r) / d + 2
    else h = (r - g) / d + 4 end
    h = h * 60
  end
  return h % 360, (mx == 0) and 0 or d / mx, mx
end

local function hsvToRgb(h, s, v)
  h = h % 360
  local c = v * s
  local x = c * (1 - abs((h / 60) % 2 - 1))
  local m = v - c
  local r, g, b
  if h < 60 then r, g, b = c, x, 0
  elseif h < 120 then r, g, b = x, c, 0
  elseif h < 180 then r, g, b = 0, c, x
  elseif h < 240 then r, g, b = 0, x, c
  elseif h < 300 then r, g, b = x, 0, c
  else r, g, b = c, 0, x end
  return floor((r + m) * 255 + 0.5), floor((g + m) * 255 + 0.5), floor((b + m) * 255 + 0.5)
end

-- Turns hue h toward target by at most `amount` degrees, never past it.
local function toward(h, target, amount)
  local d = ((target - h + 540) % 360) - 180
  if abs(d) <= amount then return target end
  return h + ((d > 0) and amount or -amount)
end

local function clamp(v, lo, hi) return max(lo, min(hi, v)) end

local function hex(r, g, b) return string.format("%02x%02x%02x", r, g, b) end

-- Six hex colours (shadow .. foam) from a hex colour. hue: 0 .. 60 (how
-- far the tones turn), sat: 0 .. 60 (how much their saturation moves),
-- range: 20 .. 180 (% of the usual light-to-dark spread).
function Palette.ramp(baseHex, hue, sat, range)
  hue = hue or Palette.DEFAULTS.hue
  sat = sat or Palette.DEFAULTS.sat
  range = (range or Palette.DEFAULTS.range) / 100
  local r, g, b = tonumber(baseHex:sub(1, 2), 16), tonumber(baseHex:sub(3, 4), 16), tonumber(baseHex:sub(5, 6), 16)
  local h, s, v = rgbToHsv(r, g, b)
  local k = sat / Palette.DEFAULTS.sat
  local out = {}
  for i = 1, 5 do
    local vi = clamp(v + V_OFF[i] * range, 0.05, 1)
    local si = clamp(s * (1 + (S_MUL[i] - 1) * k), 0, 1)
    local hi = h
    if i < 3 then hi = toward(h, DARK_HUE, H_OFF[i] * hue)
    elseif i > 3 then hi = toward(h, LIGHT_HUE, H_OFF[i] * hue) end
    out[i] = (i == 3) and baseHex:lower() or hex(hsvToRgb(hi, si, vi))
  end
  -- Foam: nearly white, a breath of the water's colour.
  local fv = clamp(v + 0.38 * range, 0.05, 1)
  if range >= 1 then fv = max(fv, 0.96) end
  out[6] = hex(hsvToRgb(toward(h, LIGHT_HUE, 2 * hue), clamp(s * 0.16, 0, 1), fv))
  return out
end

return Palette
