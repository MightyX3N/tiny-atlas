-- The window: the preview on the left, the settings on the right. It
-- grows and shrinks with its edges; the bar between the two can be
-- dragged, and the settings put away to give the preview all the room.
--
-- The preview shows the water over the sprite's other layers, round the
-- masks; the wheel zooms at the mouse, a drag moves the picture, a double
-- click fits it again. It follows the sprite: paint or erase on a mask
-- layer and the water redraws (a moment after the stroke). Drawing is
-- done in slices on a timer (Engine), so Aseprite never stalls; frames
-- already drawn keep playing while new ones come in.
--
-- Down the preview's left edge: the three mask layers ("Water": still
-- water, "River": flowing water, "Fall": where it falls; any may be
-- "none"), the look and a new variation, play, the rods, fit, the
-- settings (out or away) and the keys. Apply sits at its bottom right.
--
-- Guide rods (the rods button turns them on) are drawn and bent right on
-- the preview (Rods); the water near them runs along them. They are kept
-- per sprite.

local G = ... or _WOWE

local Styles  = G.require("styles")
local Mask    = G.require("mask")
local Engine  = G.require("engine")
local Paint   = G.require("paint")
local Output  = G.require("output")
local I18n    = G.require("i18n")
local Palette = G.require("palette")
local Guide   = G.require("guide")
local Rods    = G.require("rods")
local Style   = G.require("ui_style")
local Window  = G.require("ui_window")
local Pages   = G.require("ui_pages")

local T = I18n.t

local Ui = {}

local floor, ceil, max, min, abs = math.floor, math.ceil, math.max, math.min, math.abs

-- The timer's beat, and how much of each beat the baking may take.
local TICK, BUDGET = 0.03, 0.022
-- The preview's info line at the top and status line at the bottom.
local INFO_H, FOOT_H = 20, 26
local ZOOMS = { 0.25, 0.5, 1, 2, 3, 4, 5, 6, 8, 10, 12, 16, 20, 24, 32 }

local timer, prefs
local win                        -- the window
local p                          -- the settings
local spr                        -- the sprite being watched
local sprListener, siteListener
local layerList = {}
local waterLayer, riverLayer, fallLayer
local region, regionSig
local view, bg, fg               -- the part of the sprite on show, and its picture:
                                 -- the layers under the water, and those over it
local shown = {}                 -- frame -> { lv, x0, y0, w, h, img, key }, baked
                                 -- for the settings in use
local hold = nil                 -- what was on show before they changed, kept
                                 -- until their first frame is baked
local rgbMap, colorKey
local playing = true
local cur, acc = 1, 0
local ticks, dirtyAt = 0, nil
local notice, noticeUntil = nil, 0
local tab = "look"
-- The view: nil zoom fits the picture; else its scale and the sprite
-- point at the middle of the picture.
local zoom, panX, panY = nil, 0, 0
local press, pan = nil, nil      -- a left press on the picture; a drag moving it
local clickToggled = false       -- the last click played or paused (a double
                                 -- click takes that back)

--------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------

local function layerName(l)
  if not l then return nil end
  local ok, n = pcall(function() return l.name end)
  return ok and n or nil
end

-- Every sprite has its own guide rods. While Aseprite runs they are kept
-- with the sprite itself; a sprite saved in a file also keeps them in the
-- preferences, under a name made from the file's (so they are back the
-- next time).
local sessionRods = {}
local MAX_ROD_SETS = 40

local function spriteId(s)
  local ok, name = pcall(function() return s.filename end)
  if not ok or type(name) ~= "string" or name == "" or not app.fs.isFile(name) then return nil end
  local h = 2166136261
  for i = 1, #name do h = ((h ~ name:byte(i)) * 16777619) & 0xffffffff end
  return string.format("s%08x", h)
end

-- This sprite's entry in the session's rods (made when `make`); closed
-- sprites are forgotten.
local function sessionEntry(s, make)
  local keep, found = {}, nil
  for _, e in ipairs(sessionRods) do
    local ok, alive = pcall(function() return e.sprite.width ~= nil end)
    if ok and alive then
      keep[#keep + 1] = e
      if not found then
        local ok2, same = pcall(function() return e.sprite == s end)
        if ok2 and same then found = e end
      end
    end
  end
  sessionRods = keep
  if not found and make then
    found = { sprite = s }
    sessionRods[#sessionRods + 1] = found
  end
  return found
end

local function save()
  if not prefs then return end
  local q = Styles.copy(p)
  q.guides = nil
  prefs.settings = q
  if not spr then return end
  sessionEntry(spr, true).rods = Guide.copy(p.guides)
  local id = spriteId(spr)
  if id then
    if type(prefs.rodSets) ~= "table" then prefs.rodSets = {} end
    local sets = prefs.rodSets
    sets[id] = (#p.guides > 0) and Guide.copy(p.guides) or nil
    local n = 0
    for _ in pairs(sets) do n = n + 1 end
    if n > MAX_ROD_SETS then
      for k in pairs(sets) do
        if k ~= id then sets[k] = nil break end
      end
    end
  end
end

-- The guide rods' editor on the preview, and where the view was last
-- drawn (for the mouse).
local rods = Rods.new(function() return p.guides end, function(list) p.guides = list end)
local viewMap = nil
-- Whether the rods are drawn on the preview (hidden, they still work, but
-- cannot be edited).
local showRods = true

local function rodsLive()
  return p.guideOn and showRods
end

local function flash(text, seconds)
  notice = text
  noticeUntil = ticks + floor((seconds or 2.5) / TICK)
end

local function repaint()
  if win then win:repaint() end
end
local repaintView = repaint

local function setShowRods(v)
  showRods = v
  if prefs then prefs.showRods = v end
  rods.drag, rods.hover, rods.branch = nil, nil, false
  repaint()
end

local function frameNumber()
  local ok, n = pcall(function()
    if app.sprite == spr and app.frame then return app.frame.frameNumber end
    return 1
  end)
  return ok and n or 1
end

--------------------------------------------------------------------------
-- the sprite, the mask layers, the background
--------------------------------------------------------------------------

local function byName(name)
  if not name or name == "" then return nil end
  for _, e in ipairs(layerList) do
    if e.layer.name == name then return e.layer end
  end
  return nil
end

-- The image layers again; keeps the mask layers that are still there.
local function refreshLayers()
  local before = {}
  for i, e in ipairs(layerList) do before[i] = e.label end
  layerList = Mask.imageLayers(spr)
  local hasFall, hasWater, hasRiver = false, false, false
  for _, e in ipairs(layerList) do
    if e.layer == fallLayer then hasFall = true end
    if e.layer == waterLayer then hasWater = true end
    if e.layer == riverLayer then hasRiver = true end
  end
  -- The layer picked last time; "" when "none" was picked; else a guess.
  if not hasFall then
    local name = prefs and prefs.fallName
    fallLayer = byName(name)
    if not fallLayer and name ~= "" then
      local e = Mask.guessFall(layerList, waterLayer)
      fallLayer = e and e.layer or nil
    end
  end
  if not hasRiver then
    local name = prefs and prefs.riverName
    riverLayer = byName(name)
    if not riverLayer and name ~= "" then
      local e = Mask.guessRiver(layerList, fallLayer, waterLayer)
      riverLayer = e and e.layer or nil
    end
  end
  if riverLayer == fallLayer then riverLayer = nil end
  if not hasWater then
    local name = prefs and prefs.waterName
    waterLayer = byName(name)
    if not waterLayer and name ~= "" then
      local e = Mask.guessWater(layerList, fallLayer, riverLayer)
      waterLayer = e and e.layer or nil
    end
  end
  if waterLayer == fallLayer or waterLayer == riverLayer then waterLayer = nil end
  local same = #before == #layerList
  if same then
    for i, e in ipairs(layerList) do
      if before[i] ~= e.label then same = false end
    end
  end
  if not same then repaintView() end
end

-- Reads the masks again when their pixels changed. True when they did.
local function readRegion()
  local f = frameNumber()
  local sig = ""
  if spr and (waterLayer or riverLayer or fallLayer) then
    sig = Mask.signature(spr, waterLayer, f) .. "|" .. Mask.signature(spr, fallLayer, f) .. "|" ..
      Mask.signature(spr, riverLayer, f)
  end
  if sig == regionSig then return false end
  regionSig = sig
  if not spr then
    region = nil
  else
    region = Mask.read(spr, waterLayer, fallLayer, f, riverLayer)
  end
  return true
end

-- The other layers, flattened, round the masks (checkers underneath): the
-- ones under the water and the ones over it apart, so the preview stacks
-- them as the sprite does. The water's place: its layer when there is
-- one, else just over the water's mask layer (where Apply puts it).
local function rebuildBg()
  bg, fg, view = nil, nil, nil
  if not spr then return end
  local W, H = spr.width, spr.height
  if region then
    view = { x = region.x0, y = region.y0, w = region.w, h = region.h }
  else
    view = { x = 0, y = 0, w = W, h = H }
  end
  local img = Image(view.w, view.h, ColorMode.RGB)
  -- Checkers of 4 px, a row at a time.
  local A, B = string.char(64, 66, 70, 255):rep(4), string.char(84, 86, 90, 255):rep(4)
  local reps = ceil(view.w / 8) + 2
  local r1, r2 = (A .. B):rep(reps), (B .. A):rep(reps)
  local off = (view.x % 8) * 4
  local rows = {}
  for y = 0, view.h - 1 do
    local r = (((view.y + y) >> 2) % 2 == 0) and r1 or r2
    rows[y + 1] = r:sub(off + 1, off + view.w * 4)
  end
  img.bytes = table.concat(rows)
  local f = frameNumber()
  local function visible(l)
    while l and l ~= spr do
      if not l.isVisible then return false end
      l = l.parent
    end
    return true
  end
  -- Every image layer, bottom to top, and where the water goes among them.
  local order, slot, maskAt = {}, nil, nil
  local function walk(layers)
    for _, l in ipairs(layers) do
      if l.isGroup then
        walk(l.layers)
      elseif l.isImage then
        order[#order + 1] = l
        if l.name == Mask.OUTPUT_NAME and not slot then slot = #order end
        if l == (waterLayer or riverLayer or fallLayer) then maskAt = #order end
      end
    end
  end
  local over = nil
  local function draw(target, l)
    local cel = l:cel(f)
    if cel and cel.image then
      local at = Point(cel.position.x - view.x, cel.position.y - view.y)
      local opacity = floor((l.opacity or 255) * (cel.opacity or 255) / 255)
      local ok = pcall(function() target:drawImage(cel.image, at, opacity, l.blendMode) end)
      if not ok then pcall(function() target:drawImage(cel.image, at) end) end
    end
  end
  if spr.colorMode == ColorMode.RGB then
    walk(spr.layers)
    slot = slot or ((maskAt or #order) + 0.5)
    for i, l in ipairs(order) do
      if l ~= fallLayer and l ~= waterLayer and l ~= riverLayer and l.name ~= Mask.OUTPUT_NAME
          and visible(l) then
        if i < slot then
          draw(img, l)
        else
          over = over or Image(view.w, view.h, ColorMode.RGB)
          draw(over, l)
        end
      end
    end
  else
    -- Other colour modes: the whole sprite as Aseprite draws it.
    pcall(function()
      local full = Image(W, H, ColorMode.RGB)
      full:drawSprite(spr, f)
      img:drawImage(full, Point(-view.x, -view.y))
    end)
  end
  bg, fg = img, over
end

--------------------------------------------------------------------------
-- the water
--------------------------------------------------------------------------

-- New settings or new masks: bake again, from the frame on show on. The
-- old picture stays until the new one is there.
local function restart()
  hold = shown[cur] or hold
  shown = {}
  if cur > p.frames then cur = 1 end
  if not region then hold = nil end
  Engine.want = cur
  Engine.start(region, Styles.copy(p))
end

Engine.onFrame = function(i, lv)
  local B = Engine.F.base
  shown[i] = { lv = lv, x0 = B.x0, y0 = B.y0, w = B.w, h = B.h }
end

-- The colours and opacities as one string: frame images are made again
-- when it changes (no baking: only the colouring).
local function lookKey()
  local parts = { table.concat(p.colors, "") }
  for _, k in ipairs(Styles.ALPHA_KEYS) do parts[#parts + 1] = p.alpha[k] end
  return table.concat(parts, ":")
end

local function frameImage(e)
  local key = lookKey()
  if key ~= colorKey then
    colorKey = key
    rgbMap = Paint.map(p.colors, nil, p.alpha)
  end
  if e.img == nil or e.key ~= colorKey then
    e.img = Paint.image(e.lv, e.w, e.h, rgbMap)
    e.key = colorKey
  end
  return e.img
end

-- Watches this sprite (or none).
local function bind(s)
  if sprListener and spr then
    pcall(function() spr.events:off(sprListener) end)
  end
  sprListener = nil
  spr = s
  layerList, waterLayer, riverLayer, fallLayer, regionSig = {}, nil, nil, nil, nil
  shown, hold = {}, nil
  zoom, press, pan = nil, nil, nil
  -- This sprite's rods.
  local e = spr and sessionEntry(spr, false)
  local id = spr and spriteId(spr)
  local sets = prefs and prefs.rodSets
  p.guides = Guide.copy((e and e.rods) or (id and type(sets) == "table" and sets[id]) or nil)
  rods:reset()
  viewMap = nil
  if spr then
    sprListener = spr.events:on("change", function() dirtyAt = ticks end)
  end
  refreshLayers()
  readRegion()
  rebuildBg()
  restart()
  repaint()
end

--------------------------------------------------------------------------
-- what the settings and the toolbar do
--------------------------------------------------------------------------

local function changed()
  save()
  restart()
  repaint()
end

local function setter(key)
  return function(v)
    p[key] = v
    changed()
  end
end

-- Colours and opacity: only the colouring changes, nothing is baked again.
local function recolor()
  save()
  repaint()
end

local function setLook(name)
  Styles.apply(name, p)
  changed()
end

local function togglePlay()
  playing = not playing
  acc = 0
  repaint()
end

local function newSeed()
  p.seed = (p.seed or 1) % 9973 + 1
  changed()
end

local function setGuideOn(v)
  p.guideOn = v
  rods.branch, rods.drag = false, nil
  changed()
end

-- The rods' buttons (on the toolbar's strip and on the Rods tab).
local function rodAction(name)
  if name == "flow" or name == "lip" then
    rods.kind = name
    rods.branch = false
    repaint()
  elseif name == "branch" then
    if not p.guideOn then flash(T("msg_guides_off")) repaint() return end
    if #p.guides == 0 then flash(T("msg_no_rods")) repaint() return end
    rods.branch = not rods.branch
    repaint()
  elseif name == "reverse" then
    if rods:reverse() then changed() else flash(T("msg_pick_rod")) repaint() end
  elseif name == "undo" then
    if rods:undo() then changed() end
  elseif name == "clear" then
    if rods:clear() then changed() end
  elseif name == "show" then
    setShowRods(not showRods)
  end
end

-- The six colours from one: the base colour is the water's own tone, the
-- other five come from it (Palette).
local function makeRamp()
  if not p.palBase then p.palBase = p.colors[3] end
  p.colors = Palette.ramp(p.palBase, p.palHue, p.palSat, p.palRange)
  recolor()
end

local function slotLayer(key)
  if key == "fall" then return fallLayer end
  if key == "river" then return riverLayer end
  return waterLayer
end

-- A layer picked for a mask (or "none"); no two masks on the same layer.
local function pickMask(key, l)
  if l == "none" then l = nil end
  if key == "fall" then
    fallLayer = l
  elseif key == "river" then
    riverLayer = l
  else
    waterLayer = l
  end
  if l then
    if key ~= "fall" and fallLayer == l then fallLayer = nil end
    if key ~= "river" and riverLayer == l then riverLayer = nil end
    if key ~= "water" and waterLayer == l then waterLayer = nil end
  end
  if prefs then
    prefs.fallName = layerName(fallLayer) or ""
    prefs.riverName = layerName(riverLayer) or ""
    prefs.waterName = layerName(waterLayer) or ""
  end
  regionSig = nil
  readRegion()
  rebuildBg()
  changed()
end

--------------------------------------------------------------------------
-- the preview
--------------------------------------------------------------------------

-- The room the picture has: right of the toolbar, between the two lines.
local function area(W, H, inset)
  return inset, INFO_H, max(10, W - inset - 6), max(10, H - INFO_H - FOOT_H)
end

local function fitScale(aw, ah)
  local s = min(aw / view.w, ah / view.h)
  if s >= 1 then s = floor(s) end
  return max(0.05, s)
end

-- Part of a picture covering sprite px (X0, Y0, w, h), drawn at scale s
-- with the view's corner at (ox, oy): only what falls on the canvas.
local function drawPart(gc, img, X0, Y0, w, h, s, ox, oy, W, H)
  local sx0 = max(X0, floor(view.x + (0 - ox) / s))
  local sy0 = max(Y0, floor(view.y + (0 - oy) / s))
  local sx1 = min(X0 + w, ceil(view.x + (W - ox) / s))
  local sy1 = min(Y0 + h, ceil(view.y + (H - oy) / s))
  if sx1 <= sx0 or sy1 <= sy0 then return end
  local dx0, dy0 = floor(ox + (sx0 - view.x) * s + 0.5), floor(oy + (sy0 - view.y) * s + 0.5)
  local dx1, dy1 = floor(ox + (sx1 - view.x) * s + 0.5), floor(oy + (sy1 - view.y) * s + 0.5)
  if dx1 <= dx0 or dy1 <= dy0 then return end
  gc:drawImage(img, Rectangle(sx0 - X0, sy0 - Y0, sx1 - sx0, sy1 - sy0), Rectangle(dx0, dy0, dx1 - dx0, dy1 - dy0))
end

local function maskLine()
  local parts = {}
  for _, key in ipairs({ "water", "river", "fall" }) do
    parts[#parts + 1] = T(key .. "_label"):format(layerName(slotLayer(key)) or T("none"))
  end
  return table.concat(parts, "   ")
end

local function paintPreview(gc, W, H, inset)
  local ax, ay, aw, ah = area(W, H, inset)
  viewMap = nil
  if bg and view then
    local s = zoom or fitScale(aw, ah)
    local cx = zoom and panX or (view.x + view.w / 2)
    local cy = zoom and panY or (view.y + view.h / 2)
    local acx, acy = ax + aw / 2, ay + ah / 2
    local ox = floor(acx - (cx - view.x) * s + 0.5)
    local oy = floor(acy - (cy - view.y) * s + 0.5)
    drawPart(gc, bg, view.x, view.y, view.w, view.h, s, ox, oy, W, H)
    local e = region and (shown[cur] or hold)
    if e then drawPart(gc, frameImage(e), e.x0, e.y0, e.w, e.h, s, ox, oy, W, H) end
    if fg then drawPart(gc, fg, view.x, view.y, view.w, view.h, s, ox, oy, W, H) end
    viewMap = { s = s, ox = ox, oy = oy, x = view.x, y = view.y, w = view.w, h = view.h, acx = acx, acy = acy }
    if rodsLive() then rods:draw(gc, viewMap) end
  end
  local msg = nil
  if not spr then msg = T("msg_nosprite")
  elseif not (waterLayer or riverLayer or fallLayer) then msg = T("msg_nolayer")
  elseif not region then msg = T("msg_empty") end
  if msg then
    local tw = Style.measure(gc, msg)
    Style.label(gc, msg, max(ax, floor(ax + (aw - tw) / 2)), floor(ay + ah / 2 - 6))
  end

  -- The info line: the masks, and the zoom on the right.
  local zs = zoom and string.format("%d%%", floor((viewMap and viewMap.s or zoom) * 100 + 0.5)) or T("zoom_fit")
  local zw = Style.measure(gc, zs)
  Style.label(gc, zs, W - 10 - zw, 5, Style.TEXT_DIM)
  Style.label(gc, Style.fit(gc, maskLine(), W - inset - zw - 24), inset, 5, Style.TEXT_DIM)

  -- The status line: the frame on show, the baking; a notice above it;
  -- Apply on the right.
  local by = H - FOOT_H + 4
  if not msg then
    local line = T("frame_counter"):format(cur, p.frames)
    if not Engine.ready then
      line = line .. "   " .. T("msg_preparing")
    elseif not Engine.done then
      line = line .. "   " .. T("msg_baked"):format(Engine.count(), p.frames)
    end
    if not playing then line = line .. "   " .. T("msg_paused") end
    if p.guideOn and rods.branch then line = line .. "   " .. T("msg_branch") end
    local _, th = Style.measure(gc, line)
    Style.label(gc, Style.fit(gc, line, W - inset - 100), inset, by + floor((18 - th) / 2), Style.TEXT_DIM)
  end
  if notice and ticks < noticeUntil then
    local nw = Style.measure(gc, notice)
    Style.label(gc, notice, max(ax, floor(ax + (aw - nw) / 2)), H - FOOT_H - 18, Style.TIP_TEXT)
  end
  win:viewButton(gc, { id = "apply", x = W - 82, y = by, w = 76, h = 18, text = T("apply"), icon = "export",
    primary = true, tip = T("tip_apply"), click = function() Ui.apply() end })
end

-- The view fitted again.
local function fitView()
  zoom, pan, press = nil, nil, nil
  repaintView()
end

-- Zoom to scale s, keeping the sprite point under (mx, my) where it is.
local function zoomTo(s, mx, my)
  local M = viewMap
  if not M then return end
  s = max(ZOOMS[1], min(ZOOMS[#ZOOMS], s))
  mx, my = mx or M.acx, my or M.acy
  local sx, sy = M.x + (mx - M.ox) / M.s, M.y + (my - M.oy) / M.s
  panX = sx - (mx - M.acx) / s
  panY = sy - (my - M.acy) / s
  zoom = s
  repaintView()
end

-- The next zoom step in (dir 1) or out (dir -1).
local function zoomStep(dir, mx, my)
  local M = viewMap
  if not M then return end
  local s = M.s
  local pick = nil
  if dir > 0 then
    for _, z in ipairs(ZOOMS) do if z > s * 1.01 then pick = z break end end
  else
    for i = #ZOOMS, 1, -1 do if ZOOMS[i] < s * 0.99 then pick = ZOOMS[i] break end end
  end
  if pick then zoomTo(pick, mx, my) end
end

local function startPan(ev)
  local M = viewMap
  if not M then return end
  if not zoom then
    zoom = M.s
    panX, panY = M.x + (M.acx - M.ox) / M.s, M.y + (M.acy - M.oy) / M.s
  end
  pan = { x = ev.x, y = ev.y, px = panX, py = panY, s = zoom }
end

local function previewDown(ev)
  press, pan = nil, nil
  clickToggled = false
  if ev.button == MouseButton.MIDDLE then startPan(ev) return end
  if rodsLive() and viewMap and region then
    local r = rods:mousedown(ev, viewMap)
    if r == "changed" then changed() return end
    if r then repaint() return end
  end
  if ev.button == MouseButton.RIGHT then startPan(ev) return end
  if ev.button == MouseButton.LEFT then press = { x = ev.x, y = ev.y } end
end

local function previewMove(ev)
  if pan then
    panX = pan.px - (ev.x - pan.x) / pan.s
    panY = pan.py - (ev.y - pan.y) / pan.s
    repaintView()
    return
  end
  if press then
    if max(abs(ev.x - press.x), abs(ev.y - press.y)) >= 3 then
      startPan(press)
      press = nil
      previewMove(ev)
    end
    return
  end
  if rodsLive() and viewMap and rods:mousemove(ev, viewMap) then repaint() end
end

local function previewUp(ev)
  if pan then
    pan = nil
    repaintView()
    return
  end
  if press then
    press = nil
    togglePlay()
    clickToggled = true
    return
  end
  if rodsLive() and viewMap then
    local r = rods:mouseup(ev, viewMap)
    if r == "click" then
      togglePlay()
      clickToggled = true
    elseif r == "changed" then
      changed()
    elseif r then
      repaint()
    end
  end
end

local function previewKey(ev)
  local code = ev.code or ""
  if code == "Space" then togglePlay() return true end
  if code == "KeyF" or code == "Home" then fitView() return true end
  if code == "Equal" or code == "NumpadAdd" or ev.key == "+" then zoomStep(1) return true end
  if code == "Minus" or code == "NumpadSubtract" or ev.key == "-" then zoomStep(-1) return true end
  if code == "Escape" and rods.branch then
    rods.branch = false
    repaint()
    return true
  end
  return false
end

local function lookMenu()
  local rows = {}
  for _, g in ipairs(Pages.LOOK_GROUPS) do
    rows[#rows + 1] = { label = T(g[1]), section = true }
    for i = g[2], g[3] do
      local name = Styles.ORDER[i]
      local sw = {}
      for k, hex in ipairs(Styles.LOOKS[name].colors) do sw[k] = Style.colorOf(hex) end
      rows[#rows + 1] = { label = T(name), value = name, current = (p.style == name), swatches = sw }
    end
  end
  return { title = T("tip_look"), rows = rows, pick = function(row) setLook(row.value) end }
end

local function previewMenu(id)
  local key = id:match("^mask_(%a+)$")
  if key then
    local current = slotLayer(key)
    local rows = { { label = T("none"), value = "none", current = (current == nil) } }
    for _, e in ipairs(layerList) do
      rows[#rows + 1] = { label = e.label, value = e.layer, current = (e.layer == current) }
    end
    return { title = T("mask_" .. key), rows = rows, pick = function(row) pickMask(key, row.value) end }
  elseif id == "look" then
    return lookMenu()
  end
  return nil
end

local toggleSettings, panelShown

local function previewTools()
  local function mask(key, icon)
    local l = slotLayer(key)
    return { id = "mask_" .. key, icon = icon, kind = "menu", dim = (l == nil),
             tip = T(key .. "_label"):format(layerName(l) or T("none")) }
  end
  return {
    mask("water", "pool"), mask("river", "river"), mask("fall", "fall"),
    { group = true },
    { id = "look", icon = "drop", kind = "menu", tip = T("tip_look") },
    { id = "seed", icon = "dice", tip = T("tip_seed"), click = newSeed },
    { group = true },
    { id = "play", icon = playing and "pause" or "play", tip = playing and T("tip_pause") or T("tip_play"),
      click = togglePlay },
    { id = "rods", icon = "rod", on = p.guideOn, tip = p.guideOn and T("tip_rods_on") or T("tip_rods_off"),
      click = function() setGuideOn(not p.guideOn) end,
      strip = {
        { id = "rodFlow", icon = "rod", tip = T("rod_flow_tip"), on = rods.kind == "flow",
          click = function() rodAction("flow") end },
        { id = "rodLip", icon = "rodLip", tip = T("rod_lip_tip"), on = rods.kind == "lip",
          click = function() rodAction("lip") end },
        { id = "rodBranch", icon = "branch", tip = T("rod_branch_tip"), on = rods.branch and p.guideOn,
          click = function() rodAction("branch") end },
        { id = "rodReverse", icon = "reverse", tip = T("rod_reverse_tip"), click = function() rodAction("reverse") end },
        { id = "rodUndo", icon = "undo", tip = T("rod_undo_tip"), click = function() rodAction("undo") end },
        { id = "rodClear", icon = "trash", tip = T("rod_clear_tip"), click = function() rodAction("clear") end },
        { id = "rodShow", icon = showRods and "eye" or "eyeOff", tip = T("rod_show_tip"),
          click = function() rodAction("show") end },
      } },
    { group = true },
    { id = "fit", icon = "fit", tip = T("tip_fit"), click = fitView },
    { id = "settings", icon = "gear", on = panelShown(), tip = T("tip_settings"),
      click = function() toggleSettings() end },
  }
end

local function previewKeys()
  return { title = T("keys_title"), sections = {
    { title = T("keys_view"), rows = {
      { T("k_space"), T("k_space_d") }, { T("k_click"), T("k_click_d") }, { T("k_wheel"), T("k_wheel_d") },
      { T("k_drag"), T("k_drag_d") }, { T("k_fit"), T("k_fit_d") }, { T("k_zoom"), T("k_zoom_d") } } },
    { title = T("keys_rods"), rows = {
      { T("k_new"), T("k_new_d") }, { T("k_dot"), T("k_dot_d") }, { T("k_line"), T("k_line_d") },
      { T("k_shift"), T("k_shift_d") }, { T("k_alt"), T("k_alt_d") }, { T("k_right"), T("k_right_d") } } },
    { title = T("keys_layers"), rows = {
      { T("k_water"), T("k_water_d") }, { T("k_river"), T("k_river_d") }, { T("k_fall"), T("k_fall_d") },
      { T("k_mouth"), T("k_mouth_d") } } },
  } }
end

--------------------------------------------------------------------------
-- the window
--------------------------------------------------------------------------

-- Where the window was left, kept in the preferences.
local function place(name, r)
  if not (prefs and r) then return end
  if type(prefs.places) ~= "table" then prefs.places = {} end
  prefs.places[name] = { r.x, r.y, r.width, r.height }
end

local function placeOf(name)
  local t = prefs and type(prefs.places) == "table" and prefs.places[name]
  if type(t) ~= "table" then return nil end
  local x, y, w, h = tonumber(t[1]), tonumber(t[2]), tonumber(t[3]), tonumber(t[4])
  if not (x and y and w and h) or w < 200 or h < 160 then return nil end
  local sw, sh = 1280, 720
  pcall(function() sw, sh = app.window.width, app.window.height end)
  -- Back on the screen if the screen got smaller.
  w, h = min(w, sw), min(h, sh)
  x = max(0, min(x, sw - 80))
  y = max(0, min(y, sh - 60))
  return Rectangle(x, y, w, h)
end

panelShown = function()
  return not (prefs and prefs.panelShown == false)
end

local function panelWidth()
  return tonumber(prefs and prefs.panelWidth) or 290
end

-- The settings put away (the picture gets the whole window) or out again.
toggleSettings = function()
  if prefs then prefs.panelShown = not panelShown() end
  repaint()
end

local function makeWindow()
  local ctx = {
    p = function() return p end,
    set = setter,
    recolor = recolor,
    setLook = setLook,
    color = function(i) return Style.colorOf(p.colors[i]) end,
    setColor = function(i, c)
      p.colors[i] = Pages.hexOf(c)
      repaint()
    end,
    takeColor = function(i)
      p.colors[i] = Pages.hexOf(app.fgColor)
      recolor()
    end,
    colorsDone = recolor,
    base = function() return Style.colorOf(p.palBase or p.colors[3]) end,
    setBase = function(c)
      p.palBase = Pages.hexOf(c)
      p.colors = Palette.ramp(p.palBase, p.palHue, p.palSat, p.palRange)
      repaint()
    end,
    takeBase = function()
      p.palBase = Pages.hexOf(app.fgColor)
      makeRamp()
    end,
    baseDone = recolor,
    makeRamp = makeRamp,
    rods = rods,
    showRods = function() return showRods end,
    setShowRods = setShowRods,
    setGuideOn = setGuideOn,
    rodAction = rodAction,
    newSeed = newSeed,
    tab = function() return tab end,
    setTab = function(key)
      tab = key
      if prefs then prefs.tabKey = key end
      repaint()
    end,
  }
  win = Window.new{
    name = "main", title = function() return T("title") end, width = 760, height = 440,
    tools = previewTools, menu = previewMenu, keys = previewKeys, keysTip = function() return T("tip_keys") end,
    place = place,
    view = { paint = paintPreview, down = previewDown, move = previewMove, up = previewUp,
      wheel = function(ev) zoomStep(((ev.deltaY or 0) < 0) and 1 or -1, ev.x, ev.y) end,
      dbl = function()
        -- The first click of it played or paused: back as it was.
        if clickToggled then togglePlay() end
        clickToggled = false
        fitView()
        return true
      end,
      key = previewKey,
      leave = function()
        if rods.hover then
          rods.hover = nil
          repaint()
        end
      end },
    panel = Pages.new(ctx),
    panelShown = panelShown,
    panelWidth = panelWidth,
    setPanelWidth = function(w) if prefs then prefs.panelWidth = floor(w) end end,
    onClose = function() Ui.cleanup() end,
  }
end

-- The window in the middle of the screen, or where it was left.
local function layout(d)
  local sw, sh = 1280, 720
  pcall(function() sw, sh = app.window.width, app.window.height end)
  local w = min(860, sw - 8)
  local h = max(380, min(600, sh - 80))
  local b = placeOf("main") or Rectangle(max(4, floor((sw - w) / 2)), max(20, floor((sh - h) / 2)), w, h)
  pcall(function() d.bounds = b end)
end

--------------------------------------------------------------------------
-- the timer: sprite changes, drawing, playback
--------------------------------------------------------------------------

local lastClock = nil

local function tick()
  ticks = ticks + 1
  -- Time since the last beat (os.clock runs with the wall clock on Windows;
  -- where it is processor time, count beats instead).
  local now = os.clock()
  local dt = lastClock and (now - lastClock) or TICK
  lastClock = now
  if dt < TICK * 0.5 or dt > 0.5 then dt = TICK end
  local need = false
  -- A moment after the sprite changed: the layers, the masks, the view.
  if dirtyAt and ticks - dirtyAt >= 7 then
    dirtyAt = nil
    local ok = pcall(function()
      refreshLayers()
      local changedMasks = readRegion()
      rebuildBg()
      if changedMasks then restart() end
    end)
    if not ok then bind(nil) end
    need = true
  end
  local n = p.frames
  if not Engine.done then
    -- Bake the frame on show first, then the one after it.
    Engine.want = (playing and shown[cur]) and (cur % n + 1) or cur
    local before = Engine.count()
    local ok, err = pcall(Engine.run, BUDGET)
    if not ok then flash(tostring(err), 6) end
    if Engine.count() ~= before or not ok then need = true end
  end
  if playing and region then
    acc = acc + dt
    local step = (p.ms or 90) / 1000
    if acc >= step then
      -- The next frame when it is baked; while baking, wait for it.
      local nx = cur % n + 1
      if shown[nx] then
        cur = nx
        acc = acc - step
        if acc > step then acc = 0 end
        need = true
      else
        acc = step
      end
    end
  end
  if notice and ticks == noticeUntil then need = true end
  if need then repaintView() end
end

--------------------------------------------------------------------------
-- open / close
--------------------------------------------------------------------------

function Ui.apply()
  if not (spr and (waterLayer or riverLayer or fallLayer) and region) then
    flash((not spr) and T("msg_nosprite") or T("msg_empty"))
    repaintView()
    return
  end
  local ok, err = pcall(function()
    Engine.want = cur
    Engine.finish()
    local B = Engine.F.base
    -- The frames were baked with the settings of their bake; colours and
    -- opacity bake nothing, so the ones on show now go with them.
    local q = Styles.copy(Engine.p)
    local now = Styles.copy({ colors = p.colors, alpha = p.alpha })
    q.colors, q.alpha = now.colors, now.alpha
    local _, note = Output.write(spr, waterLayer, fallLayer, { x0 = B.x0, y0 = B.y0, w = B.w, h = B.h },
      Engine.levels, q, riverLayer)
    flash(note or T("toast_applied"), note and 4 or 2.5)
  end)
  if not ok then flash(tostring(err), 6) end
  repaintView()
end

function Ui.open(preferences)
  if win and win:isOpen() then
    -- Already open: bring it to the active sprite.
    if app.sprite ~= spr then bind(app.sprite) end
    win:show()
    return
  end
  prefs = preferences or {}
  p = Styles.sanitize(prefs.settings)
  showRods = prefs.showRods ~= false
  tab = "look"
  for _, t in ipairs(Pages.TABS) do
    if prefs.tabKey == t.key then tab = t.key end
  end
  playing, cur, acc, ticks, dirtyAt = true, 1, 0, 0, nil
  zoom, press, pan = nil, nil, nil
  Engine.reset()
  makeWindow()
  bind(app.sprite)
  siteListener = app.events:on("sitechange", function()
    if app.sprite ~= spr then pcall(bind, app.sprite) end
  end)
  local d = win:show()
  if d then layout(d) end
  timer = Timer{ interval = TICK, ontick = function()
    local ok, err = pcall(tick)
    if not ok then flash(tostring(err), 6) end
  end }
  timer:start()
end

-- Stops watching and drawing (the window has closed).
function Ui.cleanup()
  save()
  if timer then timer:stop() timer = nil end
  if siteListener then pcall(function() app.events:off(siteListener) end) siteListener = nil end
  if sprListener and spr then pcall(function() spr.events:off(sprListener) end) end
  sprListener, spr = nil, nil
  shown, hold, bg, fg, view, region, regionSig = {}, nil, nil, nil, nil, nil, nil
  Engine.reset()
end

function Ui.close()
  if win and win:isOpen() then
    win:close()
    Ui.cleanup()
  end
end

-- As if the sprite had just changed (tests).
function Ui.touch() dirtyAt = ticks end

-- For tests.
function Ui.state()
  return { win = win, dlg = win and win.dlg, p = p, region = region, spr = spr, fallLayer = fallLayer,
           waterLayer = waterLayer, riverLayer = riverLayer, rods = rods, viewMap = viewMap, showRods = showRods,
           shown = shown, cur = cur, playing = playing, view = view, bg = bg, fg = fg, tick = tick, tab = tab,
           zoom = zoom, open = win ~= nil and win:isOpen() }
end

return Ui
