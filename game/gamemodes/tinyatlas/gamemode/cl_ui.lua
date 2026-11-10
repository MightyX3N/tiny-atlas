-- The game's own UI kit: pixel art on the same grid as the world (a logical screen of about 480 x 270, each pixel
-- drawn S x S screen pixels), drawn with GMod's basic 2D functions only (surface.*, input.*) so the LÖVE layer runs it
-- unchanged. Immediate mode: screens call the widgets every frame; keyboard focus moves over the widgets in the
-- order they were drawn last frame (up / down), the mouse hovers and clicks.
--
-- Fonts (SIL Open Font License, content/resource/fonts): Jersey 10 (headings, big numbers) and Micro 5 (text, the
-- bike computer's digits), each at a size that puts its own pixels exactly on the grid.
TinyAtlas.UI = TinyAtlas.UI or {}
local UI = TinyAtlas.UI
local floor, max, min = math.floor, math.max, math.min

UI.C = {
  ink = Color(22, 32, 43), ink2 = Color(34, 48, 62), edge = Color(74, 93, 112), shadow = Color(5, 8, 11),
  text = Color(232, 237, 241), dim = Color(147, 163, 178), sign = Color(242, 193, 46), signDark = Color(168, 127, 18),
  red = Color(224, 74, 58), redDark = Color(142, 42, 32), green = Color(111, 209, 106),
  lcd = Color(169, 185, 143), lcdInk = Color(29, 39, 22), lcdGhost = Color(154, 171, 128), lcdEdge = Color(85, 96, 63),
  lcdFrame = Color(44, 52, 36), dark = Color(10, 16, 22),
}
local C = UI.C
-- the fonts: family, size of one em in grid pixels
UI.FONTS = {
  J1 = { "Jersey 10", 18.6667 }, J2 = { "Jersey 10", 37.3333 },
  M1 = { "Micro 5", 11 }, M2 = { "Micro 5", 22 }, M3 = { "Micro 5", 33 },
}

-- ---- the grid ----
function UI.metrics()
  local sw, sh = ScrW(), ScrH()
  local s = max(1, floor(sh / 270 + 0.0001))
  if UI.s ~= s or UI.sw ~= sw or UI.sh ~= sh then
    UI.s, UI.sw, UI.sh = s, sw, sh
    UI.W, UI.H = floor(sw / s), floor(sh / s)
    UI.ox, UI.oy = floor((sw - UI.W * s) / 2), floor((sh - UI.H * s) / 2)
    UI.fonts = {}
  end
  return UI.W, UI.H, s
end

function UI.font(name)
  local f = UI.fonts[name]
  if f then return f end
  local def = UI.FONTS[name]
  f = "TinyAtlasUI_" .. name .. "_" .. UI.s
  surface.CreateFont(f, { font = def[1], size = floor(def[2] * UI.s + 0.5), weight = 400, antialias = false, extended = true })
  UI.fonts[name] = f
  return f
end

-- ---- drawing, in grid pixels ----
function UI.rect(x, y, w, h, col)
  if w <= 0 or h <= 0 then return end
  local s = UI.s
  surface.SetDrawColor(col.r, col.g, col.b, col.a or 255)
  surface.DrawRect(UI.ox + floor(x) * s, UI.oy + floor(y) * s, floor(w) * s, floor(h) * s)
end
function UI.textw(str, font)
  surface.SetFont(UI.font(font))
  local w, h = surface.GetTextSize(str)
  return w / UI.s, h / UI.s
end
-- y is the top of the letters' line (the font's own top); align: "left" (default), "center", "right"
function UI.text(str, x, y, font, col, align)
  local s = UI.s
  surface.SetFont(UI.font(font))
  local w = surface.GetTextSize(str)
  local px = UI.ox + floor(x) * s
  if align == "center" then px = px - floor(w / s / 2) * s elseif align == "right" then px = px - floor(w / s + 0.999) * s end
  surface.SetTextColor(col.r, col.g, col.b, col.a or 255)
  surface.SetTextPos(px, UI.oy + floor(y) * s)
  surface.DrawText(str)
end
function UI.stext(str, x, y, font, col, align)
  UI.text(str, x + 1, y + 1, font, C.shadow, align)
  UI.text(str, x, y, font, col, align)
end
-- a panel: solid, a 1-pixel light edge, a hard shadow below and right
function UI.panel(x, y, w, h, fill)
  UI.rect(x + 1, y + 1, w, h, C.shadow)
  UI.rect(x, y, w, h, C.edge)
  UI.rect(x + 1, y + 1, w - 2, h - 2, fill or C.ink)
end
-- a route sign: a plate with a pointed right end, like a cycle-route signpost
local function plate(x, y, w, h, tip, col)
  UI.rect(x, y, w - tip, h, col)
  for i = 0, h - 1 do
    local d = floor(tip - math.abs(i - (h - 1) / 2) + 0.0)
    if d > 0 then UI.rect(x + w - tip, y + i, d, 1, col) end
  end
end
function UI.sign(x, y, w, h, fill, edge)
  local tip = floor(h / 2)
  plate(x + 1, y + 1, w, h, tip, C.shadow)
  plate(x, y, w, h, tip, edge)
  plate(x + 1, y + 1, w - 2, h - 2, tip - 1, fill)
end
function UI.disc(cx, cy, r, col)
  for yy = -r, r do
    local w = floor(math.sqrt(r * r - yy * yy))
    UI.rect(cx - w, cy + yy, w * 2 + 1, 1, col)
  end
end
-- darken towards one side (the menu's left edge)
function UI.fade_left(w, a)
  for i = 0, w - 1, 2 do
    UI.rect(i, 0, 2, UI.H, Color(10, 16, 22, floor(255 * a * min(1, (w - i) / (w / 2)))))
  end
end

-- a height profile coloured by steepness like a race book (green flat, yellow, orange, red steep, blue down);
-- the part already ridden darker. prof = { {metres, height}, ... }. Returns a function giving the screen
-- position of a distance.
local GRADE_COL = {
  { 9, Color(192, 57, 43) }, { 6, Color(224, 115, 42) }, { 3, Color(233, 181, 44) }, { -1, Color(127, 178, 74) },
  { -1000, Color(79, 143, 191) },
}
local function darker(c) return Color(floor(c.r * 0.55), floor(c.g * 0.55), floor(c.b * 0.55)) end
for _, g in ipairs(GRADE_COL) do g[3] = darker(g[2]) end
-- (worked out once per profile, size and ridden column, then only drawn: menus and the ride call it every frame)
local prof_cache = setmetatable({}, { __mode = "k" })
function UI.profile(prof, x, y, w, h, upto)
  if not prof or #prof < 2 then return function() return x, y + h end end
  local d0, d1 = prof[1][1], prof[#prof][1]
  local span = d1 - d0
  local upcol = upto and floor((upto - d0) / max(1, span) * (w - 1)) or -1
  local key = w .. ":" .. h .. ":" .. upcol
  local P = prof_cache[prof]
  if not P or P.key ~= key then
    local lo, hi = math.huge, -math.huge
    for _, p in ipairs(prof) do lo = min(lo, p[2]); hi = max(hi, p[2]) end
    -- at least 30 m tall, so a flat route stays flat
    if hi - lo < 30 then local c = (hi + lo) / 2; lo, hi = c - 15, c + 15 end
    local pad = (hi - lo) * 0.12
    lo, hi = lo - pad, hi + pad * 0.3
    local j = 1
    local function at(d)
      if d <= prof[1][1] then return prof[1][2] end
      if d >= prof[#prof][1] then return prof[#prof][2] end
      while j > 1 and prof[j][1] > d do j = j - 1 end
      while j < #prof - 1 and prof[j + 1][1] < d do j = j + 1 end
      local a, b = prof[j], prof[j + 1] or prof[j]
      return a[2] + (b[2] - a[2]) * ((d - a[1]) / max(1, b[1] - a[1]))
    end
    -- coloured by the average grade of each stretch, like a race book: about a kilometre, at least 6 pixels wide
    local seg = max(span / w * 6, 500)
    if span / seg > 40 then seg = span / 40 end
    local cols, tops = {}, {}
    local last_seg, last_col = nil, nil
    for i = 0, w - 1 do
      local d = d0 + span * i / max(1, w - 1)
      tops[i] = floor(h - (at(d) - lo) / (hi - lo) * h)
      local si = floor((d - d0) / seg)
      if si ~= last_seg then
        local a = d0 + si * seg
        local b = min(d1, a + seg)
        local g = (at(b) - at(a)) / max(1, b - a) * 100
        last_col = GRADE_COL[#GRADE_COL]
        for _, gc in ipairs(GRADE_COL) do if g > gc[1] then last_col = gc; break end end
        last_seg = si
      end
      cols[i] = (i <= upcol) and last_col[3] or last_col[2]
    end
    P = { key = key, cols = cols, tops = tops, lo = lo, hi = hi, at = at }
    prof_cache[prof] = P
  end
  -- runs of columns with the same colour and top are drawn as one rectangle
  local cols, tops = P.cols, P.tops
  local i = 0
  while i < w do
    local c, t, n = cols[i], tops[i], 1
    while i + n < w and cols[i + n] == c and tops[i + n] == t do n = n + 1 end
    UI.rect(x + i, y + t, n, h - t, c)
    UI.rect(x + i, y + t, n, 1, C.text)
    i = i + n
  end
  local lo, hi, at = P.lo, P.hi, P.at
  return function(d)
    return x + floor((d - d0) / max(1, span) * (w - 1)), floor(y + h - (at(d) - lo) / (hi - lo) * h)
  end
end

-- text cut to a width, with "..." when it does not fit
function UI.fit(str, font, w)
  if UI.textw(str, font) <= w then return str end
  while #str > 1 and UI.textw(str .. "...", font) > w do str = str:sub(1, -2) end
  return str .. "..."
end

-- ---- input: edges of keys and the mouse, read once a frame ----
local KEYS = { "UP", "DOWN", "LEFT", "RIGHT", "ENTER", "PAD_ENTER", "SPACE", "BACKSPACE", "TAB", "ESCAPE" }
local TYPE = {}
for i = 0, 9 do TYPE[#TYPE + 1] = { "KEY_" .. i, tostring(i) }; TYPE[#TYPE + 1] = { "KEY_PAD_" .. i, tostring(i) } end
for c = string.byte("A"), string.byte("Z") do TYPE[#TYPE + 1] = { "KEY_" .. string.char(c), string.char(c):lower() } end
for _, k in ipairs({ { "KEY_PERIOD", "." }, { "KEY_COMMA", "," }, { "KEY_MINUS", "-" }, { "KEY_PAD_DECIMAL", "." },
  { "KEY_PAD_MINUS", "-" }, { "KEY_SPACE", " " }, { "KEY_APOSTROPHE", "'" } }) do TYPE[#TYPE + 1] = k end
local held, mheld = {}, false
UI.pressed, UI.typed, UI.clicked, UI.wheel = {}, "", false, 0
function UI.read_input()
  UI.pressed, UI.typed = {}, ""
  for _, k in ipairs(KEYS) do
    local code = _G["KEY_" .. k]
    local down = code and input.IsKeyDown(code) or false
    if down and not held[k] then UI.pressed[k] = true end
    held[k] = down
  end
  if UI.pressed.PAD_ENTER then UI.pressed.ENTER = true end
  if UI.escape_pending then UI.pressed.ESCAPE = true; UI.escape_pending = nil end
  if UI.text_focus then
    local shift = input.IsKeyDown(KEY_LSHIFT) or input.IsKeyDown(KEY_RSHIFT)
    for _, k in ipairs(TYPE) do
      local code = _G[k[1]]
      local down = code and input.IsKeyDown(code) or false
      if down and not held[k[1]] then UI.typed = UI.typed .. (shift and k[2]:upper() or k[2]) end
      held[k[1]] = down
    end
  end
  local m = input.IsMouseDown(MOUSE_LEFT)
  UI.clicked = m and not mheld
  UI.mouse_down = m
  mheld = m
  UI.wheel = (UI.wheel_pending or 0); UI.wheel_pending = 0
  local mx, my = input.GetCursorPos()
  UI.mx, UI.my = (mx - UI.ox) / UI.s, (my - UI.oy) / UI.s
  if UI.mx ~= UI.last_mx or UI.my ~= UI.last_my then UI.mouse_moved = true; UI.last_mx, UI.last_my = UI.mx, UI.my
  else UI.mouse_moved = false end
end

-- ---- focus: every widget registers itself; up / down walk them in drawing order ----
UI.focus = UI.focus or {}             -- per screen: the focused widget's id
function UI.begin(screen)
  UI.screen_id = screen
  UI.order_prev = UI.order or {}
  UI.order = {}
  UI.active = nil
  if UI.focus[screen] == nil and UI.order_prev[1] then UI.focus[screen] = UI.order_prev[1] end
end
-- after the screen is drawn: move the focus with the keys
function UI.finish()
  local list = UI.order
  if #list == 0 then return end
  local cur = UI.focus[UI.screen_id]
  local idx
  for i, id in ipairs(list) do if id == cur then idx = i end end
  if not idx then UI.focus[UI.screen_id] = list[1]; return end
  if UI.text_focus and UI.text_focus ~= cur then UI.text_focus = nil end
  if UI.pressed.DOWN or (UI.pressed.TAB and not UI.text_focus) then UI.focus[UI.screen_id] = list[idx % #list + 1] end
  if UI.pressed.UP then UI.focus[UI.screen_id] = list[(idx - 2) % #list + 1] end
end
function UI.focused(id) return UI.focus[UI.screen_id] == id end
function UI.set_focus(id) UI.focus[UI.screen_id] = id end
-- a widget's box: hovered (mouse over it), focused, activated (clicked, or Enter while focused)
function UI.item(id, x, y, w, h)
  UI.order[#UI.order + 1] = id
  local over = UI.mx and UI.mx >= x and UI.mx < x + w and UI.my >= y and UI.my < y + h
  if over and UI.mouse_moved then UI.set_focus(id) end
  local f = UI.focused(id)
  local act = (over and UI.clicked) or (f and UI.pressed.ENTER)
  if act then UI.set_focus(id); UI.active = id end
  return over, f, act
end

-- ---- widgets ----
-- a menu line: plain text, the focused one a yellow route sign pointing right
function UI.menu_item(id, label, x, y, w)
  local _, f, act = UI.item(id, x - 8, y, w, 19)
  if f then
    UI.sign(x - 8, y, w, 19, C.sign, C.signDark)
    UI.text(label, x, y + 1, "J1", C.ink)
  else
    UI.stext(label, x, y + 1, "J1", C.text)
  end
  return act
end
-- a button: kind "go" (red sign), "sign" (yellow sign), or plain (a panel)
function UI.button(id, label, x, y, w, kind)
  local _, f, act = UI.item(id, x, y, w, 19)
  if kind == "go" or kind == "sign" then
    local fill, edge = C.red, C.redDark
    if kind == "sign" then fill, edge = C.sign, C.signDark end
    if f then UI.rect(x - 2, y - 2, w + 4, 23, C.text) end
    UI.sign(x, y, w, 19, fill, edge)
    UI.text(label, x + 7, y + 1, "J1", kind == "sign" and C.ink or C.text)
  else
    UI.panel(x, y, w, 19, f and C.ink2 or C.ink)
    if f then UI.rect(x, y + 18, w, 1, C.sign) end
    UI.text(label, x + w / 2, y + 1, "J1", f and C.sign or C.text, "center")
  end
  return act
end
-- a setting line: label on the left, value on the right; left / right (or clicking the arrows) change it.
-- values: a list of { value, text } or a number range { min, max, step, fmt }
function UI.setting(id, label, value, choices, x, y, w, note)
  local over, f, act = UI.item(id, x, y, w, 17)
  if f then UI.rect(x, y, w, 17, C.ink2); UI.rect(x, y + 16, w, 1, C.sign) end
  UI.text(label, x + 4, y + 2, "M2", f and C.sign or C.text)
  local text, nv = tostring(value), value
  local step = 0
  if f and UI.pressed.LEFT then step = -1 end
  if f and (UI.pressed.RIGHT or act) then step = 1 end
  -- the arrows can be clicked too
  local ax = x + w - 70
  if over and UI.clicked and UI.mx < x + w - 50 and UI.mx > x + w * 0.5 then step = -1 end
  if choices.min then
    local fmt = choices.fmt or "%g"
    if step ~= 0 then nv = math.Clamp(value + step * choices.step, choices.min, choices.max) end
    text = string.format(fmt, nv)
  else
    local i = 1
    for k, c in ipairs(choices) do if c[1] == value then i = k end end
    if step ~= 0 then i = (i - 1 + step) % #choices + 1; nv = choices[i][1] end
    text = choices[i] and choices[i][2] or tostring(nv)
  end
  local vw = max(40, UI.textw(text, "M2") + 22)
  ax = x + w - vw - 4
  UI.text("<", ax, y + 2, "M2", f and C.sign or C.dim)
  UI.text(text, x + w - 4 - floor(vw / 2), y + 2, "M2", C.text, "center")
  UI.text(">", x + w - 4, y + 2, "M2", f and C.sign or C.dim, "right")
  if note then UI.text(note, x + 4, y + 18, "M1", C.dim) end
  return nv, nv ~= value
end
-- a text field (search, coordinates): typing goes in while it is focused
function UI.textfield(id, text, x, y, w, hint)
  local _, f = UI.item(id, x, y, w, 17)
  if f then UI.text_focus = id end
  if f then
    if UI.pressed.BACKSPACE then text = text:sub(1, -2) end
    text = text .. UI.typed
  end
  UI.panel(x, y, w, 17, C.ink)
  if f then UI.rect(x + 1, y + 15, w - 2, 1, C.sign) end
  local shown = text ~= "" and text or (hint or "")
  UI.text(shown, x + 4, y + 2, "M2", text ~= "" and C.text or C.dim)
  if f and floor(RealTime() * 2) % 2 == 0 then
    UI.rect(x + 5 + (text ~= "" and UI.textw(text, "M2") or 0), y + 3, 1, 11, C.sign)
  end
  return text
end
-- a list of rows that scrolls to keep the focused row in view; draw_row(row, x, y, w, h, focused)
UI.scroll = UI.scroll or {}
function UI.list(id, rows, x, y, w, h, rh, draw_row)
  local n = #rows
  local first = UI.scroll[id] or 1
  local visible = floor(h / rh)
  -- keep the focused row in view
  local fi
  for i = 1, n do if UI.focused(id .. ":" .. i) then fi = i end end
  if fi then
    if fi < first then first = fi end
    if fi > first + visible - 1 then first = fi - visible + 1 end
  end
  if UI.wheel ~= 0 and UI.mx and UI.mx >= x and UI.mx < x + w and UI.my >= y and UI.my < y + h then
    first = first - UI.wheel
  end
  first = math.Clamp(first, 1, max(1, n - visible + 1))
  UI.scroll[id] = first
  local chosen
  for i = first, min(n, first + visible - 1) do
    local ry = y + (i - first) * rh
    local _, f, act = UI.item(id .. ":" .. i, x, ry, w, rh)
    draw_row(rows[i], x, ry, w, rh, f)
    if act then chosen = i end
  end
  -- a scroll bar when not everything fits
  if n > visible then
    local bh = max(6, floor(h * visible / n))
    local by = y + floor((h - bh) * (first - 1) / max(1, n - visible))
    UI.rect(x + w + 2, y, 2, h, C.ink2)
    UI.rect(x + w + 2, by, 2, bh, C.sign)
  end
  return chosen
end

-- ---- the bike computer: a small LCD ----
function UI.lcd(x, y, w, h)
  UI.rect(x + 1, y + 1, w, h, C.shadow)
  UI.rect(x, y, w, h, C.lcdFrame)
  UI.rect(x + 3, y + 3, w - 6, h - 6, C.lcdEdge)
  UI.rect(x + 4, y + 4, w - 8, h - 8, C.lcd)
end

-- numbers: a duration as h:mm:ss, a distance in the player's units
function UI.clock(t)
  t = max(0, floor(t or 0))
  return string.format("%d:%02d:%02d", floor(t / 3600), floor(t / 60) % 60, t % 60)
end
UI.imperial = false
function UI.km(m, decimals)
  if UI.imperial then return string.format("%." .. (decimals or 1) .. "f", m / 1609.344), "mi" end
  return string.format("%." .. (decimals or 1) .. "f", m / 1000), "km"
end
function UI.speed(ms)
  if UI.imperial then return string.format("%.1f", ms * 2.23694), "mph" end
  return string.format("%.1f", ms * 3.6), "km/h"
end
function UI.height(m)
  if UI.imperial then return string.format("%.0f", m * 3.28084), "ft" end
  return string.format("%.0f", m), "m"
end

-- GMod's Esc opens its own pause menu: the game takes that key for its own menus instead
hook.Add("OnPauseMenuShow", "TinyAtlas_UI", function()
  if UI.wants_escape then UI.escape_pending = true; return false end
end)
-- the mouse wheel (lists)
hook.Add("PlayerBindPress", "TinyAtlas_UIWheel", function(_, bind, pressed)
  if not UI.cursor then return end
  if bind == "invprev" then UI.wheel_pending = (UI.wheel_pending or 0) + 1; return true end
  if bind == "invnext" then UI.wheel_pending = (UI.wheel_pending or 0) - 1; return true end
end)
