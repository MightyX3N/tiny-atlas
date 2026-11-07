-- Icons for the toolbar and the tabs, drawn with canvas paths.
--
-- Simple line drawings about 14 px across, centred on (x, y): one colour,
-- 1 px lines and a few small fills. Curves are short polylines.

local Icons = {}

local floor, sin, cos, pi, sqrt = math.floor, math.sin, math.cos, math.pi, math.sqrt

Icons.COLOR = Color{ r = 214, g = 216, b = 222 }

-- A lens between two tips, `w` wide at its middle (an eye).
local function lens(gc, x0, y0, x1, y1, w)
  local dx, dy = x1 - x0, y1 - y0
  local len = sqrt(dx * dx + dy * dy)
  if len < 1e-6 then return end
  local nx, ny = -dy / len, dx / len
  local steps = 6
  gc:moveTo(x0, y0)
  for i = 1, steps do
    local t = i / steps
    local b = sin(pi * t) * w * 0.5
    gc:lineTo(x0 + dx * t + nx * b, y0 + dy * t + ny * b)
  end
  for i = steps - 1, 0, -1 do
    local t = i / steps
    local b = sin(pi * t) * w * 0.5
    gc:lineTo(x0 + dx * t - nx * b, y0 + dy * t - ny * b)
  end
end

-- Part of a circle, from angle a0 to a1 (radians, screen y down). With
-- `join` the first point continues the path instead of starting a new one.
local function arc(gc, x, y, r, a0, a1, steps, join)
  steps = steps or 8
  for i = 0, steps do
    local a = a0 + (a1 - a0) * i / steps
    local px, py = x + cos(a) * r, y + sin(a) * r
    if i == 0 and not join then gc:moveTo(px, py) else gc:lineTo(px, py) end
  end
end

-- A wave from x0 to x1 at height y: `n` humps, `a` px high.
local function wave(gc, x0, x1, y, a, n)
  local steps = n * 6
  for i = 0, steps do
    local t = i / steps
    local px, py = x0 + (x1 - x0) * t, y - sin(t * n * pi * 2) * a
    if i == 0 then gc:moveTo(px, py) else gc:lineTo(px, py) end
  end
end

local function box(gc, x0, y0, x1, y1)
  gc:moveTo(x0, y0) gc:lineTo(x1, y0) gc:lineTo(x1, y1) gc:lineTo(x0, y1) gc:lineTo(x0, y0)
end

-- Small filled squares, then back to an open path for the stroke.
local function dots(gc, list)
  gc:stroke()
  gc:beginPath()
  for _, d in ipairs(list) do gc:rect(Rectangle(d[1], d[2], d[3] or 2, d[4] or 2)) end
  gc:fill()
  gc:beginPath()
end

local DRAW = {}

--------------------------------------------------------------------------
-- The water
--------------------------------------------------------------------------

-- Still water: a basin, a ripple on its surface and one under it.
function DRAW.pool(gc, x, y)
  for i = 0, 10 do
    local a = math.pi * i / 10
    local px, py = x + cos(a) * 7, y - 2 + sin(a) * 7
    if i == 0 then gc:moveTo(px, py) else gc:lineTo(px, py) end
  end
  wave(gc, x - 7, x + 7, y - 3, 1, 2)
  gc:moveTo(x - 2, y + 2) gc:lineTo(x + 2, y + 2)
end

-- A river: two banks winding down, a current between them.
function DRAW.river(gc, x, y)
  local function bank(dx)
    for i = 0, 8 do
      local t = i / 8
      local px, py = x + dx + sin(t * pi * 1.6) * 3 - 1, y - 7 + t * 14
      if i == 0 then gc:moveTo(px, py) else gc:lineTo(px, py) end
    end
  end
  bank(-4)
  bank(4)
  gc:moveTo(x, y - 3) gc:lineTo(x + 1, y + 1)
end

-- A fall: a ledge, water pouring over it, foam at its foot.
function DRAW.fall(gc, x, y)
  gc:moveTo(x - 7, y - 6) gc:lineTo(x - 3, y - 6)
  gc:moveTo(x + 3, y - 6) gc:lineTo(x + 7, y - 6)
  gc:moveTo(x - 3, y - 6) gc:lineTo(x - 3, y + 3)
  gc:moveTo(x, y - 6) gc:lineTo(x, y + 2)
  gc:moveTo(x + 3, y - 6) gc:lineTo(x + 3, y + 3)
  wave(gc, x - 7, x + 7, y + 5, 1, 2)
end

-- A drop: the look.
function DRAW.drop(gc, x, y)
  gc:moveTo(x, y - 7)
  gc:lineTo(x - 4, y - 1)
  arc(gc, x, y + 2, 4.5, pi * 1.15, -pi * 0.15, 10, true)
  gc:lineTo(x, y - 7)
  gc:moveTo(x - 2, y + 1) gc:lineTo(x - 1, y + 3)
end

-- A painter's palette: the colours.
function DRAW.palette(gc, x, y)
  gc:oval(Rectangle(x - 7, y - 6, 14, 12))
  gc:oval(Rectangle(x - 3, y + 1, 4, 3))
  dots(gc, { { x - 4, y - 3 }, { x, y - 4 }, { x + 3, y - 1 } })
end

-- A strip of film: the loop and what goes into the sprite.
function DRAW.film(gc, x, y)
  box(gc, x - 6, y - 6, x + 6, y + 6)
  gc:moveTo(x - 3, y - 6) gc:lineTo(x - 3, y + 6)
  gc:moveTo(x + 3, y - 6) gc:lineTo(x + 3, y + 6)
  dots(gc, { { x - 5, y - 4, 1, 1 }, { x - 5, y, 1, 1 }, { x - 5, y + 4, 1, 1 },
             { x + 5, y - 4, 1, 1 }, { x + 5, y, 1, 1 }, { x + 5, y + 4, 1, 1 } })
end

--------------------------------------------------------------------------
-- The rods
--------------------------------------------------------------------------

-- A rod: a bent line with a dot at its start and an arrow at its end.
function DRAW.rod(gc, x, y)
  gc:moveTo(x - 6, y + 5)
  gc:lineTo(x - 3, y + 1) gc:lineTo(x + 1, y - 1) gc:lineTo(x + 5, y - 5)
  gc:moveTo(x + 1, y - 5) gc:lineTo(x + 5, y - 5) gc:lineTo(x + 5, y - 1)
  dots(gc, { { x - 7, y + 4, 3, 3 } })
end

-- A lip rod: the edge the water goes over, ticks hanging from it.
function DRAW.rodLip(gc, x, y)
  gc:moveTo(x - 7, y - 3) gc:lineTo(x + 7, y - 3)
  gc:moveTo(x - 5, y - 3) gc:lineTo(x - 5, y + 2)
  gc:moveTo(x - 1, y - 3) gc:lineTo(x - 1, y + 4)
  gc:moveTo(x + 3, y - 3) gc:lineTo(x + 3, y + 2)
  gc:moveTo(x + 6, y - 3) gc:lineTo(x + 6, y + 4)
end

-- A branch: one rod splitting off another.
function DRAW.branch(gc, x, y)
  gc:moveTo(x - 1, y + 7) gc:lineTo(x - 1, y - 6)
  gc:moveTo(x - 1, y + 1) gc:lineTo(x + 5, y - 5)
  gc:moveTo(x + 2, y - 5) gc:lineTo(x + 5, y - 5) gc:lineTo(x + 5, y - 2)
end

-- The other way round: two arrows.
function DRAW.reverse(gc, x, y)
  gc:moveTo(x - 6, y - 3) gc:lineTo(x + 6, y - 3)
  gc:moveTo(x + 3, y - 6) gc:lineTo(x + 6, y - 3) gc:lineTo(x + 3, y)
  gc:moveTo(x + 6, y + 3) gc:lineTo(x - 6, y + 3)
  gc:moveTo(x - 3, y) gc:lineTo(x - 6, y + 3) gc:lineTo(x - 3, y + 6)
end

--------------------------------------------------------------------------
-- Common
--------------------------------------------------------------------------

function DRAW.play(gc, x, y)
  gc:moveTo(x - 3, y - 5) gc:lineTo(x + 5, y) gc:lineTo(x - 3, y + 5) gc:lineTo(x - 3, y - 5)
  gc:stroke()
  gc:beginPath()
  gc:moveTo(x - 3, y - 5) gc:lineTo(x + 5, y) gc:lineTo(x - 3, y + 5)
  gc:closePath()
  gc:fill()
  gc:beginPath()
end

function DRAW.pause(gc, x, y)
  dots(gc, { { x - 4, y - 5, 3, 11 }, { x + 1, y - 5, 3, 11 } })
end

-- A die: a new variation.
function DRAW.dice(gc, x, y)
  box(gc, x - 6, y - 6, x + 6, y + 6)
  dots(gc, { { x - 4, y - 4 }, { x - 1, y - 1 }, { x + 2, y + 2 } })
end

function DRAW.undo(gc, x, y)
  gc:moveTo(x - 6, y - 3) gc:lineTo(x + 2, y - 3)
  arc(gc, x + 2, y + 1, 4, -pi * 0.5, pi * 0.5, 6, true)
  gc:lineTo(x - 3, y + 5)
  gc:moveTo(x - 3, y - 6) gc:lineTo(x - 6, y - 3) gc:lineTo(x - 3, y)
end

-- A small bin.
function DRAW.trash(gc, x, y)
  gc:moveTo(x - 4, y - 3) gc:lineTo(x + 4, y - 3)
  gc:moveTo(x - 1, y - 5) gc:lineTo(x + 1, y - 5)
  gc:moveTo(x - 3, y - 3) gc:lineTo(x - 2, y + 4) gc:lineTo(x + 2, y + 4) gc:lineTo(x + 3, y - 3)
  gc:moveTo(x, y - 1) gc:lineTo(x, y + 2)
end

function DRAW.eye(gc, x, y)
  lens(gc, x - 6, y, x + 6, y, 8)
  gc:oval(Rectangle(x - 2, y - 2, 4, 4))
end

function DRAW.eyeOff(gc, x, y)
  lens(gc, x - 6, y, x + 6, y, 8)
  gc:moveTo(x - 5, y + 5) gc:lineTo(x + 5, y - 5)
end

-- Fit to the view: four corner brackets.
function DRAW.fit(gc, x, y)
  gc:moveTo(x - 6, y - 2) gc:lineTo(x - 6, y - 6) gc:lineTo(x - 2, y - 6)
  gc:moveTo(x + 2, y - 6) gc:lineTo(x + 6, y - 6) gc:lineTo(x + 6, y - 2)
  gc:moveTo(x + 6, y + 2) gc:lineTo(x + 6, y + 6) gc:lineTo(x + 2, y + 6)
  gc:moveTo(x - 2, y + 6) gc:lineTo(x - 6, y + 6) gc:lineTo(x - 6, y + 2)
end

-- Zoom: a lens with a plus or a minus.
function DRAW.zoomIn(gc, x, y)
  gc:oval(Rectangle(x - 6, y - 6, 10, 10))
  gc:moveTo(x + 3, y + 3) gc:lineTo(x + 7, y + 7)
  gc:moveTo(x - 3, y - 1) gc:lineTo(x + 1, y - 1)
  gc:moveTo(x - 1, y - 3) gc:lineTo(x - 1, y + 1)
end

function DRAW.zoomOut(gc, x, y)
  gc:oval(Rectangle(x - 6, y - 6, 10, 10))
  gc:moveTo(x + 3, y + 3) gc:lineTo(x + 7, y + 7)
  gc:moveTo(x - 3, y - 1) gc:lineTo(x + 1, y - 1)
end

-- Settings: a cog.
function DRAW.gear(gc, x, y)
  gc:oval(Rectangle(x - 3, y - 3, 6, 6))
  for i = 0, 7 do
    local a = i * pi / 4
    local c, s = cos(a), sin(a)
    gc:moveTo(x + c * 4, y + s * 4) gc:lineTo(x + c * 7, y + s * 7)
  end
  arc(gc, x, y, 5, 0, pi * 2, 12)
end

-- Help: a question mark.
function DRAW.help(gc, x, y)
  gc:moveTo(x - 3, y - 3)
  arc(gc, x, y - 3, 3, pi, pi * 2.5, 8, true)
  gc:lineTo(x, y + 2)
  gc:moveTo(x, y + 4) gc:lineTo(x, y + 6)
end

-- Into the sprite: an arrow down into a tray.
function DRAW.export(gc, x, y)
  gc:moveTo(x - 6, y + 1) gc:lineTo(x - 6, y + 6) gc:lineTo(x + 6, y + 6) gc:lineTo(x + 6, y + 1)
  gc:moveTo(x, y - 7) gc:lineTo(x, y + 3)
  gc:moveTo(x - 3, y) gc:lineTo(x, y + 3) gc:lineTo(x + 3, y)
end

function DRAW.close(gc, x, y)
  gc:moveTo(x - 4, y - 4) gc:lineTo(x + 4, y + 4)
  gc:moveTo(x + 4, y - 4) gc:lineTo(x - 4, y + 4)
end

-- The foreground colour taken into the swatch, or the swatch given to it.
function DRAW.fgTake(gc, x, y)
  box(gc, x + 1, y - 6, x + 7, y)
  gc:moveTo(x + 1, y + 1) gc:lineTo(x - 5, y + 7)
  gc:moveTo(x - 5, y + 3) gc:lineTo(x - 5, y + 7) gc:lineTo(x - 1, y + 7)
end

function DRAW.fgGive(gc, x, y)
  box(gc, x + 1, y - 6, x + 7, y)
  gc:moveTo(x - 5, y + 7) gc:lineTo(x + 1, y + 1)
  gc:moveTo(x - 3, y + 1) gc:lineTo(x + 1, y + 1) gc:lineTo(x + 1, y + 5)
end

function Icons.has(name)
  return DRAW[name] ~= nil
end

function Icons.draw(gc, name, x, y, color)
  local fn = DRAW[name]
  if not fn then return end
  x, y = floor(x), floor(y)
  gc.color = color or Icons.COLOR
  gc.strokeWidth = 1
  gc:beginPath()
  fn(gc, x, y)
  gc:stroke()
end

return Icons
