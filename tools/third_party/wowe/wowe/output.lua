-- Writes the loop into the sprite: a layer "WOWe Water" just above the
-- fall's mask layer (the same one again on later runs), one cel per frame
-- at the region's box. Frames are added when the sprite has fewer than the
-- loop; the other layers carry on into them as linked cels, so a still
-- scene stays one drawing. The mask layers are hidden (foam, mist and the
-- ragged edges would let them show). All in one undo step.

local G = ... or _WOWE

local Mask  = G.require("mask")
local Paint = G.require("paint")
local I18n  = G.require("i18n")

local Output = {}

local function findLayer(layers, name)
  for _, l in ipairs(layers) do
    if l.name == name and l.isImage then return l end
    if l.isGroup then
      local hit = findLayer(l.layers, name)
      if hit then return hit end
    end
  end
  return nil
end

local function eachImageLayer(layers, fn)
  for _, l in ipairs(layers) do
    if l.isGroup then eachImageLayer(l.layers, fn) elseif l.isImage then fn(l) end
  end
end

-- Adds frames up to n. Every layer is made "continuous" for the moment,
-- so the new frames get linked cels, then put back as it was.
local function growFrames(spr, n, out)
  local had = #spr.frames
  if had >= n then return end
  local saved = {}
  eachImageLayer(spr.layers, function(l)
    if l ~= out then
      saved[#saved + 1] = { l, l.isContinuous }
      pcall(function() l.isContinuous = true end)
    end
  end)
  -- newFrame(k) copies frame k into a new frame after it.
  for i = had + 1, n do
    spr:newFrame(i - 1)
  end
  for _, s in ipairs(saved) do
    pcall(function() s[1].isContinuous = s[2] end)
  end
end

-- levels: the loop's level strings; box: where they go ({ x0, y0, w, h });
-- p: settings; riverLayer: the river's mask (or nil). Returns the layer and a
-- note for the user (or nil).
function Output.write(spr, waterLayer, fallLayer, box, levels, p, riverLayer)
  local n = #levels
  local target = Paint.target(spr)
  local map = Paint.map(p.colors, target, p.alpha)
  local images = {}
  for i = 1, n do images[i] = Paint.image(levels[i], box.w, box.h, map, target) end
  local note = nil
  local layer
  local keepLayer, keepFrame = app.layer, app.frame
  app.transaction(I18n.t("undo"), function()
    layer = findLayer(spr.layers, Mask.OUTPUT_NAME)
    local had = #spr.frames
    growFrames(spr, n, layer)
    -- Frame times: the loop's own when it sets the length.
    if had <= n then
      for i = 1, n do spr.frames[i].duration = p.ms / 1000 end
    end
    if not layer then
      layer = spr:newLayer()
      layer.name = Mask.OUTPUT_NAME
      local anchor = waterLayer or riverLayer or fallLayer
      if anchor then
        pcall(function()
          if anchor.parent ~= spr then layer.parent = anchor.parent end
          layer.stackIndex = anchor.stackIndex + 1
        end)
      end
    end
    for i = #layer.cels, 1, -1 do spr:deleteCel(layer.cels[i]) end
    for f = 1, #spr.frames do
      spr:newCel(layer, spr.frames[f], images[(f - 1) % n + 1], Point(box.x0, box.y0))
    end
    for _, l in ipairs({ waterLayer or false, fallLayer or false, riverLayer or false }) do
      if l and l.isVisible then
        l.isVisible = false
        note = I18n.t("toast_masks_hidden")
      end
    end
    if #spr.frames % n ~= 0 then
      note = string.format(I18n.t("toast_frames"), #spr.frames, n)
    end
  end)
  pcall(function()
    if keepLayer then app.layer = keepLayer end
    if keepFrame then app.frame = keepFrame end
  end)
  app.refresh()
  return layer, note
end

return Output
