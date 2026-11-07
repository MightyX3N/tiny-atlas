-- The window: one canvas that fills it, and grows and shrinks with it.
--
-- On the left the picture, with icon buttons down its left edge: a button
-- with a menu opens it while the mouse is on it, a button with a strip
-- shows a row of small buttons beside it. On the right the settings panel
-- (ui_panel.lua). The bar between them can be dragged to give either more
-- room, and the panel can be put away to give the picture all of it.
-- Menus, tooltips and the shortcut card draw over everything.
--
-- No native widgets, and nothing is ever rebuilt: every paint lays the
-- window out again from the settings.
--
-- A window is made from:
--   title()          its name
--   name             where its place is kept between sessions
--   width, height    its size the first time
--   tools()          the toolbar: { id, icon, tip, kind, on, dim, click,
--                    strip } or { group = true } between groups. kind
--                    "menu" opens menu(id) while the mouse is on the button.
--   menu(id)         { title, rows, pick(row) } (rows: ui_menu.lua)
--   view             the picture: paint(gc, w, h, inset), down, move, up,
--                    wheel, dbl, key(ev) -> handled, leave()
--   panel            header(ui), build(ui), scrollKey()
--   panelShown()     whether the panel is out
--   panelWidth(), setPanelWidth(w)
--   keys()           the shortcut card: { title, sections = { { title,
--                    rows = { { key, what } } } } }; a "?" button last on
--                    the toolbar (and F1) opens it
--   place(name, r)   keeps where the window is
--   onClose()
--
-- The picture can put buttons of its own over itself with
-- win:viewButton(gc, b) while it paints (b: { id, x, y, w, h, text, icon,
-- tip, primary, on, click }); they take the mouse before the picture does.

local G = ... or _WOWE

local Style = G.require("ui_style")
local Icons = G.require("ui_icons")
local Menu  = G.require("ui_menu")
local Panel = G.require("ui_panel")

local Window = {}
Window.__index = Window

local floor, max, min = math.floor, math.max, math.min
local clamp = Style.clamp

-- Toolbar: left edge, first button's top (below the info line), button
-- size, gap between buttons and the extra gap between groups.
local TB_X, TB_Y0, TB_SIZE, TB_GAP, TB_GROUP = 4, 22, 20, 2, 6
Window.TB_SIZE, Window.TB_Y0 = TB_SIZE, TB_Y0
-- The bar between picture and panel, and the least room each keeps.
local SPLIT_W, VIEW_MIN, PANEL_MIN = 6, 160, 220
Window.SPLIT_W = SPLIT_W

function Window.new(o)
  local self = setmetatable({ o = o }, Window)
  self.dlg = nil
  self.W, self.H = o.width or 300, o.height or 400
  self.splitX = self.W
  self.drag = nil
  self.toolBoxes, self.toolRight = {}, TB_X
  self.toolHover = nil
  self.menu, self.rowHover = nil, nil
  self.menuScroll = {}
  self.splitHover = false
  self.inViewNow = false
  self.mx, self.my = -100, -100
  self.viewButtons, self.vbHover = {}, nil
  self.keysOpen = false
  local win = self
  if o.panel then
    self.panel = Panel.new{
      header = function(ui) return win.o.panel.header(ui) end,
      build = function(ui) return win.o.panel.build(ui) end,
      scrollKey = function() return win.o.panel.scrollKey and win.o.panel.scrollKey() or nil end,
      repaint = function() win:repaint() end,
    }
  end
  return self
end

function Window:repaint()
  if self.dlg then pcall(function() self.dlg:repaint() end) end
end

function Window:isOpen()
  return self.dlg ~= nil
end

--------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------

function Window:panelShown()
  if not self.panel then return false end
  if not self.o.view or not self.o.panelShown then return true end
  return self.o.panelShown() and true or false
end

-- Where the bar between picture and panel goes for a canvas W wide.
function Window:layoutSplit(W)
  if not self.o.view then
    self.splitX = 0
  elseif not self:panelShown() then
    self.splitX = W
  else
    local pw = self.o.panelWidth and self.o.panelWidth() or 280
    pw = clamp(pw, PANEL_MIN, max(PANEL_MIN, W - VIEW_MIN - SPLIT_W))
    self.splitX = max(0, W - pw - SPLIT_W)
  end
  return self.splitX
end

function Window:inView(x, y)
  return self.o.view ~= nil and x < self.splitX
end

function Window:onSplitter(x, y)
  return self.o.view ~= nil and self:panelShown() and x >= self.splitX - 1 and x < self.splitX + SPLIT_W + 1
end

function Window:inPanel(x, y)
  if not self:panelShown() then return false end
  if not self.o.view then return true end
  return x >= self.splitX + SPLIT_W
end

-- The toolbar's buttons, top to bottom; a second column starts when the
-- window is too short for one.
function Window:layoutTools()
  local items = self.o.tools and self.o.tools() or {}
  if self.o.keys then
    local win = self
    items[#items + 1] = { group = true }
    items[#items + 1] = { id = "helpKeys", icon = "help", on = self.keysOpen,
      tip = self.o.keysTip and self.o.keysTip() or nil, click = function() win:toggleKeys() end }
  end
  local list, x, y = {}, TB_X, TB_Y0
  local bottom = self.H - 28
  local right = TB_X
  for _, it in ipairs(items) do
    if it.group then
      if #list > 0 and y > TB_Y0 then y = y + TB_GROUP end
    else
      if y + TB_SIZE > bottom and y > TB_Y0 then
        x, y = x + TB_SIZE + 3, TB_Y0
      end
      list[#list + 1] = { item = it, x = x, y = y }
      right = max(right, x + TB_SIZE)
      y = y + TB_SIZE + TB_GAP
    end
  end
  self.toolBoxes, self.toolRight = list, right
  return list
end

function Window:toolAt(x, y)
  for _, b in ipairs(self.toolBoxes) do
    if x >= b.x and x < b.x + TB_SIZE and y >= b.y and y < b.y + TB_SIZE then return b end
  end
  return nil
end

--------------------------------------------------------------------------
-- Menus and strips
--------------------------------------------------------------------------

-- m: { id, title, rows | rowsFn, anchor, pick(row), stay, strip }
-- stay: the menu stays open after a pick (a toolbar menu, where the pick
-- shows as the current row).
function Window:openMenu(m)
  self.menu = m
  self.rowHover = nil
  self:repaint()
end

function Window:closeMenu()
  if self.menu then
    self.menu, self.rowHover = nil, nil
    self:repaint()
  end
end

function Window:openToolMenu(b)
  local item = b.item
  local win = self
  self:openMenu{
    id = item.id, stay = true,
    anchor = { x = b.x, y = b.y, w = TB_SIZE, h = TB_SIZE, side = "right" },
    rowsFn = function()
      local m = win.o.menu(item.id)
      return m and m.rows or {}, m and m.title
    end,
    pick = function(row)
      local m = win.o.menu(item.id)
      if m and m.pick then m.pick(row) end
    end,
  }
end

-- A tool's strip: small icon buttons in a row beside it. item.strip:
-- { { id, icon, tip, on, dim, click } }.
function Window:openToolStrip(b)
  local item = b.item
  local win = self
  self:openMenu{
    id = item.id, stay = true, strip = true,
    anchor = { x = b.x, y = b.y, w = TB_SIZE, h = TB_SIZE, side = "right" },
    rowsFn = function()
      for _, tb in ipairs(win.toolBoxes) do
        if tb.item.id == item.id then return tb.item.strip or {} end
      end
      return {}
    end,
    pick = function(row) if row.click and not row.dim then row.click() end end,
  }
end

local STRIP_GAP = 2
local function stripGeom(anchor, n)
  local x = anchor.x + anchor.w + 4
  local w = n * TB_SIZE + (n - 1) * STRIP_GAP + 6
  return { x = x, y = anchor.y - 3, w = w, h = TB_SIZE + 6, anchor = anchor, strip = true }
end

function Window:menuHit(m, x, y)
  local g = m.geom
  if not g then return nil end
  if not m.strip then return Menu.hit(g, m.shown or {}, x, y) end
  if y < g.y + 3 or y >= g.y + 3 + TB_SIZE or x < g.x + 3 then return nil end
  local i = floor((x - g.x - 3) / (TB_SIZE + STRIP_GAP)) + 1
  local within = (x - g.x - 3) - (i - 1) * (TB_SIZE + STRIP_GAP)
  if within >= TB_SIZE or not (m.shown or {})[i] then return nil end
  return i, "row"
end

function Window:drawStrip(gc, m, W, H)
  local rows = m.shown or {}
  local g = stripGeom(m.anchor, #rows)
  m.geom = g
  Style.fillRound(gc, g.x, g.y, g.w, g.h, 3, Style.TIP_BG)
  local hot = self.rowHover and self.rowHover.index
  for i, it in ipairs(rows) do
    local bx = g.x + 3 + (i - 1) * (TB_SIZE + STRIP_GAP)
    local by = g.y + 3
    local color = it.on and Style.BUTTON_ON or ((hot == i and not it.dim) and Style.BUTTON_HI or Style.BUTTON)
    Style.fillRound(gc, bx, by, TB_SIZE, TB_SIZE, 3, color)
    Icons.draw(gc, it.icon, bx + TB_SIZE / 2, by + TB_SIZE / 2, it.dim and Style.ICON_DIM or Style.ICON)
  end
  if hot and rows[hot] and rows[hot].tip then
    local bx = g.x + 3 + (hot - 1) * (TB_SIZE + STRIP_GAP)
    Style.tip(gc, rows[hot].tip, bx + TB_SIZE / 2, g.y + g.h, "below", W, H)
  end
end

function Window:pickRow(m, idx)
  local rows = m.shown or {}
  local row = rows[idx]
  if not row or row.disabled or row.section then return end
  if not m.stay then self:closeMenu() end
  m.pick(row)
  self:repaint()
end

--------------------------------------------------------------------------
-- Buttons over the picture, and the shortcut card
--------------------------------------------------------------------------

function Window:viewButton(gc, b)
  self.viewButtons[#self.viewButtons + 1] = b
  local hot = self.vbHover == b.id
  local color
  if b.primary then color = hot and Style.FILL_HI or Style.FILL
  elseif b.on then color = Style.BUTTON_ON
  else color = hot and Style.BUTTON_HI or Style.BUTTON end
  Style.fillRound(gc, b.x, b.y, b.w, b.h, 3, color)
  local ink = b.dim and Style.ICON_DIM or Style.ICON
  if b.text then
    local iconW = b.icon and 18 or 0
    local t = Style.fit(gc, b.text, b.w - iconW - 8)
    local tw = Style.measure(gc, t)
    local cx = b.x + floor((b.w - tw - iconW) / 2)
    if b.icon then Icons.draw(gc, b.icon, cx + 7, b.y + b.h / 2, ink) end
    Style.textMid(gc, t, cx + iconW, b.y, b.h, b.dim and Style.TEXT_DIM or Style.WHITE)
  elseif b.icon then
    Icons.draw(gc, b.icon, b.x + b.w / 2, b.y + b.h / 2, ink)
  end
end

function Window:viewButtonAt(x, y)
  if not self:inView(x, y) then return nil end
  for i = #self.viewButtons, 1, -1 do
    local b = self.viewButtons[i]
    if x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h then return b end
  end
  return nil
end

function Window:toggleKeys(open)
  if open == nil then open = not self.keysOpen end
  self.keysOpen = (open and self.o.keys ~= nil) and true or false
  self:repaint()
end

local KEY_LINE = 13

-- The card: each section a title and its keys, in as many columns as the
-- picture's height asks for, in the middle of the picture.
function Window:drawKeys(gc, W, VH)
  local data = self.o.keys and self.o.keys()
  if not data then return end
  local kw, dw = 0, 0
  for _, sec in ipairs(data.sections or {}) do
    for _, r in ipairs(sec.rows) do
      kw = max(kw, (Style.measure(gc, r[1])))
      dw = max(dw, (Style.measure(gc, r[2])))
    end
  end
  local cols, colH = { {} }, { 0 }
  local maxH = max(80, VH - 56)
  for _, sec in ipairs(data.sections or {}) do
    local h = KEY_LINE + 4 + #sec.rows * KEY_LINE + 6
    local c = #cols
    if colH[c] > 0 and colH[c] + h > maxH then
      cols[c + 1], colH[c + 1] = {}, 0
      c = c + 1
    end
    cols[c][#cols[c] + 1] = sec
    colH[c] = colH[c] + h
  end
  local n = #cols
  local room = floor((W - 8 - 24 - (n - 1) * 18) / n)
  dw = max(40, min(dw, room - kw - 12))
  local colW = kw + 12 + dw
  local hMax = 0
  for _, h in ipairs(colH) do hMax = max(hMax, h) end
  local cw = min(W - 8, n * colW + (n - 1) * 18 + 24)
  local ch = min(VH - 8, hMax + 34)
  local x = max(4, floor((W - cw) / 2))
  local y = max(4, floor((VH - ch) / 2))
  Style.fillRound(gc, x, y, cw, ch, 5, Style.TIP_BG)
  Style.text(gc, data.title or "", x + 12, y + 8, Style.ACCENT)
  local closeT = "Esc"
  Style.text(gc, closeT, x + cw - 12 - (Style.measure(gc, closeT)), y + 8, Style.TEXT_DIM)
  for ci, col in ipairs(cols) do
    local cx = x + 12 + (ci - 1) * (colW + 18)
    local cy = y + 28
    for _, sec in ipairs(col) do
      if sec.title then
        Style.text(gc, sec.title, cx, cy, Style.TEXT_DIM)
        Style.fillRect(gc, cx, cy + KEY_LINE, colW, 1, Style.LINE)
      end
      cy = cy + KEY_LINE + 4
      for _, r in ipairs(sec.rows) do
        Style.text(gc, r[1], cx, cy, Style.HOT)
        Style.text(gc, Style.fit(gc, r[2], dw), cx + kw + 12, cy, Style.TIP_TEXT)
        cy = cy + KEY_LINE
      end
      cy = cy + 6
    end
  end
end

--------------------------------------------------------------------------
-- Paint
--------------------------------------------------------------------------

local function clipTo(gc, x, y, w, h)
  return pcall(function()
    gc:save()
    gc:beginPath()
    gc:rect(Rectangle(x, y, w, h))
    gc:clip()
  end)
end

local function unclip(gc, ok)
  if ok then pcall(function() gc:restore() end) end
end

function Window:drawTools(gc)
  for _, b in ipairs(self.toolBoxes) do
    local item = b.item
    local hot = self.toolHover and self.toolHover.item.id == item.id and not self.drag
    local open = self.menu and self.menu.id == item.id
    local color
    if item.on then color = Style.BUTTON_ON
    elseif hot or open then color = Style.BUTTON_HI
    else color = Style.BUTTON end
    Style.fillRound(gc, b.x, b.y, TB_SIZE, TB_SIZE, 3, color)
    Icons.draw(gc, item.icon, b.x + TB_SIZE / 2, b.y + TB_SIZE / 2,
      item.dim and Style.ICON_DIM or Style.ICON)
    if item.kind == "menu" or item.strip then
      -- A small corner triangle: this button has more behind it.
      gc.color = Style.ICON
      gc:beginPath()
      gc:moveTo(b.x + TB_SIZE - 1, b.y + TB_SIZE - 5)
      gc:lineTo(b.x + TB_SIZE - 1, b.y + TB_SIZE - 1)
      gc:lineTo(b.x + TB_SIZE - 5, b.y + TB_SIZE - 1)
      gc:closePath()
      gc:fill()
    end
  end
end

function Window:paint(ev)
  local gc = ev.context
  local W, H = gc.width or self.W, gc.height or self.H
  self.W, self.H = W, H
  gc.antialias = false
  local sx = self:layoutSplit(W)

  if self.o.view then
    self:layoutTools()
    self.viewButtons = {}
    local ok = clipTo(gc, 0, 0, sx, H)
    Style.fillRect(gc, 0, 0, sx, H, Style.VIEW_BG)
    self.o.view.paint(gc, sx, H, self.toolRight + 8)
    if self.keysOpen then self:drawKeys(gc, sx, H) end
    unclip(gc, ok)
    self:drawTools(gc)
  end
  if self:panelShown() then
    local px = self.o.view and (sx + SPLIT_W) or 0
    local ok = clipTo(gc, px, 0, W - px, H)
    self.panel:paint(gc, px, 0, W - px, H)
    unclip(gc, ok)
    if self.o.view then
      -- The bar, with a grip in its middle.
      Style.fillRect(gc, sx, 0, SPLIT_W, H, Style.HEAD)
      Style.fillRect(gc, sx, 0, 1, H, Style.LINE)
      Style.fillRect(gc, sx + SPLIT_W - 1, 0, 1, H, Style.LINE)
      local hot = self.splitHover or (self.drag and self.drag.kind == "split")
      local gy = floor(H / 2) - 10
      for i = 0, 4 do
        Style.fillRect(gc, sx + 2, gy + i * 5, 2, 2, hot and Style.ACCENT or Style.KNOB_OFF)
      end
    end
  end

  -- Over everything: an open menu, the colour picker and the tooltips.
  local m = self.menu
  if m then
    local rows, title = m.rows, m.title
    if m.rowsFn then
      local r, t = m.rowsFn()
      rows, title = r, t or title
    end
    m.shown = rows
    if m.strip then
      self:drawStrip(gc, m, W, H)
    else
      m.geom = Menu.layout(gc, rows, m.anchor, W, H, self.menuScroll[m.id], title)
      Menu.draw(gc, m.geom, rows, self.rowHover and self.rowHover.index)
    end
  end
  if self:panelShown() then self.panel:paintOverlay(gc, W, H) end
  if self.toolHover and not self.drag and not m then
    local b = self.toolHover
    if b.item.tip then
      Style.tip(gc, b.item.tip, b.x + TB_SIZE, b.y + TB_SIZE / 2, "right", W, H)
    end
  end
  local vb = self.vbHover and not self.drag and not m and self:viewButtonAt(self.mx, self.my)
  if vb and vb.tip then
    Style.tip(gc, vb.tip, vb.x + vb.w / 2, vb.y, "above", W, H)
  end
end

--------------------------------------------------------------------------
-- Mouse and keys
--------------------------------------------------------------------------

function Window:pressTool(b)
  local item = b.item
  if item.kind == "menu" then
    if self.menu and self.menu.id == item.id then self:closeMenu() else self:openToolMenu(b) end
  elseif item.click then
    item.click()
  end
  self:repaint()
end

function Window:leaveView()
  if self.inViewNow then
    self.inViewNow = false
    if self.o.view and self.o.view.leave then self.o.view.leave() end
  end
end

function Window:updateHover(ev)
  local x, y = ev.x, ev.y
  self.mx, self.my = x, y
  local m = self.menu
  local onMenu, row = false, nil
  if m and m.geom then
    local idx, part = self:menuHit(m, x, y)
    if idx then
      onMenu, row = true, { index = idx, part = part }
    elseif Menu.keeps(m.geom, x, y) then
      onMenu = true
    end
  end
  local tool, vb = nil, nil
  if not onMenu then
    vb = self:viewButtonAt(x, y)
    tool = (not vb and self:inView(x, y)) and self:toolAt(x, y) or nil
    if tool and tool.item.kind == "menu" then
      if not (m and m.id == tool.item.id) then self:openToolMenu(tool) end
      onMenu = true
    elseif tool and tool.item.strip then
      if not (m and m.id == tool.item.id) then self:openToolStrip(tool) end
    elseif m then
      self:closeMenu()
    end
  end
  local changed = (tool and tool.item.id) ~= (self.toolHover and self.toolHover.item.id)
    or (vb and vb.id) ~= self.vbHover
    or (row and row.index) ~= (self.rowHover and self.rowHover.index)
  self.toolHover, self.rowHover = tool, row
  self.vbHover = vb and vb.id or nil
  local split = not onMenu and not tool and self:onSplitter(x, y)
  if split ~= self.splitHover then
    self.splitHover = split
    changed = true
  end
  if self.panel then
    if not onMenu and not tool and self:inPanel(x, y) then
      self.panel:updateHover(x, y)
    else
      self.panel:clearHover()
    end
  end
  if not onMenu and not tool and not vb and not split and self:inView(x, y) and not self.keysOpen then
    self.inViewNow = true
    if self.o.view.move then self.o.view.move(ev) end
  else
    self:leaveView()
  end
  if changed then self:repaint() end
end

function Window:onMouseDown(ev)
  local x, y = ev.x, ev.y
  self.mx, self.my = x, y
  local m = self.menu
  if m and m.geom then
    local idx = self:menuHit(m, x, y)
    if idx then
      if ev.button == MouseButton.LEFT then self:pickRow(m, idx) end
      return
    end
    if Menu.keeps(m.geom, x, y) and not self:toolAt(x, y) then return end
    self:closeMenu()
  end
  -- The panel, when the mouse is on it or it is typing or picking a colour.
  if self.panel and (self.panel:isBusy() or self:inPanel(x, y)) then
    if self.panel:onMouseDown(ev) then
      self:repaint()
      return
    end
  end
  if self:onSplitter(x, y) then
    self.drag = { kind = "split", x0 = x, w0 = self.W - self.splitX - SPLIT_W }
    self:repaint()
    return
  end
  if not self:inView(x, y) then return end
  local vb = self:viewButtonAt(x, y)
  if vb then
    if ev.button == MouseButton.LEFT and vb.click and not vb.dim then vb.click(ev) end
    self:repaint()
    return
  end
  local b = self:toolAt(x, y)
  if b then
    if ev.button == MouseButton.LEFT then self:pressTool(b) end
    return
  end
  if self.keysOpen then
    self:toggleKeys(false)
    return
  end
  self.drag = { kind = "view" }
  self.inViewNow = true
  if self.o.view.down then self.o.view.down(ev) end
  self:repaint()
end

function Window:onMouseMove(ev)
  local d = self.drag
  if d then
    self.mx, self.my = ev.x, ev.y
    if d.kind == "split" then
      if self.o.setPanelWidth then
        local w = clamp(d.w0 - (ev.x - d.x0), PANEL_MIN, max(PANEL_MIN, self.W - VIEW_MIN - SPLIT_W))
        self.o.setPanelWidth(w)
      end
      self:repaint()
    elseif self.o.view.move then
      self.o.view.move(ev)
    end
    return
  end
  if self.panel and self.panel.drag then
    self.panel:onMouseMove(ev)
    return
  end
  self:updateHover(ev)
end

function Window:onMouseUp(ev)
  local d = self.drag
  if d then
    self.drag = nil
    if d.kind == "view" and self.o.view.up then self.o.view.up(ev) end
    self:updateHover(ev)
    self:repaint()
    return
  end
  if self.panel and self.panel.drag then self.panel:onMouseUp(ev) end
end

function Window:onWheel(ev)
  local d = ev.deltaY or 0
  if d == 0 then return end
  local m = self.menu
  if m and m.geom and m.geom.scrolls and Menu.keeps(m.geom, ev.x, ev.y) then
    self.menuScroll[m.id] = Menu.scrolled(m.geom, (d > 0) and 3 or -3)
    self:repaint()
    return
  end
  if self:inPanel(ev.x, ev.y) then
    self.panel:onWheel(ev)
  elseif self:inView(ev.x, ev.y) and self.o.view.wheel then
    self.o.view.wheel(ev)
  end
end

-- The second press of a double click comes as this alone, without a mouse
-- down.
function Window:onDoubleClick(ev)
  local x, y = ev.x, ev.y
  if self.menu and self.menu.geom and Menu.keeps(self.menu.geom, x, y) then
    self:onMouseDown(ev)
    return
  end
  if self.panel and (self.panel:isBusy() or self:inPanel(x, y)) then
    if self.panel:onDoubleClick(ev) then
      self:repaint()
      return
    end
  end
  if self:toolAt(x, y) or self:onSplitter(x, y) or self.keysOpen or self:viewButtonAt(x, y) then
    self:onMouseDown(ev)
    return
  end
  if self:inView(x, y) and self.o.view.dbl and self.o.view.dbl(ev) then
    self:repaint()
    return
  end
  self:onMouseDown(ev)
end

function Window:onKeyDown(ev)
  local handled = false
  if self.panel and self.panel.edit then
    handled = self.panel:onKeyDown(ev)
  elseif self.menu and ev.code == "Escape" then
    self:closeMenu()
    handled = true
  elseif self.o.keys and ev.code == "F1" then
    self:toggleKeys()
    handled = true
  elseif self.keysOpen and ev.code == "Escape" then
    self:toggleKeys(false)
    handled = true
  else
    if self.panel and (self.panel.picker or self:inPanel(self.mx, self.my)) then
      handled = self.panel:onKeyDown(ev)
    end
    if not handled and self.o.view and self.o.view.key then
      handled = self.o.view.key(ev) and true or false
    end
  end
  if handled then
    if ev.stopPropagation then ev:stopPropagation() end
    self:repaint()
  end
end

--------------------------------------------------------------------------
-- The dialog
--------------------------------------------------------------------------

function Window:show()
  if self.dlg then
    pcall(function() self.dlg:show{ wait = false } end)
    return self.dlg
  end
  self.drag, self.menu, self.rowHover, self.toolHover = nil, nil, nil, nil
  self.keysOpen, self.vbHover = false, nil
  if self.panel then self.panel:reset() end
  local win = self
  local d
  d = Dialog{
    title = self.o.title(),
    onclose = function()
      if win.dlg == d then
        win:keepPlace()
        win.dlg = nil
        win.drag, win.menu = nil, nil
        if win.panel then win.panel:reset() end
        if win.o.onClose then win.o.onClose() end
      end
    end
  }
  self.dlg = d
  d:canvas{
    id = "canvas",
    width = self.o.width or 300,
    height = self.o.height or 400,
    hexpand = true,
    vexpand = true,
    -- Keys only reach a canvas that has the focus.
    focus = true,
    onpaint = function(ev) win:paint(ev) end,
    onmousedown = function(ev) win:onMouseDown(ev) end,
    onmousemove = function(ev) win:onMouseMove(ev) end,
    onmouseup = function(ev) win:onMouseUp(ev) end,
    onwheel = function(ev) win:onWheel(ev) end,
    ondblclick = function(ev) win:onDoubleClick(ev) end,
    onkeydown = function(ev) win:onKeyDown(ev) end,
  }
  d:show{ wait = false }
  return d
end

-- Remembers where the window is, for the next time it opens.
function Window:keepPlace()
  if not (self.o.place and self.o.name and self.dlg) then return end
  pcall(function() self.o.place(self.o.name, self.dlg.bounds) end)
end

function Window:close()
  self:keepPlace()
  self.drag, self.menu = nil, nil
  if self.panel then self.panel:reset() end
  if self.dlg then
    local d = self.dlg
    self.dlg = nil
    pcall(function() d:close() end)
  end
end

--------------------------------------------------------------------------
-- For the tests: press what a user would press, by name.
--------------------------------------------------------------------------

-- Lays the window out as a paint would (the boxes the mouse is tested
-- against), on the canvas the tests give (Window.testCanvas(w, h)).
function Window:paintNow()
  if Window.testCanvas and self.dlg then
    self:paint({ context = Window.testCanvas(self.W, self.H) })
  end
end

local function findStrip(self, id)
  for _, b in ipairs(self.toolBoxes) do
    for _, it in ipairs(b.item.strip or {}) do
      if it.id == id then return it end
    end
  end
  return nil
end

-- A toolbar button, a strip's button, a button over the picture or
-- anything in the panel.
function Window:click(id)
  self:paintNow()
  for _, b in ipairs(self.toolBoxes) do
    if b.item.id == id then
      self:pressTool(b)
      self:paintNow()
      return true
    end
  end
  for _, vb in ipairs(self.viewButtons) do
    if vb.id == id then
      vb.click()
      self:paintNow()
      return true
    end
  end
  local st = findStrip(self, id)
  if st then
    st.click()
    self:paintNow()
    return true
  end
  assert(self.panel, "nothing called " .. tostring(id) .. " in the window")
  local it = self.panel:findItem(id)
  assert(it, "nothing called " .. tostring(id) .. " in the window")
  assert(it.click, tostring(id) .. " cannot be clicked")
  it.click({ button = MouseButton.LEFT, x = it.x + 1, y = it.y + 1 })
  self:paintNow()
  return true
end

-- A right click on something in the panel.
function Window:rclick(id)
  self:paintNow()
  local it = self.panel:findItem(id)
  assert(it and it.rclick, tostring(id) .. " takes no right click")
  it.rclick({ button = MouseButton.RIGHT })
  self:paintNow()
end

-- A slider, dial or colour in the panel set to a value.
function Window:setValue(id, v)
  self:paintNow()
  local it = self.panel:findItem(id)
  assert(it, "nothing called " .. tostring(id) .. " in the window")
  assert(it.setValue, tostring(id) .. " takes no value")
  it.setValue(v)
  self:paintNow()
end

-- A row of a toolbar menu, by its value.
function Window:pickMenu(id, value)
  local m = self.o.menu(id)
  assert(m, "no menu " .. tostring(id))
  for _, r in ipairs(m.rows) do
    if r.value == value and not r.section then
      m.pick(r)
      self:paintNow()
      return true
    end
  end
  error("menu " .. tostring(id) .. " has no row " .. tostring(value))
end

-- Where something is on the canvas: x, y, w, h (or nil).
function Window:boxOf(id)
  self:paintNow()
  for _, b in ipairs(self.toolBoxes) do
    if b.item.id == id then return b.x, b.y, TB_SIZE, TB_SIZE end
  end
  for _, vb in ipairs(self.viewButtons) do
    if vb.id == id then return vb.x, vb.y, vb.w, vb.h end
  end
  local it = self.panel and self.panel:findItem(id)
  if it then return it.x, it.y, it.w, it.h end
  return nil
end

function Window:has(id)
  return self:boxOf(id) ~= nil or findStrip(self, id) ~= nil
end

return Window
