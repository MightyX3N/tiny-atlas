-- The masks: which pixels of the sprite are still or gathered water (the
-- opaque pixels of the water layer: pools, ponds, lakes), which are rivers
-- (the river layer: always flowing) and which are falling water (the fall
-- layer). All three are optional. Where the river and the fall overlap is
-- the river's mouth: the lip it rolls over into the fall. Elsewhere the
-- fall wins over the others, the river over still water.
--
-- A region is { x0, y0, w, h, sprW, sprH, fall = { true/false .. },
-- water = { .. } (every surface: still water, rivers and lips), river =
-- { .. }, lip = { .. }, fallCount, waterCount, riverCount, lipCount, sig }:
-- the box round the masks, grown by MARGIN px (inside the sprite) for the
-- foam, mist and spray that reach past them.

local Mask = {}

local min, max = math.min, math.max

Mask.OUTPUT_NAME = "WOWe Water"
Mask.MARGIN = 28

-- Every image layer of a sprite (groups opened), top of the stack first,
-- except the layer the scene is written into.
function Mask.imageLayers(spr)
  local list, seen = {}, {}
  local function walk(layers, prefix)
    for i = #layers, 1, -1 do
      local l = layers[i]
      if l.isGroup then
        walk(l.layers, prefix .. l.name .. " / ")
      elseif l.isImage and not l.isTilemap and l.name ~= Mask.OUTPUT_NAME then
        local label = prefix .. l.name
        seen[label] = (seen[label] or 0) + 1
        if seen[label] > 1 then label = label .. " (" .. seen[label] .. ")" end
        list[#list + 1] = { label = label, layer = l }
      end
    end
  end
  if spr then walk(spr.layers, "") end
  return list
end

-- A layer's name in lower case, ASCII letters only: string.lower follows
-- the system's locale, which (Turkish Windows, say) would also change the
-- bytes of letters like "ö" and "ğ" and spoil the match.
local function lowerName(name)
  return (name:gsub("[A-Z]", function(c) return string.char(c:byte() + 32) end))
end
Mask.lowerName = lowerName

local function named(list, words, skip, skip2)
  for _, e in ipairs(list) do
    if e.layer ~= skip and e.layer ~= skip2 then
      local n = lowerName(e.layer.name)
      for _, w in ipairs(words) do
        if n:find(w, 1, true) then return e end
      end
    end
  end
  return nil
end

local FALL_WORDS = { "fall", "selale", "\197\159elale", "cascade" }
local RIVER_WORDS = { "river", "nehir", "stream", "dere", "creek", "cay", "\195\167ay",
                      "agiz", "a\196\159\196\177z", "mouth", "lip", "dudak" }
local WATER_WORDS = { "water", "pool", "havuz", "pond", "lake", "gol", "g\195\182l", "sea", "deniz" }

-- The fall's layer: one called fall / selale / cascade, else none.
function Mask.guessFall(list, waterLayer)
  return named(list, FALL_WORDS, waterLayer)
end

-- The river's layer: one called river / nehir / stream / dere / ..., or
-- agiz / mouth / lip (the water running into a fall's mouth), else none.
function Mask.guessRiver(list, fallLayer, waterLayer)
  return named(list, RIVER_WORDS, fallLayer, waterLayer)
end

-- The still water's layer: one called water / pool / lake / su / ...; when
-- there is neither a fall nor a river, else one called mask, else the
-- active one, else the first.
function Mask.guessWater(list, fallLayer, riverLayer)
  local e = named(list, WATER_WORDS, fallLayer, riverLayer)
  if e then return e end
  for _, f in ipairs(list) do
    if f.layer ~= fallLayer and f.layer ~= riverLayer and lowerName(f.layer.name) == "su" then return f end
  end
  if fallLayer or riverLayer then return nil end
  e = named(list, { "mask", "maske" })
  if e then return e end
  for _, f in ipairs(list) do
    if f.layer == app.layer then return f end
  end
  return list[1]
end

-- The cel a mask is read from: the one in `frame`, else the first there is.
local function celOf(layer, frame)
  local cel = layer:cel(frame or 1)
  if cel and cel.image then return cel end
  for _, c in ipairs(layer.cels) do
    if c.image then return c end
  end
  return nil
end

-- A string that changes whenever a layer's pixels do.
function Mask.signature(spr, layer, frame)
  if not (spr and layer) then return "" end
  local cel = celOf(layer, frame)
  if not cel then return "empty" end
  local img, pos = cel.image, cel.position
  local ok, bytes = pcall(function() return img.bytes end)
  return pos.x .. "," .. pos.y .. "," .. img.width .. "x" .. img.height .. ":" ..
    (ok and bytes or tostring(img))
end

-- The opaque pixels of a layer inside the sprite: a list of sprite pixel
-- numbers (y * W + x) and the box round them, or nil.
local function solidOf(spr, layer, frame)
  if not layer then return nil end
  local cel = celOf(layer, frame)
  if not cel then return nil end
  local img, pos = cel.image, cel.position
  local W, H = spr.width, spr.height
  local iw, ih = img.width, img.height
  local mode = img.colorMode
  local step = (mode == ColorMode.RGB and 4) or (mode == ColorMode.GRAY and 2) or 1
  local transparent = img.spec.transparentColor
  local bytes = img.bytes
  local byte = string.byte
  local list = {}
  local x0, y0, x1, y1 = math.huge, math.huge, -1, -1
  for y = 0, ih - 1 do
    local sy = pos.y + y
    if sy >= 0 and sy < H then
      local row = { byte(bytes, y * iw * step + 1, (y + 1) * iw * step) }
      for x = 0, iw - 1 do
        local on
        if step == 1 then on = row[x + 1] ~= transparent else on = row[x * step + step] > 0 end
        local sx = pos.x + x
        if on and sx >= 0 and sx < W then
          list[#list + 1] = sy * W + sx
          if sx < x0 then x0 = sx end
          if sx > x1 then x1 = sx end
          if sy < y0 then y0 = sy end
          if sy > y1 then y1 = sy end
        end
      end
    end
  end
  if #list == 0 then return nil end
  return { list = list, x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
end

-- The region from lists of sprite pixels (fall, water, river; any may be
-- nil).
local function region(W, H, fall, water, sig, river)
  if not fall and not water and not river then return nil, "empty" end
  local x0, y0, x1, y1 = math.huge, math.huge, -1, -1
  for _, m in ipairs({ fall or false, water or false, river or false }) do
    if m then
      x0, y0 = min(x0, m.x0), min(y0, m.y0)
      x1, y1 = max(x1, m.x1), max(y1, m.y1)
    end
  end
  local M = Mask.MARGIN
  x0, y0 = max(0, x0 - M), max(0, y0 - M)
  x1, y1 = min(W - 1, x1 + M), min(H - 1, y1 + M)
  local w, h = x1 - x0 + 1, y1 - y0 + 1
  local F, S, V, L = {}, {}, {}, {}
  for i = 1, w * h do F[i], S[i], V[i], L[i] = false, false, false, false end
  local function each(m, fn)
    for _, k in ipairs(m and m.list or {}) do fn((k // W - y0) * w + (k % W - x0) + 1) end
  end
  each(water, function(i) S[i] = true end)
  each(river, function(i) V[i] = true end)
  each(fall, function(i) F[i] = true end)
  local fallCount, waterCount, riverCount, lipCount = 0, 0, 0, 0
  for i = 1, w * h do
    if V[i] and F[i] then
      -- The mouth: river over the fall.
      L[i], F[i], S[i] = true, false, true
      lipCount = lipCount + 1
    elseif F[i] then
      S[i], V[i] = false, false
    elseif V[i] then
      S[i] = true
    end
    if F[i] then fallCount = fallCount + 1 end
    if S[i] then waterCount = waterCount + 1 end
    if V[i] then riverCount = riverCount + 1 end
  end
  return { x0 = x0, y0 = y0, w = w, h = h, sprW = W, sprH = H, fall = F, water = S, river = V, lip = L,
           fallCount = fallCount, waterCount = waterCount, riverCount = riverCount, lipCount = lipCount,
           sig = sig }
end

-- The region with lip rods drawn on it (Guide.edge of each: x -> y, sprite
-- px). A rod is where the water goes over: in every column it crosses,
-- the fall above it is the mouth (river running to the edge, as if the
-- river were painted over the fall there) and the fall starts at it;
-- the river's mask below it no longer counts, and where the river reaches
-- the rod with no fall under it, the water falls there too, as far down as
-- the rod's fall beside it goes (or till it meets still water).
function Mask.withLips(R, edges)
  local w, h = R.w, R.h
  local F, S, V, L = {}, {}, {}, {}
  for i = 1, w * h do F[i], S[i], V[i], L[i] = R.fall[i], R.water[i], R.river[i], R.lip[i] end
  local function at(x, y) return y * w + x + 1 end
  for _, edge in ipairs(edges) do
    local cols, bottom = {}, {}
    for X, Y in pairs(edge) do
      local x = X - R.x0
      local ye = math.floor(Y + 0.5) - R.y0
      if x >= 0 and x < w and ye >= 0 and ye < h then
        cols[#cols + 1] = { x, ye }
        -- The fall (and its mouth) in this column round the rod: the
        -- nearest pixel of it within 3 rows, then all of it up and down.
        local near = nil
        for d = 0, 3 do
          for _, y in ipairs({ ye + d, ye - d }) do
            if not near and y >= 0 and y < h and (F[at(x, y)] or L[at(x, y)]) then near = y end
          end
        end
        if near then
          local top, bot = near, near
          while top > 0 and (F[at(x, top - 1)] or L[at(x, top - 1)]) do top = top - 1 end
          while bot < h - 1 and (F[at(x, bot + 1)] or L[at(x, bot + 1)]) do bot = bot + 1 end
          for y = top, bot do
            local i = at(x, y)
            if y < ye then
              F[i], L[i], S[i], V[i] = false, true, true, true
            else
              F[i], L[i], S[i], V[i] = true, false, false, false
            end
          end
          if bot >= ye then bottom[x] = bot end
        end
      end
    end
    for _, c in ipairs(cols) do
      local x, ye = c[1], c[2]
      -- Below the rod the river's mask no longer counts.
      local riverAbove = ye > 0 and V[at(x, ye - 1)]
      local y = ye
      while y < h and V[at(x, y)] and not F[at(x, y)] do
        local i = at(x, y)
        S[i], V[i], L[i] = false, false, false
        riverAbove = true
        y = y + 1
      end
      -- The river reaches the rod with no fall under it: it falls here
      -- too, as far as the nearest column of this rod's fall.
      if riverAbove and not F[at(x, ye)] then
        local best, bd = nil, math.huge
        for xx, bot in pairs(bottom) do
          local d = math.abs(xx - x)
          if d < bd then best, bd = bot, d end
        end
        if best then
          for yy = ye, best do
            local i = at(x, yy)
            if S[i] or F[i] then break end
            F[i] = true
          end
        end
      end
    end
  end
  local fallCount, waterCount, riverCount, lipCount = 0, 0, 0, 0
  for i = 1, w * h do
    if F[i] then fallCount = fallCount + 1 end
    if S[i] then waterCount = waterCount + 1 end
    if V[i] then riverCount = riverCount + 1 end
    if L[i] then lipCount = lipCount + 1 end
  end
  return { x0 = R.x0, y0 = R.y0, w = w, h = h, sprW = R.sprW, sprH = R.sprH, fall = F, water = S, river = V,
           lip = L, fallCount = fallCount, waterCount = waterCount, riverCount = riverCount, lipCount = lipCount,
           sig = R.sig }
end

-- Reads the region. Returns it, or nil and why ("nosprite", "nolayer",
-- "empty": nothing painted on either mask).
function Mask.read(spr, waterLayer, fallLayer, frame, riverLayer)
  if not spr then return nil, "nosprite" end
  if not waterLayer and not fallLayer and not riverLayer then return nil, "nolayer" end
  local water = waterLayer and solidOf(spr, waterLayer, frame) or nil
  local fall = (fallLayer and fallLayer ~= waterLayer) and solidOf(spr, fallLayer, frame) or nil
  local river = (riverLayer and riverLayer ~= waterLayer and riverLayer ~= fallLayer)
    and solidOf(spr, riverLayer, frame) or nil
  return region(spr.width, spr.height, fall, water,
    Mask.signature(spr, waterLayer, frame) .. "|" .. Mask.signature(spr, fallLayer, frame) .. "|" ..
    Mask.signature(spr, riverLayer, frame), river)
end

-- A region from functions water(x, y), fall(x, y) and river(x, y) (any may
-- be nil) over a sprite of W x H (demos, tests).
function Mask.fromFunctions(W, H, waterFn, fallFn, riverFn)
  local function solid(fn)
    if not fn then return nil end
    local list, x0, y0, x1, y1 = {}, math.huge, math.huge, -1, -1
    for y = 0, H - 1 do
      for x = 0, W - 1 do
        if fn(x, y) then
          list[#list + 1] = y * W + x
          if x < x0 then x0 = x end
          if x > x1 then x1 = x end
          if y < y0 then y0 = y end
          if y > y1 then y1 = y end
        end
      end
    end
    if #list == 0 then return nil end
    return { list = list, x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
  end
  local s, f, v = solid(waterFn), solid(fallFn), solid(riverFn)
  return region(W, H, f, s, tostring(s and #s.list) .. ":" .. tostring(f and #f.list) .. ":" ..
    tostring(v and #v.list), v)
end

-- Distance (px) from every pixel of the region's box where open(k) is true
-- to the nearest pixel where it is not (chamfer: a step across costs 1, a
-- step up or down `vy` (default 1), a diagonal step both; 0.5 for a pixel
-- beside it). Past the box: closed inside the sprite, open past its edge
-- (the water goes on there).
function Mask.distance(R, open, step, vy)
  local w, h = R.w, R.h
  local W2, H2 = w + 2, h + 2
  local INF = 1e9
  vy = vy or 1
  local R2 = math.sqrt(1 + vy * vy)
  local d = {}
  for y = 0, H2 - 1 do
    local sy = R.y0 + y - 1
    for x = 0, W2 - 1 do
      local sx = R.x0 + x - 1
      local v
      if x == 0 or y == 0 or x == W2 - 1 or y == H2 - 1 then
        local inside = sx >= 0 and sy >= 0 and sx < R.sprW and sy < R.sprH
        v = inside and 0 or INF
      else
        v = open((y - 1) * w + x) and INF or 0
      end
      d[y * W2 + x + 1] = v
    end
  end
  for y = 1, H2 - 1 do
    local row, up = y * W2 + 1, (y - 1) * W2 + 1
    for x = 0, W2 - 1 do
      local k = row + x
      local v = d[k]
      if v > 0 then
        if x > 0 then
          local c = d[k - 1] + 1 if c < v then v = c end
          c = d[up + x - 1] + R2 if c < v then v = c end
        end
        local c = d[up + x] + vy if c < v then v = c end
        if x < W2 - 1 then c = d[up + x + 1] + R2 if c < v then v = c end end
        d[k] = v
      end
    end
    if step then step() end
  end
  for y = H2 - 2, 0, -1 do
    local row, dn = y * W2 + 1, (y + 1) * W2 + 1
    for x = W2 - 1, 0, -1 do
      local k = row + x
      local v = d[k]
      if v > 0 then
        if x < W2 - 1 then
          local c = d[k + 1] + 1 if c < v then v = c end
          c = d[dn + x + 1] + R2 if c < v then v = c end
        end
        local c = d[dn + x] + vy if c < v then v = c end
        if x > 0 then c = d[dn + x - 1] + R2 if c < v then v = c end end
        d[k] = v
      end
    end
    if step then step() end
  end
  local out = {}
  for y = 0, h - 1 do
    local src = (y + 1) * W2 + 2
    local dst = y * w + 1
    for x = 0, w - 1 do
      local v = d[src + x]
      out[dst + x] = (v > 0) and (min(v, 999) - 0.5) or 0
    end
  end
  return out
end

return Mask
