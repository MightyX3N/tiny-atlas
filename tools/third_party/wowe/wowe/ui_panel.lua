-- Settings drawn on a canvas.
--
-- A panel fills a part of a window's canvas: icon tabs across its top, then
-- the settings of the open tab, which scroll with the wheel. Nothing is
-- built once and kept: every paint lays the panel out again from the
-- settings (an immediate-mode GUI), so a change made anywhere shows at
-- once.
--
-- A panel is given two functions: header(ui) for the part that stays put
-- (the tabs) and build(ui) for the part that scrolls. They call the widgets
-- below, which lay themselves out top to bottom, draw themselves and leave
-- a box for the mouse. Each paint runs build twice: once to measure
-- (nothing drawn), so the scroll can be kept in range, then to draw.
--
-- Mouse:  sliders follow the mouse (Shift: fine), double click types a
--         value, the arrow keys nudge the slider under the mouse. A colour
--         opens the colour picker by it (right click: the foreground
--         colour). Every setting tells what it does when the mouse rests
--         on it.

local G = ... or _WOWE

local Style = G.require("ui_style")
local Icons = G.require("ui_icons")
local I18n  = G.require("i18n")

local Panel = {}
Panel.__index = Panel

local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local C = Style
local fillRect, fillRound, frame = Style.fillRect, Style.fillRound, Style.frame
local text, textMid, textCenter = Style.text, Style.textMid, Style.textCenter
local measure, fit, clamp = Style.measure, Style.fit, Style.clamp

-- Side margins (the right one leaves room for the scroll bar), a row's
-- height, the gap under every widget and the room above a section.
local PAD_L, PAD_R, ROW, GAP, SEC_TOP = 8, 12, 18, 4, 10
Panel.ROW, Panel.GAP = ROW, GAP
local HEAD_TOP, HEAD_BOTTOM, CONTENT_TOP, CONTENT_BOTTOM = 6, 6, 6, 12
local SCROLL_STEP = 36

local function rgb(r, g, b, a) return Color{ r = r, g = g, b = b, a = a or 255 } end

--------------------------------------------------------------------------
-- Colours: HSV
--------------------------------------------------------------------------

local function toHsv(c)
  local r, g, b = c.red / 255, c.green / 255, c.blue / 255
  local mx, mn = max(r, g, b), min(r, g, b)
  local d = mx - mn
  local h = 0
  if d > 0 then
    if mx == r then h = ((g - b) / d) % 6
    elseif mx == g then h = ((b - r) / d) + 2
    else h = ((r - g) / d) + 4 end
    h = h * 60
  end
  return h % 360, (mx == 0) and 0 or d / mx, mx
end

local function fromHsvRgb(h, s, v)
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

local function fromHsv(h, s, v)
  local r, g, b = fromHsvRgb(h, s, v)
  return rgb(r, g, b)
end

local function copyColor(c)
  if not c then return nil end
  return rgb(c.red, c.green, c.blue, c.alpha or 255)
end
Panel.copyColor = copyColor

--------------------------------------------------------------------------
-- The layout context: one per pass of a paint
--------------------------------------------------------------------------

local UI = {}
UI.__index = UI

local function newUi(panel, gc, region, drawing, y, top, bottom)
  return setmetatable({
    panel = panel, gc = gc, drawing = drawing, region = region,
    x = region.x + PAD_L, w = max(40, region.w - PAD_L - PAD_R), y = y,
    top = top, bottom = bottom, items = panel.newItems, first = true,
  }, UI)
end

-- Takes a box h high across the panel and moves on below it.
function UI:take(h)
  local y = self.y
  self.y = y + h + GAP
  self.first = false
  return self.x, y, self.w
end

function UI:space(h)
  self.y = self.y + (h or GAP)
end

-- True when a box starting at y, h high, is drawn this pass.
function UI:shows(y, h)
  return self.drawing and y + h > self.top and y < self.bottom
end

-- Leaves a box for the mouse (draw pass only).
function UI:add(item)
  if not self.drawing then return item end
  item.clip, item.clipB = self.top, self.bottom
  self.items[#self.items + 1] = item
  return item
end

function UI:isHover(id)
  local p = self.panel
  if p.drag then return p.drag.id == id end
  return p.hover == id
end

function UI:isPressed(id)
  local p = self.panel
  return p.drag ~= nil and p.drag.id == id
end

local function drawSwitch(gc, x, y, on, hot)
  local sw, sh = 24, 12
  fillRound(gc, x, y, sw, sh, 5, on and C.FILL_HI or (hot and C.KNOB_OFF or C.FIELD_HI))
  local kx = on and (x + sw - sh + 2) or (x + 2)
  fillRound(gc, kx, y + 2, sh - 4, sh - 4, 3, on and C.KNOB or C.KNOB_OFF)
end

-- A section title: accent text and a line to the right edge. With sw =
-- { id, get, set, tip } a switch sits at the line's right end and the whole
-- line flips it (the tide, clean pixel art, the rods).
function UI:section(label, sw)
  if not self.first then self.y = self.y + SEC_TOP end
  local h = sw and ROW or 12
  local x, y, w = self:take(h)
  if not self.drawing then return end
  local gc = self.gc
  local swW = sw and 28 or 0
  if sw then
    self:add{ id = sw.id, x = x, y = y, w = w, h = h, tip = sw.tip,
      click = function() sw.set(not (sw.get() and true or false)) end }
  end
  if not self:shows(y, h) then return end
  local hot = sw and self:isHover(sw.id)
  if hot then fillRound(gc, x - 2, y, w + 4, h, 3, C.FIELD) end
  local s = fit(gc, label, w - 16 - swW)
  local tw = measure(gc, s)
  local on = (not sw) or (sw.get() and true or false)
  textMid(gc, s, x, y, h, on and C.ACCENT or C.TEXT_DIM)
  fillRect(gc, x + tw + 6, y + floor(h / 2), w - tw - 6 - swW - (sw and 4 or 0), 1, C.LINE)
  if sw then drawSwitch(gc, x + w - 24, y + floor((h - 12) / 2), on, hot) end
end

-- Dim text across the panel, wrapped.
function UI:hint(s)
  local lines = Style.wrap(self.gc, s, self.w)
  local _, th = measure(self.gc, "Ag")
  local lh = th + 2
  local x, y = self:take(#lines * lh)
  if not self:shows(y, #lines * lh) then return end
  for i, line in ipairs(lines) do
    text(self.gc, line, x, y + (i - 1) * lh, C.TEXT_DIM)
  end
end

-- A caption over a widget: dim text on its own short line.
function UI:caption(s)
  local x, y, w = self.x, self.y, self.w
  self.y = y + 13
  self.first = false
  if self:shows(y, 13) then
    textMid(self.gc, fit(self.gc, s, w), x, y, 13, C.TEXT_DIM)
  end
end

--------------------------------------------------------------------------
-- Slider
--------------------------------------------------------------------------

-- A value bar: the label on the left, the value on the right, the bar
-- filled up to the value.
-- s: { id, label, min, max, get, set, step, suffix, fmt(v), dim, tip }
-- step: the values it takes (min, min + step, ...); fmt: how the value is
-- written (else the number and suffix); dim: drawn faded (its part is
-- switched off), still movable.
function UI:slider(s)
  local x, y, w = self:take(ROW)
  if not self.drawing then return end
  local panel, gc = self.panel, self.gc
  local id = s.id
  local mn, mx = s.min, s.max
  local range = max(1, mx - mn)
  local step = s.step or 1

  local function valueAt(ev)
    return mn + (ev.x - x - 2) / max(1, w - 4) * range
  end

  local function setTo(v)
    v = mn + floor((v - mn) / step + 0.5) * step
    v = clamp(v, mn, mx)
    if v ~= s.get() then s.set(v) end
  end

  local function shown(v)
    if s.fmt then return s.fmt(v) end
    return tostring(floor(v + 0.5)) .. (s.suffix or "")
  end

  local item = self:add{
    id = id, x = x, y = y, w = w, h = ROW, tip = s.tip, slider = true,
    setValue = setTo,
    down = function(ev)
      panel:notePress(id, s.get())
      if ev.shiftKey then
        return { fine = true, x0 = ev.x, v0 = s.get() }
      end
      setTo(valueAt(ev))
      return {}
    end,
    dbl = function()
      panel:revertPress(id, function(v) setTo(v) end)
      panel:startEdit(id, tostring(floor((s.get() or mn) + 0.5)), "num", function(t)
        local v = tonumber((t:gsub(",", ".")))
        if v then setTo(v) end
      end)
    end,
    key = function(ev)
      local code = ev.code or ""
      local k = (ev.shiftKey and 5 or 1) * step
      if code == "ArrowLeft" or code == "ArrowDown" then setTo(s.get() - k) return true end
      if code == "ArrowRight" or code == "ArrowUp" then setTo(s.get() + k) return true end
      return false
    end,
  }
  -- A drag follows the mouse; with Shift it moves a tenth as fast from
  -- where Shift was pressed, and taking Shift off goes back to following.
  item.drag = function(ev, d)
    if ev.shiftKey then
      if not d.fine then d.fine, d.x0, d.v0 = true, ev.x, s.get() end
      setTo(d.v0 + (ev.x - d.x0) / max(1, w) * range / 10)
    else
      d.fine = false
      setTo(valueAt(ev))
    end
  end

  if not self:shows(y, ROW) then return end
  local hot = self:isHover(id)
  local editing = panel.edit and panel.edit.id == id
  local v = s.get() or mn
  fillRound(gc, x, y, w, ROW, 3, hot and C.FIELD_HI or C.FIELD)
  if editing then
    frame(gc, x, y, w, ROW, C.FILL_HI)
    local t = panel.edit.text
    textMid(gc, t, x + 6, y, ROW, C.TEXT)
    fillRect(gc, x + 7 + measure(gc, t), y + 4, 1, ROW - 8, C.TEXT)
    return
  end
  local b = floor(x + (clamp(v, mn, mx) - mn) / range * w + 0.5)
  local fillC = s.dim and C.FILL_OFF or ((hot or self:isPressed(id)) and C.FILL_HI or C.FILL)
  if b - x >= 8 then fillRound(gc, x, y, b - x, ROW, 3, fillC)
  else fillRect(gc, x, y + 1, b - x, ROW - 2, fillC) end
  local vs = shown(v)
  local vw = measure(gc, vs)
  local ink = s.dim and C.TEXT_DIM or C.TEXT
  textMid(gc, fit(gc, s.label, w - vw - 18), x + 6, y, ROW, ink)
  textMid(gc, vs, x + w - 6 - vw, y, ROW, s.dim and C.TEXT_DIM or C.WHITE)
end

-- A direction: the label on the left, the way written and an arrow in a
-- ring on the right; a drag on the ring turns it (steps of 15 degrees).
-- s: { id, label, get, set, dim, tip }
local DIAL_H = 26
local WAYS = { [0] = "way_right", [90] = "way_down", [180] = "way_left", [270] = "way_up" }

function UI:dial(s)
  local x, y, w = self:take(DIAL_H)
  if not self.drawing then return end
  local gc, id = self.gc, s.id
  local r = floor(DIAL_H / 2) - 1
  local cx, cy = x + w - r - 3, y + floor(DIAL_H / 2)
  local function setAt(ev)
    local dx, dy = ev.x - cx, ev.y - cy
    if dx * dx + dy * dy < 4 then return end
    local v = floor(math.deg(math.atan(dy, dx)) / 15 + 0.5) * 15 % 360
    if v ~= s.get() then s.set(v) end
  end
  local item = self:add{ id = id, x = x, y = y, w = w, h = DIAL_H, tip = s.tip,
    setValue = function(v) s.set(floor(v / 15 + 0.5) * 15 % 360) end,
    down = function(ev) setAt(ev) return {} end,
    key = function(ev)
      local code = ev.code or ""
      if code == "ArrowLeft" or code == "ArrowDown" then s.set((s.get() + 345) % 360) return true end
      if code == "ArrowRight" or code == "ArrowUp" then s.set((s.get() + 15) % 360) return true end
      return false
    end }
  item.drag = function(ev) setAt(ev) end
  if not self:shows(y, DIAL_H) then return end
  local hot = self:isHover(id)
  if hot then fillRound(gc, x, y, w, DIAL_H, 3, C.FIELD) end
  local a = s.get() or 0
  local ink = s.dim and C.TEXT_DIM or C.TEXT
  textMid(gc, fit(gc, s.label, w - 2 * r - 70), x + 6, y, DIAL_H, ink)
  local way = WAYS[a] and I18n.t(WAYS[a]) or (a .. "\u{B0}")
  local ww = measure(gc, way)
  textMid(gc, way, cx - r - 8 - ww, y, DIAL_H, ink)
  gc.antialias = true
  gc.strokeWidth = 1
  gc.color = hot and C.KNOB_OFF or C.FIELD_HI
  gc:beginPath()
  gc:oval(Rectangle(cx - r, cy - r, 2 * r, 2 * r))
  gc:stroke()
  local rad = math.rad(a)
  local ca, sa = math.cos(rad), math.sin(rad)
  local ex, ey = cx + ca * (r - 3), cy + sa * (r - 3)
  gc.color = s.dim and C.KNOB_OFF or C.ACCENT
  gc.strokeWidth = 2
  gc:beginPath()
  gc:moveTo(cx - ca * (r - 5), cy - sa * (r - 5))
  gc:lineTo(ex, ey)
  gc:moveTo(ex, ey)
  gc:lineTo(ex - math.cos(rad - 0.6) * 5, ey - math.sin(rad - 0.6) * 5)
  gc:moveTo(ex, ey)
  gc:lineTo(ex - math.cos(rad + 0.6) * 5, ey - math.sin(rad + 0.6) * 5)
  gc:stroke()
  gc.antialias = false
  gc.strokeWidth = 1
end

--------------------------------------------------------------------------
-- Toggle, choice, buttons, chips
--------------------------------------------------------------------------

-- A switch on the right of its label; the whole row flips it.
-- s: { id, label, get, set, tip }
function UI:toggle(s)
  local x, y, w = self:take(ROW)
  if not self.drawing then return end
  local gc, id = self.gc, s.id
  local on = s.get() and true or false
  self:add{ id = id, x = x, y = y, w = w, h = ROW, tip = s.tip,
    click = function() s.set(not (s.get() and true or false)) end }
  if not self:shows(y, ROW) then return end
  local hot = self:isHover(id)
  if hot then fillRound(gc, x, y, w, ROW, 3, C.FIELD) end
  drawSwitch(gc, x + w - 28, y + floor((ROW - 12) / 2), on, false)
  textMid(gc, fit(gc, s.label, w - 40), x + 4, y, ROW, on and C.TEXT or C.TEXT_DIM)
end

-- Segments side by side, one of them picked; with a label, it takes the
-- row's left part.
-- s: { id, label, options = { { value, text, icon, tip } }, get, set, tip, dim }
function UI:choice(s)
  local x, y, w = self:take(ROW)
  if not self.drawing then return end
  local gc = self.gc
  local show = self:shows(y, ROW)
  if s.label then
    local lw = floor(w * 0.34)
    if show then textMid(gc, fit(gc, s.label, lw - 6), x + 4, y, ROW, s.dim and C.TEXT_DIM or C.TEXT) end
    x, w = x + lw, w - lw
  end
  local n = #s.options
  local cur = s.get()
  if show then fillRound(gc, x, y, w, ROW, 3, C.FIELD) end
  local sx = x
  for i, o in ipairs(s.options) do
    local sw = (i == n) and (x + w - sx) or floor(w / n)
    local id = s.id .. ":" .. tostring(o.value)
    local on = (o.value == cur)
    local item = self:add{ id = id, x = sx, y = y, w = sw, h = ROW, tip = o.tip or s.tip,
      click = function() if s.get() ~= o.value then s.set(o.value) end end }
    if show then
      local hot = self:isHover(id)
      if on or hot then
        fillRound(gc, sx + 1, y + 1, sw - 2, ROW - 2, 3,
          on and (s.dim and C.FILL_OFF or C.FILL_HI) or C.FIELD_HI)
      end
      if o.icon then
        Icons.draw(gc, o.icon, sx + sw / 2, y + ROW / 2, on and C.WHITE or C.TEXT)
        item.tip = item.tip or o.text
      else
        local label = o.text or tostring(o.value)
        local ls = fit(gc, label, sw - 8)
        if ls ~= label then item.tip = item.tip or label end
        textCenter(gc, ls, sx, y, sw, ROW, on and C.WHITE or C.TEXT)
      end
      if i < n and not on and s.options[i + 1].value ~= cur then
        fillRect(gc, sx + sw, y + 4, 1, ROW - 8, C.LINE)
      end
    end
    sx = sx + sw
  end
end

-- Buttons side by side, sharing the row.
-- list: { { id, text, icon, tip, click, on, dim } }
function UI:buttons(list)
  local x, y, w = self:take(ROW + 2)
  if not self.drawing then return end
  local gc = self.gc
  local n = #list
  local gap = 4
  local bw = floor((w - gap * (n - 1)) / n)
  local show = self:shows(y, ROW + 2)
  for i, b in ipairs(list) do
    local bx = x + (i - 1) * (bw + gap)
    local ww = (i == n) and (x + w - bx) or bw
    local item = self:add{ id = b.id, x = bx, y = y, w = ww, h = ROW + 2, tip = b.tip,
      click = function() if not b.dim then b.click() end end }
    if show then
      local hot = self:isHover(b.id) and not b.dim
      local fillC = b.on and C.FILL_HI or (hot and C.FIELD_HI or C.FIELD)
      fillRound(gc, bx, y, ww, ROW + 2, 3, fillC)
      local ink = b.dim and C.TEXT_DIM or C.TEXT
      local label = b.text or ""
      local iconW = b.icon and 16 or 0
      local ls = fit(gc, label, ww - iconW - 10)
      if ls ~= label and not b.tip then item.tip = label end
      local lw = (ls ~= "") and measure(gc, ls) or 0
      local total = iconW + ((lw > 0 and iconW > 0) and 3 or 0) + lw
      local cx = bx + floor((ww - total) / 2)
      if b.icon then
        Icons.draw(gc, b.icon, cx + 7, y + (ROW + 2) / 2, ink)
        cx = cx + iconW + 3
      end
      if lw > 0 then textMid(gc, ls, cx, y, ROW + 2, ink) end
    end
  end
end

-- Small buttons that wrap onto more lines: one of them is on.
-- s: { id, items = { { value, text, tip, on } }, select(value) }
function UI:chips(s)
  local gc = self.gc
  local x0, w = self.x, self.w
  local boxes = {}
  local cx, line = x0, 0
  for i, c in ipairs(s.items) do
    local cw = max(ROW + 2, measure(gc, c.text) + 14)
    if cx > x0 and cx + cw > x0 + w then cx, line = x0, line + 1 end
    boxes[i] = { x = cx, line = line, w = min(cw, w), c = c }
    cx = cx + cw + 3
  end
  local lines = line + 1
  local h = lines * (ROW + 2) + (lines - 1) * 3
  local _, y = self:take(h)
  if not self.drawing then return end
  local show = self:shows(y, h)
  for _, b in ipairs(boxes) do
    local by = y + b.line * (ROW + 5)
    local id = s.id .. ":" .. tostring(b.c.value)
    local item = self:add{ id = id, x = b.x, y = by, w = b.w, h = ROW + 2, tip = b.c.tip,
      click = function() s.select(b.c.value) end }
    if show then
      local hot = self:isHover(id)
      fillRound(gc, b.x, by, b.w, ROW + 2, 3, b.c.on and C.FILL_HI or (hot and C.FIELD_HI or C.FIELD))
      local ls = fit(gc, b.c.text, b.w - 8)
      if ls ~= b.c.text then item.tip = item.tip or b.c.text end
      textCenter(gc, ls, b.x, by, b.w, ROW + 2, b.c.on and C.WHITE or C.TEXT)
    end
  end
end

--------------------------------------------------------------------------
-- Colours
--------------------------------------------------------------------------

-- Colour swatches in a row; a click opens the picker under one, a right
-- click takes the foreground colour.
-- s: { id, count, get(i) -> Color, set(i, Color), name(i), take(i) }
function UI:swatches(s)
  local x, y, w = self:take(ROW + 4)
  if not self.drawing then return end
  local gc, panel = self.gc, self.panel
  local n = s.count
  local gap = 3
  local sw = floor((w - gap * (n - 1)) / n)
  local show = self:shows(y, ROW + 4)
  for i = 1, n do
    local sx = x + (i - 1) * (sw + gap)
    local ww = (i == n) and (x + w - sx) or sw
    local id = s.id .. ":" .. i
    local c = s.get(i)
    local name = s.name and s.name(i) or nil
    self:add{ id = id, x = sx, y = y, w = ww, h = ROW + 4, opensPicker = true,
      tip = (name and (name .. "  ") or "") .. Style.hexOf(c),
      setValue = function(col) s.set(i, col) end,
      rclick = s.take and function() s.take(i) end or nil,
      click = function()
        panel:openPicker{ id = id, title = name,
          get = function() return s.get(i) end,
          set = function(col) s.set(i, col) end,
          done = s.done,
          anchor = { x = sx, y = y, w = ww, h = ROW + 4 } }
      end }
    if show then
      Style.swatch(gc, sx, y, ww, ROW + 4, c)
      local open = panel.picker and panel.picker.id == id
      if open or self:isHover(id) then
        frame(gc, sx, y, ww, ROW + 4, open and C.WHITE or C.KNOB_OFF)
        if open then frame(gc, sx + 1, y + 1, ww - 2, ROW + 2, C.BLACK) end
      end
    end
  end
end

-- One colour with its label on the left. s: { id, label, get, set, take, tip }
function UI:colorRow(s)
  local x, y, w = self:take(ROW + 2)
  if not self.drawing then return end
  local gc, panel = self.gc, self.panel
  local id = s.id
  local sw = floor(w * 0.5)
  local sx = x + w - sw
  local c = s.get()
  self:add{ id = id, x = x, y = y, w = w, h = ROW + 2, tip = s.tip or (s.label .. "  " .. Style.hexOf(c)),
    opensPicker = true,
    setValue = function(col) s.set(col) end,
    rclick = s.take,
    click = function()
      panel:openPicker{ id = id, title = s.label, get = s.get, set = s.set, done = s.done,
        anchor = { x = sx, y = y, w = sw, h = ROW + 2 } }
    end }
  if not self:shows(y, ROW + 2) then return end
  textMid(gc, fit(gc, s.label, w - sw - 8), x + 4, y, ROW + 2, C.TEXT)
  Style.swatch(gc, sx, y, sw, ROW + 2, c)
  local open = panel.picker and panel.picker.id == id
  if open or self:isHover(id) then
    frame(gc, sx, y, sw, ROW + 2, open and C.WHITE or C.KNOB_OFF)
  end
  if c then textCenter(gc, Style.hexOf(c), sx, y, sw, ROW + 2, Style.inkOn(c)) end
end

--------------------------------------------------------------------------
-- Header tabs
--------------------------------------------------------------------------

-- Icon tabs across the top; the open one is wider and shows its name.
-- s: { id, items = { { key, icon, text } }, current, select(key) }
function UI:tabs(s)
  local x, y, w = self:take(22)
  if not self.drawing then return end
  local gc = self.gc
  local n = #s.items
  local tw, gap = 26, 2
  local activeW = w - (n - 1) * (tw + gap)
  local wide = activeW >= tw + 30
  if not wide then tw = floor((w - gap * (n - 1)) / n) activeW = tw end
  local tx = x
  for i, t in ipairs(s.items) do
    local on = (t.key == s.current)
    local ww = on and activeW or tw
    if i == n and not wide then ww = x + w - tx end
    local id = s.id .. ":" .. t.key
    local item = self:add{ id = id, x = tx, y = y, w = ww, h = 22,
      click = function() if s.current ~= t.key then s.select(t.key) end end }
    local hot = self:isHover(id)
    fillRound(gc, tx, y, ww, 22, 3, on and C.FILL_HI or (hot and C.FIELD_HI or C.FIELD))
    if on and wide then
      Icons.draw(gc, t.icon, tx + 13, y + 11, C.WHITE)
      local ls = fit(gc, t.text, ww - 32)
      if ls ~= t.text then item.tip = t.text end
      textMid(gc, ls, tx + 26, y, 22, C.WHITE)
    else
      Icons.draw(gc, t.icon, tx + ww / 2, y + 11, on and C.WHITE or C.TEXT)
      item.tip = t.text
    end
    tx = tx + ww + gap
  end
end

--------------------------------------------------------------------------
-- The panel
--------------------------------------------------------------------------

-- o: { header(ui), build(ui), scrollKey() -> string, repaint() }
function Panel.new(o)
  local self = setmetatable({}, Panel)
  self.o = o
  self.items, self.overlay = {}, {}
  self.hover = nil
  self.mx, self.my = -100, -100
  self.drag, self.edit, self.picker = nil, nil, nil
  self.scrolls = {}
  self.headH, self.viewH, self.contentH = 0, 0, 0
  self.region = { x = 0, y = 0, w = 0, h = 0 }
  return self
end

function Panel:repaint()
  if self.o.repaint then self.o.repaint() end
end

-- Forget the mouse, the typing and the picker (the window closes).
function Panel:reset()
  if self.picker then self:closePicker(false) end
  self.drag, self.edit, self.picker, self.hover = nil, nil, nil, nil
  self.press = nil
end

function Panel:scrollKey()
  return (self.o.scrollKey and self.o.scrollKey()) or "main"
end

function Panel:getScroll()
  return self.scrolls[self:scrollKey()] or 0
end

function Panel:setScroll(v)
  local maxS = max(0, self.contentH - self.viewH)
  self.scrolls[self:scrollKey()] = clamp(floor(v + 0.5), 0, maxS)
end

-- The value a slider had before the first click of a double click, so the
-- double click can put it back before the typing starts.
function Panel:notePress(id, value)
  local pr = self.press
  if pr and pr.id == id and pr.fresh then return end
  self.press = { id = id, value = value, fresh = true }
end

function Panel:revertPress(id, apply)
  local pr = self.press
  if pr and pr.id == id and pr.value ~= nil then apply(pr.value) end
  self.press = nil
end

function Panel:agePress()
  local pr = self.press
  if not pr then return end
  if not app.isUIAvailable then
    pr.fresh = false
    return
  end
  local t
  t = Timer{ interval = 0.45, ontick = function()
    if t then t:stop() end
    t = nil
    if self.press == pr then pr.fresh = false end
  end }
  t:start()
end

function Panel:startEdit(id, textValue, kind, apply)
  self.edit = { id = id, text = textValue or "", kind = kind, apply = apply, fresh = true }
  self:repaint()
end

function Panel:commitEdit()
  local e = self.edit
  if not e then return end
  self.edit = nil
  pcall(e.apply, e.text)
  self:repaint()
end

function Panel:isBusy()
  return self.drag ~= nil or self.edit ~= nil or self.picker ~= nil
end

--------------------------------------------------------------------------
-- Colour picker
--------------------------------------------------------------------------

local SV, HUE_W = 110, 12
local svImage, svHue, hueImage = nil, nil, nil

local function svPicture(h)
  h = floor(h + 0.5) % 360
  if svImage and svHue == h then return svImage end
  local img = Image(SV, SV, ColorMode.RGB)
  local pc = app.pixelColor
  for yy = 0, SV - 1 do
    local v = 1 - yy / (SV - 1)
    for xx = 0, SV - 1 do
      local r, g, b = fromHsvRgb(h, xx / (SV - 1), v)
      img:drawPixel(xx, yy, pc.rgba(r, g, b, 255))
    end
  end
  svImage, svHue = img, h
  return img
end

local function huePicture()
  if hueImage then return hueImage end
  local img = Image(HUE_W, SV, ColorMode.RGB)
  local pc = app.pixelColor
  for yy = 0, SV - 1 do
    local r, g, b = fromHsvRgb(360 * yy / SV, 1, 1)
    for xx = 0, HUE_W - 1 do img:drawPixel(xx, yy, pc.rgba(r, g, b, 255)) end
  end
  hueImage = img
  return img
end

-- o: { id, title, get, set, done(), anchor = { x, y, w, h } }
-- done: called once when the picker closes (the colour kept or put back).
function Panel:openPicker(o)
  if self.picker and self.picker.id == o.id then
    self:closePicker(false)
    return
  end
  if self.picker then self:closePicker(false) end
  local c = o.get() or rgb(128, 128, 128)
  local h, s, v = toHsv(c)
  self.picker = { id = o.id, title = o.title, get = o.get, set = o.set, done = o.done, anchor = o.anchor,
                  old = copyColor(c), h = h, s = s, v = v }
  self:repaint()
end

function Panel:closePicker(revert)
  local pk = self.picker
  if not pk then return end
  if revert and pk.old then pk.set(copyColor(pk.old)) end
  self.picker = nil
  if self.edit and self.edit.id == "picker:hex" then self.edit = nil end
  if pk.done then pk.done() end
  self:repaint()
end

function Panel:pickerSet(c, keepHsv)
  local pk = self.picker
  if not pk then return end
  if not keepHsv then
    local h, s, v = toHsv(c)
    -- A grey keeps the hue it had; black keeps the saturation too.
    if s > 0 and v > 0 then pk.h = h end
    if v > 0 then pk.s = s end
    pk.v = v
  end
  pk.set(c)
end

function Panel:isHoverRaw(id)
  if self.drag then return self.drag.id == id end
  return self.hover == id
end

function Panel:drawPicker(gc, W, H)
  local pk = self.picker
  local titleH = pk.title and 14 or 0
  local pw = 8 + SV + 6 + HUE_W + 8
  local ph = 8 + titleH + SV + 8 + ROW + 8
  local a = pk.anchor
  local px = clamp(a.x, 4, max(4, W - pw - 4))
  local py = a.y + a.h + 4
  if py + ph > H - 4 then
    py = a.y - ph - 4
    if py < 4 then py = clamp(H - ph - 4, 4, max(4, H - ph - 4)) end
  end
  self.pickerRect = { x = px, y = py, w = pw, h = ph }
  fillRound(gc, px, py, pw, ph, 4, C.TIP_BG)
  frame(gc, px, py, pw, ph, C.FIELD_HI)
  local items = self.overlay
  local function add(it) items[#items + 1] = it return it end
  -- The picker's own ground takes the mouse from what is under it.
  add{ id = "picker:bg", x = px, y = py, w = pw, h = ph }

  local y0 = py + 8
  if pk.title then
    textMid(gc, fit(gc, pk.title, pw - 16), px + 8, y0 - 2, 14, C.TEXT_DIM)
    y0 = y0 + titleH
  end
  local sx, sy = px + 8, y0
  pcall(function() gc:drawImage(svPicture(pk.h), sx, sy) end)
  local hx = sx + SV + 6
  pcall(function() gc:drawImage(huePicture(), hx, sy) end)

  local mx = sx + floor(pk.s * (SV - 1) + 0.5)
  local my = sy + floor((1 - pk.v) * (SV - 1) + 0.5)
  frame(gc, mx - 3, my - 3, 7, 7, C.WHITE)
  frame(gc, mx - 2, my - 2, 5, 5, C.BLACK)
  local hy = sy + floor(pk.h / 360 * SV + 0.5)
  frame(gc, hx - 2, hy - 2, HUE_W + 4, 5, C.WHITE)
  fillRect(gc, hx - 1, hy - 1, HUE_W + 2, 3, C.BLACK)
  fillRect(gc, hx, hy, HUE_W, 1, C.WHITE)

  local panel = self
  local function svFrom(ev)
    local s = clamp((ev.x - sx) / (SV - 1), 0, 1)
    local v = clamp(1 - (ev.y - sy) / (SV - 1), 0, 1)
    pk.s, pk.v = s, v
    panel:pickerSet(fromHsv(pk.h, s, v), true)
  end
  local function hueFrom(ev)
    pk.h = clamp((ev.y - sy) / SV * 360, 0, 359.99)
    panel:pickerSet(fromHsv(pk.h, pk.s, pk.v), true)
  end
  local sv = add{ id = "picker:sv", x = sx, y = sy, w = SV, h = SV,
    down = function(ev) svFrom(ev) return {} end }
  sv.drag = function(ev) svFrom(ev) end
  local hu = add{ id = "picker:hue", x = hx - 2, y = sy, w = HUE_W + 4, h = SV,
    down = function(ev) hueFrom(ev) return {} end }
  hu.drag = function(ev) hueFrom(ev) end

  -- Old and new colour, the hex code, and the foreground colour buttons.
  local ry = sy + SV + 8
  local cur = pk.get()
  Style.swatch(gc, sx, ry, 18, ROW, pk.old)
  Style.swatch(gc, sx + 18, ry, 18, ROW, cur)
  add{ id = "picker:old", x = sx, y = ry, w = 18, h = ROW, tip = I18n.t("picker_revert"),
    click = function() panel:pickerSet(copyColor(pk.old)) end }
  local hxX, hxW = sx + 40, 52
  local editing = self.edit and self.edit.id == "picker:hex"
  add{ id = "picker:hex", x = hxX, y = ry, w = hxW, h = ROW, tip = I18n.t("picker_hex"),
    click = function()
      panel:startEdit("picker:hex", Style.hexOf(pk.get()):sub(2), "hex", function(t)
        t = t:gsub("[^%x]", "")
        if #t == 3 then t = t:gsub("(%x)", "%1%1") end
        if #t == 6 then panel:pickerSet(Style.colorOf(t)) end
      end)
    end }
  fillRound(gc, hxX, ry, hxW, ROW, 3, (editing or self:isHoverRaw("picker:hex")) and C.FIELD_HI or C.FIELD)
  if editing then
    frame(gc, hxX, ry, hxW, ROW, C.FILL_HI)
    local t = "#" .. self.edit.text
    textMid(gc, t, hxX + 4, ry, ROW, C.TEXT)
    fillRect(gc, hxX + 5 + measure(gc, t), ry + 4, 1, ROW - 8, C.TEXT)
  else
    textCenter(gc, Style.hexOf(cur), hxX, ry, hxW, ROW, C.TEXT)
  end
  local bx = px + pw - 8 - 2 * 18 - 2
  for i, b in ipairs({
    { id = "picker:take", icon = "fgTake", tip = I18n.t("picker_take_fg"),
      click = function() if app.fgColor then panel:pickerSet(copyColor(app.fgColor)) end end },
    { id = "picker:give", icon = "fgGive", tip = I18n.t("picker_give_fg"),
      click = function() app.fgColor = copyColor(pk.get()) end },
  }) do
    local x = bx + (i - 1) * 20
    add{ id = b.id, x = x, y = ry, w = 18, h = ROW, tip = b.tip, click = b.click }
    fillRound(gc, x, ry, 18, ROW, 3, self:isHoverRaw(b.id) and C.FIELD_HI or C.FIELD)
    Icons.draw(gc, b.icon, x + 9, ry + ROW / 2, C.TEXT)
  end
end

--------------------------------------------------------------------------
-- Paint
--------------------------------------------------------------------------

-- Lays out and draws the panel into a part of the canvas.
function Panel:paint(gc, rx, ry, rw, rh)
  local region = { x = rx, y = ry, w = rw, h = rh }
  self.region = region
  fillRect(gc, rx, ry, rw, rh, C.BG)

  -- Measure the header, then the content, so the scroll stays in range.
  self.newItems = {}
  local hm = newUi(self, gc, region, false, ry + HEAD_TOP, ry, ry + rh)
  self.o.header(hm)
  local headH = hm.first and 0 or (hm.y - GAP + HEAD_BOTTOM - ry)
  local viewH = max(1, rh - headH)
  local cm = newUi(self, gc, region, false, 0, -1e9, 1e9)
  self.o.build(cm)
  local contentH = max(0, cm.y - GAP) + CONTENT_TOP + CONTENT_BOTTOM
  self.headH, self.viewH, self.contentH = headH, viewH, contentH
  local scroll = clamp(self:getScroll(), 0, max(0, contentH - viewH))
  self.scrolls[self:scrollKey()] = scroll

  -- The content, then the header over any of it that scrolled up there.
  local top = ry + headH
  local cd = newUi(self, gc, region, true, top + CONTENT_TOP - scroll, top, ry + rh)
  self.o.build(cd)
  if headH > 0 then
    fillRect(gc, rx, ry, rw, headH, C.HEAD)
    fillRect(gc, rx, ry + headH - 1, rw, 1, C.LINE)
    local hd = newUi(self, gc, region, true, ry + HEAD_TOP, ry, ry + headH)
    self.o.header(hd)
  end

  -- The scroll bar, when there is anything to scroll.
  if contentH > viewH then
    local trackY, trackH = top + 2, viewH - 4
    local thumbH = max(18, floor(trackH * viewH / contentH))
    local maxS = contentH - viewH
    local thumbY = trackY + floor((trackH - thumbH) * scroll / maxS + 0.5)
    local panel = self
    local sb = { id = "scrollbar", x = rx + rw - 8, y = trackY, w = 8, h = trackH, clip = top, clipB = ry + rh }
    sb.down = function(ev2)
      if ev2.y < thumbY or ev2.y >= thumbY + thumbH then
        panel:setScroll((ev2.y - trackY - thumbH / 2) / max(1, trackH - thumbH) * maxS)
      end
      return { y0 = ev2.y, s0 = panel:getScroll() }
    end
    sb.drag = function(ev2, d)
      panel:setScroll(d.s0 + (ev2.y - d.y0) / max(1, trackH - thumbH) * maxS)
    end
    self.newItems[#self.newItems + 1] = sb
    fillRound(gc, rx + rw - 6, thumbY, 4, thumbH, 1, self:isHoverRaw("scrollbar") and C.KNOB_OFF or C.FIELD_HI)
  end
  self.items = self.newItems
  self.newItems = nil
end

function Panel:findItem(id)
  if not id then return nil end
  for i = #self.overlay, 1, -1 do
    if self.overlay[i].id == id then return self.overlay[i] end
  end
  for i = #self.items, 1, -1 do
    if self.items[i].id == id then return self.items[i] end
  end
  return nil
end

-- What goes over everything else on the canvas: the colour picker, then
-- the tooltip of what the mouse is on.
function Panel:paintOverlay(gc, W, H)
  self.overlay = {}
  self.pickerRect = nil
  if self.picker then self:drawPicker(gc, W, H) end
  if not self.drag and self.hover then
    local it = self:findItem(self.hover)
    if it and it.tip and not (self.edit and self.edit.id == it.id) then
      local below = (it.y + it.h + 40 < H)
      local ax = (it.w > 120) and self.mx or (it.x + it.w / 2)
      Style.tip(gc, it.tip, floor(ax), below and (it.y + it.h) or it.y, below and "below" or "above", W, H)
    end
  end
end

--------------------------------------------------------------------------
-- Mouse and keys
--------------------------------------------------------------------------

local function inRect(r, x, y)
  return r and x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
end

-- True when the point is on the panel or on its picker.
function Panel:contains(x, y)
  return inRect(self.region, x, y) or inRect(self.pickerRect, x, y)
end

function Panel:itemAt(x, y)
  for i = #self.overlay, 1, -1 do
    local it = self.overlay[i]
    if x >= it.x and x < it.x + it.w and y >= it.y and y < it.y + it.h then return it end
  end
  for i = #self.items, 1, -1 do
    local it = self.items[i]
    if x >= it.x and x < it.x + it.w and y >= max(it.y, it.clip or -1e9)
       and y < min(it.y + it.h, it.clipB or 1e9) then
      return it
    end
  end
  return nil
end

function Panel:updateHover(x, y)
  self.mx, self.my = x, y
  local it = self:itemAt(x, y)
  local id = it and it.id or nil
  if id ~= self.hover then
    self.hover = id
    self:repaint()
  end
end

function Panel:clearHover()
  if self.hover then
    self.hover = nil
    self:repaint()
  end
end

-- Returns true when the press was the panel's.
function Panel:onMouseDown(ev)
  local x, y = ev.x, ev.y
  self.mx, self.my = x, y
  local it = self:itemAt(x, y)
  if self.edit then
    -- A click in the field being typed into leaves it be; anywhere else
    -- takes the value typed.
    if it and it.id == self.edit.id then return true end
    self:commitEdit()
  end
  if self.picker and not inRect(self.pickerRect, x, y) then
    -- A click beside the picker closes it; on another colour it opens
    -- that one's.
    local was = self.picker.id
    self:closePicker(false)
    if not (it and it.opensPicker and it.id ~= was) then return true end
  end
  if not it then return self:contains(x, y) end
  if ev.button ~= MouseButton.LEFT then
    if ev.button == MouseButton.RIGHT and it.rclick then
      it.rclick(ev)
      self:repaint()
    end
    return true
  end
  if it.down then
    local d = it.down(ev)
    if d then
      d.id, d.item, d.downX, d.downY = it.id, it, x, y
      self.drag = d
    end
  elseif it.click then
    it.click(ev)
  end
  self:repaint()
  return true
end

function Panel:onMouseMove(ev)
  local d = self.drag
  if d then
    -- A drag is not the first half of a double click.
    if self.press and (abs(ev.x - d.downX) > 3 or abs(ev.y - d.downY) > 3) then
      self.press.fresh = false
    end
    self.mx, self.my = ev.x, ev.y
    if d.item and d.item.drag then d.item.drag(ev, d) end
    self:repaint()
    return
  end
  self:updateHover(ev.x, ev.y)
end

function Panel:onMouseUp(ev)
  if self.drag then
    self.drag = nil
    self:agePress()
    self:updateHover(ev.x, ev.y)
    self:repaint()
  end
end

function Panel:onWheel(ev)
  if self.picker or self.drag then return end
  local dy = ev.deltaY or 0
  if dy == 0 then return end
  self:setScroll(self:getScroll() + dy * SCROLL_STEP)
  self.hover = nil
  self:repaint()
end

-- The second press of a double click comes as this alone, without a mouse
-- down: what has no double click of its own takes it as a press.
function Panel:onDoubleClick(ev)
  local it = self:itemAt(ev.x, ev.y)
  if it and it.dbl and not self.edit and not self.picker then
    it.dbl(ev)
    self:repaint()
    return true
  end
  return self:onMouseDown(ev)
end

-- Typing into a value or a hex code.
local KEY_CHARS = {
  Minus = "-", NumpadSubtract = "-", Period = ".", NumpadDecimal = ".", Comma = ",",
}

function Panel:typeKey(ev)
  local e = self.edit
  local code = ev.code or ""
  if code == "Escape" then
    self.edit = nil
  elseif code == "Enter" or code == "NumpadEnter" or code == "Tab" then
    self:commitEdit()
  elseif code == "Backspace" then
    if e.fresh then e.text = "" else e.text = e.text:sub(1, -2) end
    e.fresh = false
  else
    local ch = code:match("^Digit(%d)$") or code:match("^Numpad(%d)$") or KEY_CHARS[code]
    if not ch and e.kind == "hex" then
      local l = code:match("^Key([A-Fa-f])$")
      ch = l and l:lower() or nil
    end
    if not ch and ev.key and #ev.key == 1 then
      local k = ev.key
      if k:match("[%d%.,%-]") or (e.kind == "hex" and k:match("%x")) then ch = k:lower() end
    end
    if not ch then return true end
    if e.kind == "hex" and not ch:match("%x") then return true end
    -- The first key replaces the value shown.
    if e.fresh then e.text = "" e.fresh = false end
    if #e.text < 12 then e.text = e.text .. ch end
  end
  self:repaint()
  return true
end

-- Keys while typing, for the picker, and the arrows on the slider under the
-- mouse. Returns true when the key was the panel's.
function Panel:onKeyDown(ev)
  if self.edit then return self:typeKey(ev) end
  if ev.ctrlKey or ev.altKey or ev.metaKey then return false end
  if self.picker and (ev.code == "Escape" or ev.code == "Enter" or ev.code == "NumpadEnter") then
    self:closePicker(ev.code == "Escape")
    return true
  end
  local it = self:findItem(self.hover)
  if it and it.key then return it.key(ev) and true or false end
  return false
end

return Panel
