-- Editing the guide rods (Guide) on the preview.
--
--   drag on the water        a new rod; the water runs the way you drag
--   drag a dot               bends the rod (an end dot: longer, shorter)
--   drag the line            a new dot there, bending it
--   Shift + drag an end dot  a new dot past it: the rod grows longer
--   Alt + drag the line      a branch from there ("Branch" does the same)
--   right click a dot        takes it away; the line: the whole rod
--   click                    (nothing dragged) left to the preview: pause
--
-- New rods are of the kind picked (flow rods steer the water; lip rods
-- draw the edge a fall goes over, and grow no branches).
--
-- The rods are kept in sprite px. `M` maps them onto the canvas: the
-- scale s, where the view's corner is drawn (ox, oy) and the view itself
-- (x, y, w, h, in sprite px).

local G = ... or _WOWE

local Guide = G.require("guide")

local Rods = {}
Rods.__index = Rods

local floor, abs, max, min = math.floor, math.abs, math.max, math.min

local DOT, NEAR, MOVED = 5, 5, 3   -- canvas px: a dot's reach, a line's, a drag's start
local KEEP = 40                    -- steps Undo goes back

-- get(): the rods; set(list): puts a new list in their place.
function Rods.new(get, set)
  return setmetatable({ get = get, set = set, sel = nil, hover = nil, drag = nil, branch = false,
                        history = {}, kind = "flow" }, Rods)
end

-- Forgets the selection and the steps back (another sprite).
function Rods:reset()
  self.sel, self.hover, self.drag, self.branch, self.before = nil, nil, nil, false, nil
  self.history = {}
end

local function toCanvas(M, x, y)
  return M.ox + (x - M.x) * M.s, M.oy + (y - M.y) * M.s
end

local function toSprite(M, cx, cy, free)
  local x, y = M.x + (cx - M.ox) / M.s, M.y + (cy - M.oy) / M.s
  if free then return x, y end
  return max(M.x, min(M.x + M.w, x)), max(M.y, min(M.y + M.h, y))
end
Rods.toCanvas, Rods.toSprite = toCanvas, toSprite

-- What is under the mouse: a dot { rod, pt }, a line { rod, at, x, y,
-- span } or nil.
function Rods:hit(M, cx, cy)
  local rods = self.get()
  local best, bd = nil, DOT + 0.5
  for i = #rods, 1, -1 do
    local r = rods[i]
    for k = 1, #r.pts // 2 do
      local hx, hy = toCanvas(M, r.pts[k * 2 - 1], r.pts[k * 2])
      local d = max(abs(hx - cx), abs(hy - cy))
      if d < bd or (d == bd and i == self.sel) then best, bd = { rod = i, pt = k }, d end
    end
  end
  if best then return best end
  local sx, sy = toSprite(M, cx, cy, true)
  local lim = NEAR / M.s
  for i = #rods, 1, -1 do
    local d, at, px, py, span = Guide.nearest(Guide.chain(rods[i]), sx, sy)
    if d <= lim and (not best or d < best.d) then
      best = { rod = i, at = at, x = px, y = py, span = span, d = d }
    end
  end
  return best
end

local function same(a, b)
  if a == nil or b == nil then return a == b end
  return a.rod == b.rod and a.pt == b.pt
end

-- Keeps the rods as they were, for Undo.
function Rods:remember(list)
  local h = self.history
  h[#h + 1] = list or Guide.copy(self.get())
  if #h > KEEP then table.remove(h, 1) end
end

-- Mouse down on the preview. Returns nil (not for the rods), "edit"
-- (dragging; paint again) or "changed" (the rods changed: bake again).
function Rods:mousedown(ev, M)
  local rods = self.get()
  local h = self:hit(M, ev.x, ev.y)
  self.before = Guide.copy(rods)
  if ev.button == MouseButton.RIGHT then
    if not h then return nil end
    local r = rods[h.rod]
    if h.pt and #r.pts > 4 then
      table.remove(r.pts, h.pt * 2 - 1)
      table.remove(r.pts, h.pt * 2 - 1)
      -- Its first dot gone, a branch comes off its parent.
      if h.pt == 1 then r.parent, r.at = nil, nil end
    else
      rods = Guide.remove(rods, h.rod)
      self.set(rods)
      self.sel = nil
    end
    Guide.attach(rods)
    self:remember(self.before)
    self.hover, self.before = nil, nil
    return "changed"
  end
  if h and h.pt then
    local r = rods[h.rod]
    local n = #r.pts // 2
    local pt = h.pt
    if ev.shiftKey and pt == n then
      -- Past the end: a new last dot.
      r.pts[#r.pts + 1] = r.pts[n * 2 - 1]
      r.pts[#r.pts + 1] = r.pts[n * 2]
      pt = n + 1
    elseif ev.shiftKey and pt == 1 and not r.parent then
      -- Before the start: a new first dot.
      table.insert(r.pts, 1, r.pts[2])
      table.insert(r.pts, 1, r.pts[2])
      pt = 1
    end
    self.drag = { rod = h.rod, pt = pt }
    self.sel = h.rod
  elseif h then
    if (ev.altKey or self.branch) and not rods[h.rod].kind then
      rods[#rods + 1] = { pts = { h.x, h.y, h.x, h.y }, parent = h.rod, at = h.at }
      self.drag = { rod = #rods, pt = 2 }
      self.sel = #rods
      self.branch = false
    else
      local r = rods[h.rod]
      local at = h.span * 2 + 1
      table.insert(r.pts, at, h.y)
      table.insert(r.pts, at, h.x)
      self.drag = { rod = h.rod, pt = h.span + 1 }
      self.sel = h.rod
    end
  else
    -- Nothing here: a new rod once the mouse moves (a click pauses).
    self.drag = { new = true, cx = ev.x, cy = ev.y }
    self.sel = nil
  end
  return "edit"
end

-- Mouse moved. True when the preview should be painted again.
function Rods:mousemove(ev, M)
  local d = self.drag
  if not d then
    local h = self:hit(M, ev.x, ev.y)
    if h and not h.pt then h = { rod = h.rod } end
    if not same(h, self.hover) then
      self.hover = h
      return true
    end
    return false
  end
  local rods = self.get()
  if d.new then
    if max(abs(ev.x - d.cx), abs(ev.y - d.cy)) < MOVED then return false end
    local x1, y1 = toSprite(M, d.cx, d.cy)
    local x2, y2 = toSprite(M, ev.x, ev.y)
    rods[#rods + 1] = { pts = { x1, y1, x2, y2 }, kind = (self.kind == "lip") and "lip" or nil }
    self.drag = { rod = #rods, pt = 2 }
    self.sel = #rods
    return true
  end
  local r = rods[d.rod]
  if not r then
    self.drag = nil
    return true
  end
  local x, y = toSprite(M, ev.x, ev.y)
  local par = r.parent and rods[r.parent]
  if d.pt == 1 and par then
    -- A branch's first dot slides along its parent.
    local _, at = Guide.nearest(Guide.chain(par), x, y)
    r.at = at
  else
    r.pts[d.pt * 2 - 1], r.pts[d.pt * 2] = x, y
    if d.pt == 1 or d.pt == #r.pts // 2 then
      -- An end moved (the rod longer or shorter): its branches stay where
      -- they join it. A dot in between bends it: they move along.
      local c = Guide.chain(r)
      for _, b in ipairs(rods) do
        if b.parent == d.rod then
          local _, at = Guide.nearest(c, b.pts[1], b.pts[2])
          b.at = at
        end
      end
    end
  end
  Guide.attach(rods)
  return true
end

-- Mouse up. Returns nil (not dragging), "click" (pressed and let go on
-- the water without moving: for the preview), "edit" (paint again) or
-- "changed" (bake again).
function Rods:mouseup()
  local d = self.drag
  self.drag = nil
  if not d then return nil end
  if d.new then
    self.before = nil
    return "click"
  end
  local before = self.before
  self.before = nil
  if before and Guide.signature(before) ~= Guide.signature(self.get()) then
    self:remember(before)
    return "changed"
  end
  return "edit"
end

-- Back one step. True when there was one.
function Rods:undo()
  local h = self.history
  if #h == 0 then return false end
  self.set(Guide.copy(h[#h]))
  h[#h] = nil
  self.sel, self.hover, self.drag = nil, nil, nil
  return true
end

-- The selected rod (or the only one) the other way round. True when one
-- was turned.
function Rods:reverse()
  local rods = self.get()
  local i = self.sel or ((#rods == 1) and 1 or nil)
  if not (i and rods[i]) then return false end
  self:remember()
  Guide.reverse(rods, i)
  return true
end

-- Every rod gone. True when there were any.
function Rods:clear()
  if #self.get() == 0 then return false end
  self:remember()
  self.set({})
  self.sel, self.hover, self.drag = nil, nil, nil
  return true
end

--------------------------------------------------------------------------
-- drawing
--------------------------------------------------------------------------

local function rgb(r, g, b, a) return Color{ r = r, g = g, b = b, a = a or 255 } end

local EDGE = rgb(10, 14, 20, 170)
local LINE = rgb(150, 236, 246)
local LINE_HOT = rgb(225, 250, 255)
local LINE_SEL = rgb(255, 214, 110)
local BRANCH = rgb(200, 160, 255)
local LIP = rgb(255, 150, 90)

-- The curve through canvas points.
local function path(gc, xs, ys)
  gc:beginPath()
  gc:moveTo(xs[1], ys[1])
  for k = 2, #xs do gc:lineTo(xs[k], ys[k]) end
  gc:stroke()
end

-- A chevron at (x, y) pointing along (ux, uy).
local function chevron(gc, x, y, ux, uy, size)
  local bx, by = x - ux * size, y - uy * size
  local nx, ny = -uy * size * 0.7, ux * size * 0.7
  gc:beginPath()
  gc:moveTo(bx + nx, by + ny)
  gc:lineTo(x, y)
  gc:lineTo(bx - nx, by - ny)
  gc:stroke()
end

function Rods:draw(gc, M)
  local rods = self.get()
  if #rods == 0 then return end
  gc.antialias = true
  local hotRod = self.hover and self.hover.rod
  for i, r in ipairs(rods) do
    local c = Guide.chain(r)
    local n = #c.xs
    if n >= 2 then
      local xs, ys = {}, {}
      for k = 1, n do xs[k], ys[k] = toCanvas(M, c.xs[k], c.ys[k]) end
      local lip = r.kind == "lip"
      local color = (i == self.sel) and LINE_SEL or ((i == hotRod) and LINE_HOT
        or (lip and LIP or (r.parent and BRANCH or LINE)))
      -- A flow rod: which way the water goes, an arrow at the end and
      -- chevrons on the way. A lip rod: short ticks hanging down, where
      -- the water goes over.
      local marks, ticks = {}, {}
      if lip then
        local count = floor(c.len * M.s / 10)
        for q = 0, count do
          local x, y = Guide.pointAt(c, (count > 0) and q / count or 0)
          local mx, my = toCanvas(M, x, y)
          ticks[#ticks + 1] = { mx, my }
        end
      else
        local count = floor(c.len * M.s / 38)
        for q = 1, count do
          local x, y, ux, uy = Guide.pointAt(c, (q - 0.5) / count)
          local mx, my = toCanvas(M, x, y)
          marks[#marks + 1] = { mx, my, ux, uy }
        end
      end
      for pass = 1, 2 do
        gc.color = (pass == 1) and EDGE or color
        gc.strokeWidth = (pass == 1) and 4 or 2
        path(gc, xs, ys)
        for _, m in ipairs(marks) do chevron(gc, m[1], m[2], m[3], m[4], 4) end
        if lip then
          for _, m in ipairs(ticks) do
            gc:beginPath()
            gc:moveTo(m[1], m[2])
            gc:lineTo(m[1], m[2] + 5)
            gc:stroke()
          end
        else
          chevron(gc, xs[n], ys[n], c.tx[n], c.ty[n], 6)
        end
      end
    end
  end
  gc.antialias = false
  gc.strokeWidth = 1
  -- The dots.
  for i, r in ipairs(rods) do
    for k = 1, #r.pts // 2 do
      local hx, hy = toCanvas(M, r.pts[k * 2 - 1], r.pts[k * 2])
      local x, y = floor(hx + 0.5), floor(hy + 0.5)
      local hot = self.hover and self.hover.rod == i and self.hover.pt == k
      gc.color = EDGE
      gc:fillRect(Rectangle(x - 3, y - 3, 7, 7))
      gc.color = hot and rgb(255, 255, 255) or ((i == self.sel) and LINE_SEL
        or ((r.kind == "lip") and LIP or ((k == 1 and r.parent) and BRANCH or LINE)))
      gc:fillRect(Rectangle(x - 2, y - 2, 5, 5))
      if not hot then
        gc.color = rgb(20, 30, 40)
        gc:fillRect(Rectangle(x - 1, y - 1, 3, 3))
      end
    end
  end
end

return Rods
