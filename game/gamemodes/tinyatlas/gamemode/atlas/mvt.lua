-- Mapbox Vector Tile (protobuf) decoder in plain Lua. Shared by every game.
--
--   mvt.decode(s) -> { [layer name] = layer }
--   layer   = { name, extent, features = { feature, ... } }
--   feature = { id, type = 1 point | 2 line | 3 polygon, props = { key = value }, parts }
--   parts   = list of flat coordinate arrays { x1, y1, x2, y2, ... } in tile units (y down, 0..extent,
--             with a buffer outside). Polygon rings are closed (first point repeated last) and each ring has
--             ring.outer = true for an exterior ring, false for a hole (holes follow their exterior).
local byte, sub = string.byte, string.sub
local floor = math.floor

local M = {}

-- read a varint at p; returns value, next position (exact up to 2^53)
local function varint(s, p)
  local v, mul = 0, 1
  while true do
    local b = byte(s, p); p = p + 1
    if b < 128 then return v + b * mul, p end
    v = v + (b - 128) * mul
    mul = mul * 128
  end
end

local function zigzag(v)
  if v % 2 == 0 then return v / 2 end
  return -(v + 1) / 2
end

local function f32(s, p)
  local b0, b1, b2, b3 = byte(s, p, p + 3)          -- little endian
  local sign = b3 >= 128 and -1 or 1
  local e = (b3 % 128) * 2 + floor(b2 / 128)
  local m = ((b2 % 128) * 256 + b1) * 256 + b0
  if e == 0 then return sign * m * 2 ^ -149 end
  if e == 255 then return m == 0 and sign * math.huge or 0 / 0 end
  return sign * (1 + m / 8388608) * 2 ^ (e - 127)
end

local function f64(s, p)
  local b = { byte(s, p, p + 7) }
  local sign = b[8] >= 128 and -1 or 1
  local e = (b[8] % 128) * 16 + floor(b[7] / 16)
  local m = (b[7] % 16)
  for i = 6, 1, -1 do m = m * 256 + b[i] end
  if e == 0 then return sign * m * 2 ^ -1074 end
  if e == 2047 then return m == 0 and sign * math.huge or 0 / 0 end
  return sign * (1 + m / 2 ^ 52) * 2 ^ (e - 1023)
end

-- skip a field of wire type wt at p
local function skip(s, p, wt)
  if wt == 0 then local _; _, p = varint(s, p); return p end
  if wt == 1 then return p + 8 end
  if wt == 2 then local len; len, p = varint(s, p); return p + len end
  if wt == 5 then return p + 4 end
  error("mvt: unsupported wire type " .. wt)
end

local function value(s, p, e)
  local v
  while p < e do
    local key; key, p = varint(s, p)
    local f, wt = floor(key / 8), key % 8
    if f == 1 then local len; len, p = varint(s, p); v = sub(s, p, p + len - 1); p = p + len
    elseif f == 2 then v = f32(s, p); p = p + 4
    elseif f == 3 then v = f64(s, p); p = p + 8
    elseif f == 4 then                             -- int64: negatives are 10-byte two's complement varints
      local q, lo, mul, nb = p, 0, 1, 0
      repeat
        local b = byte(s, q); q = q + 1; nb = nb + 1
        if nb <= 8 then lo = lo + (127 - b % 128) * mul; mul = mul * 128 end   -- ones' complement, exact
      until b < 128
      v = nb == 10 and -(lo + 1) or varint(s, p)
      p = q
    elseif f == 5 then v, p = varint(s, p)
    elseif f == 6 then v, p = varint(s, p); v = zigzag(v)
    elseif f == 7 then v, p = varint(s, p); v = v ~= 0
    else p = skip(s, p, wt) end
  end
  return v
end

local function geometry(s, p, e, gtype)
  local parts, cur = {}, nil
  local x, y = 0, 0
  local cmd, count = 0, 0
  while p < e do
    if count == 0 then
      local c; c, p = varint(s, p)
      cmd, count = c % 8, floor(c / 8)
      if cmd == 7 then                             -- ClosePath: repeat the first point
        if cur and #cur >= 2 then cur[#cur + 1] = cur[1]; cur[#cur + 1] = cur[2] end
        count = 0
      end
    else
      local dx, dy
      dx, p = varint(s, p); dy, p = varint(s, p)
      x = x + zigzag(dx); y = y + zigzag(dy)
      if cmd == 1 and (gtype ~= 1 or not cur) then  -- MoveTo starts a new part (points stay in one part)
        cur = {}; parts[#parts + 1] = cur
      end
      cur[#cur + 1] = x; cur[#cur + 1] = y
      count = count - 1
    end
  end
  if gtype == 3 then
    for i = 1, #parts do
      local r, a = parts[i], 0
      for k = 1, #r - 3, 2 do a = a + r[k] * r[k + 3] - r[k + 2] * r[k + 1] end
      r.area = a / 2
      r.outer = a > 0                              -- clockwise in y-down tile space = exterior
    end
  end
  return parts
end

local function feature(s, p, e, keys, vals)
  local f = { type = 0, props = {} }
  local tags, gp, ge
  while p < e do
    local key; key, p = varint(s, p)
    local fld, wt = floor(key / 8), key % 8
    if fld == 1 then f.id, p = varint(s, p)
    elseif fld == 2 then local len; len, p = varint(s, p); tags = { p, p + len }; p = p + len
    elseif fld == 3 then f.type, p = varint(s, p)
    elseif fld == 4 then local len; len, p = varint(s, p); gp, ge = p, p + len; p = p + len
    else p = skip(s, p, wt) end
  end
  if tags then
    local q = tags[1]
    while q < tags[2] do
      local k, v
      k, q = varint(s, q); v, q = varint(s, q)
      local kn = keys[k + 1]
      if kn then f.props[kn] = vals[v + 1] end
    end
  end
  f.parts = gp and geometry(s, gp, ge, f.type) or {}
  return f
end

local TICK = function() end                      -- see M.decode

local function layer(s, p, e)
  local L = { extent = 4096, features = {} }
  local keys, vals, feats = {}, {}, {}
  while p < e do
    local key; key, p = varint(s, p)
    local fld, wt = floor(key / 8), key % 8
    if fld == 1 then local len; len, p = varint(s, p); L.name = sub(s, p, p + len - 1); p = p + len
    elseif fld == 2 then local len; len, p = varint(s, p); feats[#feats + 1] = { p, p + len }; p = p + len
    elseif fld == 3 then local len; len, p = varint(s, p); keys[#keys + 1] = sub(s, p, p + len - 1); p = p + len
    elseif fld == 4 then local len; len, p = varint(s, p); vals[#vals + 1] = value(s, p, p + len); p = p + len
    elseif fld == 5 then L.extent, p = varint(s, p)
    else p = skip(s, p, wt) end
  end
  for i = 1, #feats do
    L.features[i] = feature(s, feats[i][1], feats[i][2], keys, vals)
    if i % 16 == 0 then TICK() end
  end
  return L
end

-- tick: optional, called every few dozen features (a build job yields there when its time is up)
function M.decode(s, tick)
  TICK = tick or function() end
  local layers, p, e = {}, 1, #s + 1
  while p < e do
    local key; key, p = varint(s, p)
    local fld, wt = floor(key / 8), key % 8
    if fld == 3 then
      local len; len, p = varint(s, p)
      local L = layer(s, p, p + len)
      layers[L.name] = L
      p = p + len
    else
      p = skip(s, p, wt)
    end
  end
  return layers
end

return M
