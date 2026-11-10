-- Well-known binary geometry (Overture's geometry column) to Lua: points, lines and polygons as flat lon/lat lists.
--   wkb.decode(v) -> { kind = "point" | "line" | "polygon", parts = { { lon, lat, lon, lat, ... }, ... },
--                      polys = { { outer, hole, ... }, ... } (polygons) }
--   v: a string, or { bytes, offset, length } (parquet.read_column's raw values)
local floor = math.floor
local parquet_double

local M = {}

local function u32(b, p, le)
  if le then return b[p] + b[p + 1] * 256 + b[p + 2] * 65536 + b[p + 3] * 16777216 end
  return b[p + 3] + b[p + 2] * 256 + b[p + 1] * 65536 + b[p] * 16777216
end
local tmp = {}
local function dbl(b, p, le)
  if le then return parquet_double(b, p) end
  for i = 0, 7 do tmp[i + 1] = b[p + 7 - i] end
  return parquet_double(tmp, 1)
end

local function coords(b, p, le, n, dims, out)
  local k = #out
  for _ = 1, n do
    out[k + 1] = dbl(b, p, le)
    out[k + 2] = dbl(b, p + 8, le)
    k = k + 2
    p = p + 8 * dims
  end
  return p
end

local function geom(b, p, g)
  local le = b[p] == 1
  local t = u32(b, p + 1, le)
  p = p + 5
  local dims = 2
  local base = t % 1000
  local zm = floor(t / 1000)
  if zm == 1 or zm == 2 then dims = 3 elseif zm == 3 then dims = 4 end
  if t >= 0x20000000 then
    -- EWKB flags (Z 0x80000000, M 0x40000000, SRID 0x20000000)
    local hi = floor(t / 0x10000000)
    if t >= 0x80000000 then dims = dims + 1 end
    if hi % 8 >= 4 then dims = dims + 1 end
    if hi % 4 >= 2 then p = p + 4 end
    base = t % 0x10000000 % 1000
  end
  if base == 1 then
    g.kind = g.kind or "point"
    local part = {}
    p = coords(b, p, le, 1, dims, part)
    g.parts[#g.parts + 1] = part
  elseif base == 2 then
    g.kind = g.kind or "line"
    local n = u32(b, p, le); p = p + 4
    local part = {}
    p = coords(b, p, le, n, dims, part)
    g.parts[#g.parts + 1] = part
  elseif base == 3 then
    g.kind = g.kind or "polygon"
    local nr = u32(b, p, le); p = p + 4
    local poly = {}
    for _ = 1, nr do
      local n = u32(b, p, le); p = p + 4
      local ring = {}
      p = coords(b, p, le, n, dims, ring)
      poly[#poly + 1] = ring
      g.parts[#g.parts + 1] = ring
    end
    g.polys[#g.polys + 1] = poly
  elseif base >= 4 and base <= 7 then
    local n = u32(b, p, le); p = p + 4
    for _ = 1, n do p = geom(b, p, g) end
  else
    error("wkb: unsupported geometry type " .. tostring(t))
  end
  return p
end

function M.decode(v)
  parquet_double = parquet_double or ATLAS_REQUIRE("parquet").double
  local b, p
  if type(v) == "table" then b, p = v[1], v[2]
  else
    b = { v:byte(1, -1) }
    p = 1
  end
  local g = { parts = {}, polys = {} }
  geom(b, p, g)
  return g
end

return M
