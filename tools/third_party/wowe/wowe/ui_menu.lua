-- Menus that open beside a toolbar button, drawn on the canvas: the mask
-- layers, the looks.
--
-- A menu stays open while the mouse is on it, on its button or on the way
-- between the two. Its name runs across the top. Long lists are split into
-- columns; a list too long for the columns that fit scrolls with the wheel.
-- A row can show a few colours (a look's palette).
--
-- The layout measures its texts, so it is worked out while painting and
-- kept for the mouse to be tested against.

local G = ... or _WOWE

local Style = G.require("ui_style")

local Menu = {}

local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min

Menu.ROW = 18
local ROW = Menu.ROW
-- Text padding, the least room kept to the canvas edges, the narrowest and
-- widest a column gets, the rows a column holds before the menu grows a
-- second one and the width of a row's colours.
local PAD, MARGIN = 8, 4
local MIN_W, MAX_W = 110, 240
local PREF_ROWS = 18
local SWATCH_W = 7

-- rows:   { { label, value, current, disabled, section, swatches = { Color... } } }
--         A section row names the rows under it and cannot be picked.
-- anchor: the button, { x, y, w, h, side = "right" | "left" | "below" }:
--         where the menu opens.
-- scroll: the first row shown when the list scrolls.
-- title:  the menu's name, or nil.
function Menu.layout(gc, rows, anchor, cw, ch, scroll, title)
  local textW, anySw = 0, 0
  for _, r in ipairs(rows) do
    local w = Style.measure(gc, r.label)
    if w > textW then textW = w end
    if r.swatches then anySw = max(anySw, #r.swatches) end
  end
  local extra = (anySw > 0) and (anySw * SWATCH_W + 8) or 0
  local colW = max(MIN_W, min(MAX_W, floor(textW) + PAD * 2 + extra))
  if anchor.side == "below" then colW = max(colW, anchor.w) end
  local titleH = title and ROW or 0

  local n = max(1, #rows)
  local perColMax = max(1, floor((ch - MARGIN * 2 - titleH) / ROW))
  local maxCols = max(1, floor((cw - MARGIN * 2) / colW))
  local cols, perCol, scrolls, first
  local need = ceil(n / perColMax)
  if need > maxCols then
    cols, perCol, scrolls = 1, perColMax, true
    first = max(0, min(scroll or 0, n - perCol))
  else
    cols = min(maxCols, max(need, ceil(n / PREF_ROWS)))
    perCol, scrolls, first = ceil(n / cols), false, 0
  end
  if title then
    local tw = Style.measure(gc, title) + PAD * 2
    if tw > cols * colW then colW = min(MAX_W, ceil(tw / cols)) end
  end
  local w, h = cols * colW, titleH + perCol * ROW
  local x, y
  if anchor.side == "below" then
    x, y = anchor.x, anchor.y + anchor.h + 2
    if x + w > cw - MARGIN then x = max(MARGIN, cw - MARGIN - w) end
    if y + h > ch - MARGIN then
      y = anchor.y - 2 - h
      if y < MARGIN then y = max(MARGIN, ch - MARGIN - h) end
    end
  else
    if anchor.side == "left" then
      x = anchor.x - 2 - w
      if x < MARGIN then x = MARGIN end
    else
      x = anchor.x + anchor.w + 2
      if x + w > cw - MARGIN then x = max(MARGIN, cw - MARGIN - w) end
    end
    y = anchor.y
    if y + h > ch - MARGIN then y = max(MARGIN, ch - MARGIN - h) end
  end
  return { x = x, y = y, w = w, h = h, cols = cols, perCol = perCol, colW = colW,
           scrolls = scrolls, first = first, n = #rows, anchor = anchor,
           title = title, top = y + titleH }
end

-- Where row `idx` sits, or nil when it is scrolled out of sight.
local function rowRect(g, idx)
  local col, row
  if g.scrolls then
    col, row = 0, idx - g.first - 1
    if row < 0 or row >= g.perCol then return nil end
  else
    col, row = (idx - 1) // g.perCol, (idx - 1) % g.perCol
  end
  return g.x + col * g.colW, g.top + row * ROW
end

local function inside(x, y, rx, ry, rw, rh)
  return x >= rx and x < rx + rw and y >= ry and y < ry + rh
end

-- The row under the mouse, or nil.
function Menu.hit(g, rows, mx, my)
  if not g or not inside(mx, my, g.x, g.top, g.w, g.y + g.h - g.top) then return nil end
  local col = floor((mx - g.x) / g.colW)
  local row = floor((my - g.top) / ROW)
  local idx
  if g.scrolls then
    idx = g.first + row + 1
  else
    idx = col * g.perCol + row + 1
  end
  if not rows[idx] then return nil end
  return idx, "row"
end

-- True while the mouse is on the menu, just around it or on the way to it
-- from its button.
function Menu.keeps(g, mx, my)
  if not g then return false end
  if inside(mx, my, g.x - 2, g.y - 2, g.w + 4, g.h + 4) then return true end
  local a = g.anchor
  if not a then return false end
  if inside(mx, my, a.x, a.y, a.w, a.h) then return true end
  if a.side == "below" then
    if g.y >= a.y + a.h then
      return inside(mx, my, a.x, a.y + a.h, a.w, g.y - (a.y + a.h) + 1)
    end
    return inside(mx, my, a.x, g.y + g.h, a.w, a.y - (g.y + g.h) + 1)
  elseif a.side == "left" then
    return inside(mx, my, g.x + g.w, a.y, a.x - (g.x + g.w) + 1, a.h)
  end
  return inside(mx, my, a.x + a.w, a.y, g.x - (a.x + a.w) + 1, a.h)
end

-- The first row shown after scrolling by `delta` rows.
function Menu.scrolled(g, delta)
  if not g or not g.scrolls then return 0 end
  return max(0, min(g.first + delta, g.n - g.perCol))
end

local function arrow(gc, x, y, up)
  gc.color = Style.ICON
  gc:beginPath()
  if up then
    gc:moveTo(x - 3, y + 2) gc:lineTo(x, y - 1) gc:lineTo(x + 3, y + 2)
  else
    gc:moveTo(x - 3, y - 1) gc:lineTo(x, y + 2) gc:lineTo(x + 3, y - 1)
  end
  gc:closePath()
  gc:fill()
end

function Menu.draw(gc, g, rows, hoverIdx)
  Style.fillRect(gc, g.x, g.y, g.w, g.h, Style.TIP_BG)
  Style.frame(gc, g.x, g.y, g.w, g.h, Style.BUTTON_HI)
  if g.title then
    local text = Style.fit(gc, g.title, g.w - PAD * 2)
    local _, th = Style.measure(gc, text)
    Style.text(gc, text, g.x + PAD, g.y + floor((ROW - th) / 2), Style.TEXT_DIM)
    Style.fillRect(gc, g.x + 4, g.top - 1, g.w - 8, 1, Style.BUTTON_HI)
  end
  for idx, r in ipairs(rows) do
    local rx, ry = rowRect(g, idx)
    if rx and r.section then
      local text = Style.fit(gc, r.label, g.colW - PAD * 2)
      local _, th = Style.measure(gc, text)
      Style.text(gc, text, rx + PAD, ry + floor((ROW - th) / 2), Style.ACCENT)
    elseif rx then
      local hot = (hoverIdx == idx) and not r.disabled
      if r.current or hot then
        Style.fillRect(gc, rx + 1, ry, g.colW - 2, ROW, r.current and Style.BUTTON_ON or Style.BUTTON_HI)
      end
      local right = rx + g.colW
      if r.swatches then
        local n = #r.swatches
        local sx = right - 6 - n * SWATCH_W
        for i, c in ipairs(r.swatches) do
          Style.fillRect(gc, sx + (i - 1) * SWATCH_W, ry + 4, SWATCH_W, ROW - 8, c)
        end
        right = sx - 2
      end
      local text = Style.fit(gc, r.label, right - rx - PAD - 2)
      local _, th = Style.measure(gc, text)
      Style.text(gc, text, rx + PAD, ry + floor((ROW - th) / 2), r.disabled and Style.TEXT_DIM or Style.TIP_TEXT)
    end
  end
  if g.scrolls then
    local ax = g.x + floor(g.w / 2)
    if g.first > 0 then arrow(gc, ax, g.top + 2, true) end
    if g.first + g.perCol < g.n then arrow(gc, ax, g.y + g.h - 3, false) end
  end
end

return Menu
